# Shared by start.sh, stop.sh, status.sh and verify.sh: reads .env and defines the helpers. Source it; do not run it.
# shellcheck shell=bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ENV_FILE selects an alternate recipe file (for example .env.mia-eaq); the default is still .env.
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac
if [ ! -f "$ENV_FILE" ]; then
  echo "no $ENV_FILE: copy .env.example to .env and edit it" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

API="http://${BIND_HOST/0.0.0.0/127.0.0.1}:${PORT}/v1"
# shellcheck disable=SC2034  # the scripts that source this file use STORE_PORT and LOGS
STORE_PORT=29551                 # TensorFold's rank-0 rendezvous port (--master-port default)
# shellcheck disable=SC2034
LOGS="$ROOT/logs"

log() { echo "[tfv41 $(date -u +%H:%M:%SZ)] $*"; }
wssh() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" "$@"; }
auth() { [ -n "${API_KEY_FILE:-}" ] && printf 'Authorization: Bearer %s' "$(grep -v '^#' "$API_KEY_FILE" | head -1 | sed 's/^.*: *//')"; }
healthy() { curl -fsS -m 10 -H "$(auth)" "$API/models" 2>/dev/null | grep -q "\"$SERVED_NAME\""; }
