#!/usr/bin/env bash
# First checkout: download the Mia EAQ checkpoint and the Engram tables, pull the engine image on both Sparks,
# build the model view, copy it to the worker and pre-build the CUDA extensions. It does not start the server,
# does not install systemd units and does not reboot.
#
# Usage:
#   ./prepare.sh            # do the work (resumable; safe to re-run)
#   ./prepare.sh --check    # only report what is present/missing; download/pull/build nothing
#
# Then:
#   ./install-boot.sh       # installs/enables the boot units (asks for sudo)
#   reboot both Sparks      # or start the units now; see BOOT.md
# The first service start writes the ~100 GiB rank caches on each node (~15 min).
#
# The model and Engram are pinned below. The Docker image is taken from .env.mia-eaq
# (IMAGE=vaninvv/tensorfold-dsv41:mia-eaq-07aa02585f64, public).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export HOME="${HOME:-/home/spark1}"

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# Pinned Mia variant (same as scripts/link_mia_view.sh).
MODEL_ID="${MODEL_ID:-Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw}"
MODEL_REV="${MODEL_REVISION:-45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b}"
ENGRAM_ID="${ENGRAM_ID:-deepseek-ai/DeepSeek-V4.1-Flash-1017}"
ENGRAM_REV="${ENGRAM_REVISION:-1bae0e1088993b9b82de08f59de5be5a34e42170}"
ENGRAM_FILES=(model-00047-of-00048.safetensors model-00048-of-00048.safetensors)
declare -A ENGRAM_SIZE=([model-00047-of-00048.safetensors]=101535150936 [model-00048-of-00048.safetensors]=101537926640)

ENV_FILE="$ROOT/.env.mia-eaq"
if [ ! -f "$ENV_FILE" ]; then
  cp -p "$ROOT/.env.mia-eaq.example" "$ENV_FILE"
  echo "[prepare] created $ENV_FILE from .env.mia-eaq.example; review WORKER_SSH/HEAD_IP/WORKER_IP"
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
[ "${VARIANT:-}" = mia-eaq ] || { echo "[prepare] VARIANT is not mia-eaq" >&2; exit 1; }
: "${WORKER_SSH:?WORKER_SSH is not set in .env.mia-eaq}"
: "${MODEL_VIEW:?MODEL_VIEW is not set in .env.mia-eaq}"
: "${IMAGE:?IMAGE is not set in .env.mia-eaq}"
HF_CACHE="${HF_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}}"
export HF_CACHE
export MODEL_ID MODEL_REV ENGRAM_ID ENGRAM_REV
export MIA_MODEL_REPO="$MODEL_ID" MIA_MODEL_REV="$MODEL_REV"
export MIA_ENGRAM_REPO="$ENGRAM_ID" MIA_ENGRAM_REV="$ENGRAM_REV"
MODEL_SNAP="$HF_CACHE/hub/models--${MODEL_ID//\//--}/snapshots/$MODEL_REV"
ENGRAM_SNAP="$HF_CACHE/hub/models--${ENGRAM_ID//\//--}/snapshots/$ENGRAM_REV"

find_hf() {
  local c
  for c in "${HF_BIN:-}" hf huggingface-cli "$HOME/.local/bin/hf"; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}
HF_BIN="$(find_hf || true)"
[ -n "$HF_BIN" ] || { echo "[prepare] the Hugging Face CLI (hf) is not installed: pip install -U huggingface_hub" >&2; exit 1; }

say() { echo "[prepare] $*"; }
die() { echo "[prepare] ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed on the head"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (docker group?)"
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" true 2>/dev/null ||
  die "cannot ssh to $WORKER_SSH; set WORKER_SSH in $ENV_FILE"
ssh -n -o BatchMode=yes "$WORKER_SSH" 'docker info >/dev/null 2>&1' ||
  die "$WORKER_SSH cannot talk to its docker daemon"

bad=0
note() { [ "$1" = 0 ] || bad=1; echo "[prepare] $2"; }

# --- the image -----------------------------------------------------------------
head_id=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)
worker_id=$(ssh -n -o BatchMode=yes "$WORKER_SSH" "docker image inspect -f '{{.Id}}' '$IMAGE'" 2>/dev/null || true)
if [ "$CHECK" = 1 ]; then
  [ -n "$head_id" ] || { note 1 "head: image $IMAGE is missing"; }
  [ -n "$worker_id" ] || { note 1 "worker: image $IMAGE is missing"; }
  if [ -n "$head_id" ] && [ -n "$worker_id" ] && [ "$head_id" != "$worker_id" ]; then
    note 1 "image IDs differ: head $head_id, worker $worker_id"
  fi
  [ -n "$head_id" ] && [ "$head_id" = "$worker_id" ] && say "image: present on both ($head_id)"
else
  if [ -z "$head_id" ]; then say "pulling $IMAGE on head"; docker pull "$IMAGE"; head_id=$(docker image inspect -f '{{.Id}}' "$IMAGE"); fi
  if [ -z "$worker_id" ]; then say "pulling $IMAGE on worker"; ssh -n -o BatchMode=yes "$WORKER_SSH" "docker pull '$IMAGE'"; worker_id=$(ssh -n -o BatchMode=yes "$WORKER_SSH" "docker image inspect -f '{{.Id}}' '$IMAGE'"); fi
  [ "$head_id" = "$worker_id" ] || die "image IDs differ: head $head_id, worker $worker_id"
  say "image: $IMAGE on both ($head_id)"
fi

# --- the checkpoint ------------------------------------------------------------
if [ -f "$MODEL_SNAP/model.safetensors.index.json" ]; then
  say "checkpoint: present at $MODEL_SNAP"
