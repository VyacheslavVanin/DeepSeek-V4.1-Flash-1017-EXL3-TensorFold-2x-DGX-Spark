#!/usr/bin/env bash
# Prepare the Mia EAQ variant on a clean checkout:
#   1. create .env.mia-eaq from the tracked .env.mia-eaq.example when it is missing;
#   2. pull the engine image on the head and the worker (the image is public);
#   3. check the model view and the link MTU, and print the remaining steps.
# It does not start the server and does not download the 390 GiB model view.
# Run on the head, from the project root. Safe to re-run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env.mia-eaq}"
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac

created=0
if [ ! -f "$ENV_FILE" ]; then
  [ -f "$ROOT/.env.mia-eaq.example" ] || { echo "missing $ROOT/.env.mia-eaq.example" >&2; exit 1; }
  cp -p "$ROOT/.env.mia-eaq.example" "$ENV_FILE"
  created=1
  echo "[bootstrap] created $ENV_FILE from .env.mia-eaq.example"
fi

# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a
: "${IMAGE:?IMAGE is not set in $ENV_FILE}"
: "${WORKER_SSH:?WORKER_SSH is not set in $ENV_FILE}"
: "${MODEL_VIEW:?MODEL_VIEW is not set in $ENV_FILE}"
command -v docker >/dev/null || { echo "docker is not installed on the head" >&2; exit 1; }

if [ "$created" = 1 ]; then
  echo "[bootstrap] review HEAD_IP / WORKER_IP / WORKER_SSH in $ENV_FILE if this pair differs"
fi

remote() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" "$@"; }
remote true 2>/dev/null || {
  echo "[bootstrap] cannot ssh to $WORKER_SSH; edit WORKER_SSH in $ENV_FILE and rerun" >&2
  exit 1
}

echo "[bootstrap] engine image: $IMAGE"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[bootstrap] head: present"
else
  echo "[bootstrap] head: pulling"
  docker pull "$IMAGE"
fi
if remote "docker image inspect '$IMAGE' >/dev/null 2>&1"; then
  echo "[bootstrap] worker: present"
else
  echo "[bootstrap] worker: pulling"
  remote "docker pull '$IMAGE'"
fi

head_id=$(docker image inspect -f '{{.Id}}' "$IMAGE")
worker_id=$(remote "docker image inspect -f '{{.Id}}' '$IMAGE'")
if [ "$head_id" != "$worker_id" ]; then
  echo "[bootstrap] image IDs differ: head $head_id, worker $worker_id" >&2
  exit 1
fi
arch=$(docker image inspect -f '{{.Architecture}}' "$IMAGE")
echo "[bootstrap] head and worker hold $head_id (arch $arch)"
[ "$arch" = "arm64" ] || echo "[bootstrap] warning: the Sparks need linux/arm64, this image is $arch"

if [ -f "$MODEL_VIEW/model/chat_template.jinja" ] && [ -d "$MODEL_VIEW/engram" ]; then
  echo "[bootstrap] view: $MODEL_VIEW"
else
  cat <<EOF
[bootstrap] view is not ready: $MODEL_VIEW
  The Mia checkpoint and Engram tables must be in ~/.cache/huggingface first:
    Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw @ 45ee5d0f (39 shards)
    deepseek-ai/DeepSeek-V4.1-Flash-1017 @ 1bae0e10 (shards 47 and 48)
  Then run:
    ./scripts/link_mia_view.sh
    ./scripts/sync_view.sh
EOF
fi

if [ -x "$ROOT/setup_mtu.sh" ]; then
  echo "[bootstrap] link MTU (set 9000 if RDMA reports transport retry counter exceeded):"
  "$ROOT/setup_mtu.sh" --env "$ENV_FILE" --check || true
fi

cat <<EOF

[bootstrap] next:
  ./start.sh          # start both ranks (uses .env.mia-eaq by default)
  ./status.sh         # containers and API
  ./verify.sh         # five API checks
  ./stop.sh           # stop both ranks
  For a source build instead of the published image: ./docker/build.sh
EOF
