#!/usr/bin/env bash
# tfv41-server.service (head, as spark1): wait for both prestart markers, run ./start.sh, then stay alive and
# restart the service when a rank (or the API) goes down.
set -euo pipefail
PROJECT=/home/spark1/projects/DeepSeek-V4.1-Flash-1017-EXL3-TensorFold-2x-DGX-Spark
cd "$PROJECT"
# shellcheck disable=SC1091
set -a
. "$PROJECT/.env.mia-eaq"
set +a
: "${WORKER_SSH:?WORKER_SSH is not set in .env.mia-eaq}"
PORT="${PORT:-8888}"

echo "[tfv41-server] waiting for the head prestart"
for _ in $(seq 1 150); do
  [ -f /run/tfv41-prestart-ready ] && break
  sleep 2
done
[ -f /run/tfv41-prestart-ready ] || { echo "[tfv41-server] ERROR: head prestart is not ready" >&2; exit 1; }

echo "[tfv41-server] waiting for the worker prestart ($WORKER_SSH)"
for _ in $(seq 1 120); do
  ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WORKER_SSH" 'test -f /run/tfv41-prestart-ready' 2>/dev/null && break
  sleep 5
done
ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WORKER_SSH" 'test -f /run/tfv41-prestart-ready' 2>/dev/null ||
  { echo "[tfv41-server] ERROR: worker prestart is not ready" >&2; exit 1; }

echo "[tfv41-server] starting the server"
./start.sh
echo "[tfv41-server] started; monitoring"

trap 'exit 0' TERM INT
fails=0
i=0
while :; do
  if ! docker inspect -f '{{.State.Running}}' tfv41-r0 2>/dev/null | grep -qx true; then
    echo "[tfv41-server] rank 0 is not running" >&2
    exit 1
  fi
  if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WORKER_SSH" \
      "docker inspect -f '{{.State.Running}}' tfv41-r1" 2>/dev/null | grep -qx true; then
    echo "[tfv41-server] rank 1 is not running" >&2
    exit 1
  fi
  if (( i % 6 == 0 )); then
    if curl -fsS -m 10 "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1; then
      fails=0
    else
      fails=$((fails + 1))
      echo "[tfv41-server] API check failed ($fails/3)" >&2
      [ "$fails" -ge 3 ] && exit 1
    fi
  fi
  i=$((i + 1))
  sleep 10
done
