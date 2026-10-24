#!/usr/bin/env bash
# Copy MODEL_VIEW (model/ and engram/) to the worker with rsync. It never deletes anything on the worker; a re-run
# resumes partial files. Run after scripts/link_mia_view.sh.
#
# Usage: ENV_FILE=.env.mia-eaq scripts/sync_view.sh
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

fail() { echo "[sync-view] ERROR: $*" >&2; exit 1; }
say() { log "$@"; }

[ "${VARIANT:-}" = mia-eaq ] ||
  fail "VARIANT is '${VARIANT:-}', not 'mia-eaq': run with ENV_FILE=.env.mia-eaq"
: "${MODEL_VIEW:?MODEL_VIEW is not set}"
MODEL_VIEW=${MODEL_VIEW%/}
[ -d "$MODEL_VIEW/model" ] || fail "no $MODEL_VIEW/model; run scripts/link_mia_view.sh first"
[ -d "$MODEL_VIEW/engram" ] || fail "no $MODEL_VIEW/engram; run scripts/link_mia_view.sh first"
wssh true 2>/dev/null || fail "ssh to $WORKER_SSH failed"
wssh 'command -v rsync >/dev/null' || fail "rsync is not installed on $WORKER_SSH"

view_size=$(du -sb "$MODEL_VIEW" | cut -f1)
q=$(printf '%q' "$MODEL_VIEW")
wssh "mkdir -p $q"
free=$(wssh "df -B1 --output=avail $q | tail -1" | tr -dc 0-9)
need=$((view_size + 10 * 1024 ** 3))
[ "${free:-0}" -ge "$need" ] ||
  fail "$WORKER_SSH has $((free / 1024 ** 3)) GiB free at $MODEL_VIEW; need $((need / 1024 ** 3)) GiB"

say "copying $MODEL_VIEW ($((view_size / 1024 ** 3)) GiB) to $WORKER_SSH (no --delete)"
rsync -a --partial-dir=.rsync-partial --info=progress2 \
  -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
  "$MODEL_VIEW/" "$WORKER_SSH:$MODEL_VIEW/"

bytes_of() { (cd "$1" && find model engram -type f -printf '%s\n' | awk '{s += $1} END {printf "%d", s + 0}'); }
want=$(bytes_of "$MODEL_VIEW")
have=$(wssh "cd $q && find model engram -type f -printf '%s\n' | awk '{s += \$1} END {printf \"%d\", s + 0}'")
[ "$want" = "$have" ] ||
  fail "worker view is $have bytes, head view is $want: rerun this script (rsync resumes) or inspect $WORKER_SSH:$MODEL_VIEW"
say "worker view is complete ($want bytes)"