else
  if [ "$CHECK" = 1 ]; then
    note 1 "checkpoint: missing $MODEL_SNAP"
  else
    [ -d "$HF_CACHE/hub" ] || mkdir -p "$HF_CACHE/hub"
    avail=$(df -B1 --output=avail "$HF_CACHE" | tail -1 | tr -dc 0-9)
    if [ "${avail:-0}" -lt $((420 * 1024 ** 3)) ]; then
      die "only $((avail / 1024 ** 3)) GiB free in $HF_CACHE; the checkpoint (~197 GiB) and Engram (~190 GiB) need ~400 GiB"
    fi
    say "downloading $MODEL_ID @ ${MODEL_REV:0:8} (~197 GiB; resumes)"
    for attempt in 1 2 3 4 5; do
      if "$HF_BIN" download "$MODEL_ID" --revision "$MODEL_REV" --cache-dir "$HF_CACHE/hub" \
          --exclude 'images/*' --exclude 'encoding/*'; then break; fi
      say "download attempt $attempt failed; retrying in 30 s"
      sleep 30
    done
    [ -f "$MODEL_SNAP/model.safetensors.index.json" ] || die "$MODEL_ID: download failed or incomplete"
    say "checkpoint: $MODEL_SNAP"
  fi
fi

# --- the Engram tables ---------------------------------------------------------
engram_ok=1
if [ -f "$ENGRAM_SNAP/model.safetensors.index.json" ]; then
  for f in "${ENGRAM_FILES[@]}"; do
    [ -f "$ENGRAM_SNAP/$f" ] && [ "$(stat -L -c %s "$ENGRAM_SNAP/$f")" = "${ENGRAM_SIZE[$f]}" ] || engram_ok=0
  done
else
  engram_ok=0
fi
if [ "$engram_ok" = 1 ]; then
  say "engram: present at $ENGRAM_SNAP"
else
  if [ "$CHECK" = 1 ]; then
    note 1 "engram: missing/incomplete at $ENGRAM_SNAP"
  else
    [ -d "$HF_CACHE/hub" ] || mkdir -p "$HF_CACHE/hub"
    inc=(--include model.safetensors.index.json --include config.json)
    for f in "${ENGRAM_FILES[@]}"; do inc+=(--include "$f"); done
    say "downloading Engram: ${ENGRAM_FILES[*]} (~190 GiB; resumes, Xet)"
    for attempt in 1 2 3 4 5; do
      if "$HF_BIN" download "$ENGRAM_ID" --revision "$ENGRAM_REV" --cache-dir "$HF_CACHE/hub" \
          --max-workers 2 "${inc[@]}"; then break; fi
      say "Engram attempt $attempt failed; retrying in 30 s"
      sleep 30
    done
    for f in "${ENGRAM_FILES[@]}"; do
      [ -f "$ENGRAM_SNAP/$f" ] || die "$ENGRAM_ID: $f is missing"
      [ "$(stat -L -c %s "$ENGRAM_SNAP/$f")" = "${ENGRAM_SIZE[$f]}" ] ||
        die "$f is $(stat -L -c %s "$ENGRAM_SNAP/$f") bytes, expected ${ENGRAM_SIZE[$f]}"
    done
    say "engram: $ENGRAM_SNAP"
  fi
fi

# --- the view ------------------------------------------------------------------
view_shards=0
if [ -d "$MODEL_VIEW/model" ]; then
  view_shards=$(find "$MODEL_VIEW/model" -maxdepth 1 -name 'model-*-of-*.safetensors' | wc -l)
fi
view_ok=0
[ -f "$MODEL_VIEW/model/chat_template.jinja" ] && [ -d "$MODEL_VIEW/engram" ] && [ "$view_shards" -ge 39 ] && view_ok=1
if [ "$CHECK" = 1 ]; then
  [ "$view_ok" = 1 ] && say "view: $MODEL_VIEW ($view_shards shards)" || note 1 "view: missing/incomplete $MODEL_VIEW ($view_shards shards)"
  ssh -n -o BatchMode=yes "$WORKER_SSH" "test -f '$MODEL_VIEW/model/chat_template.jinja'" 2>/dev/null &&
    say "worker view: present" || note 1 "worker view: missing"
else
  if [ "$view_ok" = 1 ]; then
    say "view: $MODEL_VIEW ($view_shards shards)"
  else
    [ "$view_shards" = 0 ] || die "$MODEL_VIEW is partial ($view_shards shards); remove it and rerun"
    say "building the hard-link view at $MODEL_VIEW"
    "$ROOT/scripts/link_mia_view.sh" || die "link_mia_view.sh failed"
  fi
  say "copying the view to $WORKER_SSH (rsync, resumes; only the model/ dir is large)"
  "$ROOT/scripts/sync_view.sh" || die "sync_view.sh failed"
fi

# --- CUDA extensions -----------------------------------------------------------
if [ "$CHECK" = 1 ]; then
  say "CUDA extensions: run without --check to build/cache them"
else
  say "pre-building the CUDA extensions on both nodes"
  "$ROOT/scripts/build_extensions.sh" || die "build_extensions.sh failed"
fi

if [ "$bad" = 1 ]; then
  echo "[prepare] CHECK FAILED: see the missing items above" >&2
  exit 1
fi
if [ "$CHECK" = 1 ]; then
  say "check OK"
  exit 0
fi
cat <<EOF

[prepare] done. Next:
  ./install-boot.sh          # installs/enables the boot units (sudo)
  sudo reboot                # or start the units now; see BOOT.md

The first service start writes the ~100 GiB rank caches on each node (~15 min).
EOF
