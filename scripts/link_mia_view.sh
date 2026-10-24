#!/usr/bin/env bash
# Variant A: build MODEL_VIEW/model and MODEL_VIEW/engram from the Mia-AiLab EAQ checkpoint and the Engram tables
# already in this head's Hugging Face cache. The files are HARD LINKS: no data is copied and the Mia recipe's cache is
# not modified. Run on the head, then scripts/sync_view.sh for the worker.
#
# Usage: ENV_FILE=.env.mia-eaq scripts/link_mia_view.sh
# The target must be empty (or missing); this script never deletes or merges an existing view.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

fail() { echo "[link-view] ERROR: $*" >&2; exit 1; }
say() { echo "[link-view] $*"; }

[ "${VARIANT:-}" = mia-eaq ] ||
  fail "VARIANT is '${VARIANT:-}', not 'mia-eaq': run with ENV_FILE=.env.mia-eaq (see .env.mia-eaq)"

MIA_MODEL_REPO="${MIA_MODEL_REPO:-Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw}"
MIA_MODEL_REV="${MIA_MODEL_REV:-45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b}"
MIA_ENGRAM_REPO="${MIA_ENGRAM_REPO:-deepseek-ai/DeepSeek-V4.1-Flash-1017}"
MIA_ENGRAM_REV="${MIA_ENGRAM_REV:-1bae0e1088993b9b82de08f59de5be5a34e42170}"
HF="${HF_CACHE:-$HOME/.cache/huggingface}"
MODEL_SNAP="${MIA_MODEL_SNAP:-$HF/hub/models--${MIA_MODEL_REPO//\//--}/snapshots/$MIA_MODEL_REV}"
ENGRAM_SNAP="${MIA_ENGRAM_SNAP:-$HF/hub/models--${MIA_ENGRAM_REPO//\//--}/snapshots/$MIA_ENGRAM_REV}"

: "${MODEL_VIEW:?MODEL_VIEW is not set}"
MODEL_VIEW=${MODEL_VIEW%/}
[ -d "$MODEL_SNAP" ] || fail "Mia checkpoint snapshot not found: $MODEL_SNAP"
[ -d "$ENGRAM_SNAP" ] || fail "Engram snapshot not found: $ENGRAM_SNAP"
[ -s "$MODEL_SNAP/model.safetensors.index.json" ] || fail "no checkpoint index in $MODEL_SNAP"
[ -s "$MODEL_SNAP/config.json" ] || fail "no config.json in $MODEL_SNAP"

# The two Engram files are what the engine reads; their sizes are the 1017 card's (the same check prepare.sh makes).
declare -A ENGRAM_SIZE=(
  [model-00047-of-00048.safetensors]=101535150936
  [model-00048-of-00048.safetensors]=101537926640
)
for f in "${!ENGRAM_SIZE[@]}"; do
  [ -f "$ENGRAM_SNAP/$f" ] || fail "missing $ENGRAM_SNAP/$f"
  got=$(stat -L -c %s "$ENGRAM_SNAP/$f")
  [ "$got" = "${ENGRAM_SIZE[$f]}" ] || fail "$f is $got bytes, expected ${ENGRAM_SIZE[$f]}: the Engram download is incomplete"
done

# Refuse to touch a non-empty view.
for d in "$MODEL_VIEW/model" "$MODEL_VIEW/engram"; do
  if [ -d "$d" ] && [ -n "$(find "$d" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    fail "$d already has files; remove it yourself or pick a fresh MODEL_VIEW in .env.mia-eaq"
  fi
done
mkdir -p "$MODEL_VIEW/model" "$MODEL_VIEW/engram"

# Hard links need one filesystem (the HF cache and $HOME/models are on the same NVMe here).
src_dev=$(stat -c %d "$MODEL_SNAP")
for d in "$MODEL_VIEW/model" "$MODEL_VIEW/engram"; do
  [ "$(stat -c %d "$d")" = "$src_dev" ] ||
    fail "$d and $MODEL_SNAP are on different filesystems; hard links need one disk (set MODEL_VIEW on the same disk)"
done

link_file() {  # $1 source, $2 link name
  local src
  src=$(readlink -f -- "$1") || fail "cannot resolve $1"
  [ -f "$src" ] || fail "not a file: $1"
  ln -- "$src" "$2" || fail "cannot hard-link $src -> $2"
}

# The engine scans every *.safetensors in /model and reads the JSON/tokenizer files beside them. The chat template is
# installed by scripts/patch_template.py afterwards, so it is skipped here.
n=0
for f in "$MODEL_SNAP"/*; do
  [ -d "$f" ] && continue
  base=${f##*/}
  case "$base" in
    README.md|LICENSE|.gitattributes|chat_template.jinja) continue ;;
  esac
  link_file "$f" "$MODEL_VIEW/model/$base"
  case "$base" in *.safetensors) n=$((n + 1)) ;; esac
done
[ "$n" -gt 0 ] || fail "no *.safetensors in $MODEL_SNAP"

for f in "$ENGRAM_SNAP"/*; do
  [ -d "$f" ] && continue
  link_file "$f" "$MODEL_VIEW/engram/${f##*/}"
done

# The Python recipe serves its patched MiaAI template, not the one of the Mia recipe.
rm -f "$MODEL_VIEW/model/chat_template.jinja"
MODEL_VIEW="$MODEL_VIEW" python3 "$ROOT/scripts/patch_template.py" ||
  fail "scripts/patch_template.py failed"
[ -s "$MODEL_VIEW/model/chat_template.jinja" ] || fail "chat_template.jinja was not written"

say "model:  $n weight shards, $(du -shL "$MODEL_VIEW/model" | cut -f1) resolved"
say "engram: $(du -shL "$MODEL_VIEW/engram" | cut -f1) resolved"
say "view:   $MODEL_VIEW"
say "next:   ENV_FILE=.env.mia-eaq scripts/sync_view.sh"
