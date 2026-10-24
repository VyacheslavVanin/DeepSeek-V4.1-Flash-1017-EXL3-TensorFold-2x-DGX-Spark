#!/usr/bin/env bash
# Set MTU 9000 on the direct ConnectX-7 link of both Sparks (both rails), or show/undo it.
# Runtime only: no NetworkManager/networkd change, so a reboot restores the old MTU. The Wi-Fi interface is not touched.
# Run on the head; sudo will ask for a password here and on the worker. Run it only if the Python engine reports
# "transport retry counter exceeded" (its RDMA gather needs an active MTU of 4096).
#
# Usage: ./setup_mtu.sh [--check|--set|--undo] [--env FILE] [--yes]
#   (no action)  show the current MTU, ask, then set 9000
#   --check      only show the current MTU
#   --undo       restore 1500
#   --yes, -y    do not ask for confirmation (sudo still asks for its password)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env.mia-eaq}"
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac
ACTION=set
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --set) ACTION=set ;;
    --undo) ACTION=undo ;;
    --yes|-y) ASSUME_YES=1 ;;
    --env) ENV_FILE=$2; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE: cp .env.mia-eaq.example .env.mia-eaq (or run scripts/bootstrap-mia-eaq.sh)" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${WORKER_SSH:?WORKER_SSH is not set in $ENV_FILE}"
MTU=9000
[ "$ACTION" = undo ] && MTU=1500

# The NCCL/rendezvous netdev plus the netdev behind every RDMA device used by TensorFold.
devs=()
[ -n "${NCCL_SOCKET_IFNAME:-}" ] && devs+=("$NCCL_SOCKET_IFNAME")
IFS=, read -ra rds <<< "${RDMA_DEVICES:-}"
for rd in "${rds[@]}"; do
  nd=$(ls "/sys/class/infiniband/$rd/device/net" 2>/dev/null | head -1) || true
  [ -n "$nd" ] && devs+=("$nd")
done
mapfile -t devs < <(printf '%s\n' "${devs[@]}" | awk 'NF && !seen[$0]++')
[ "${#devs[@]}" -gt 0 ] || { echo "no netdevs found (NCCL_SOCKET_IFNAME / RDMA_DEVICES)" >&2; exit 1; }

mtu_of() { ip -o link show dev "$1" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p'; }
worker_mtu_of() {
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" \
    "ip -o link show dev '$1' 2>/dev/null | sed -n 's/.* mtu \\([0-9]*\\).*/\\1/p'" 2>/dev/null || true
}
show() {
  echo
  printf '%-18s %-10s %-10s\n' netdev head worker
  for d in "${devs[@]}"; do
    printf '%-18s %-10s %-10s\n' "$d" "$(mtu_of "$d" || true)" "$(worker_mtu_of "$d" || true)"
  done
}

show
[ "$ACTION" = check ] && exit 0
if [ "$ASSUME_YES" != 1 ]; then
  printf 'Set MTU %s on %s (head and %s)? [y/N] ' "$MTU" "${devs[*]}" "$WORKER_SSH"
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi

for d in "${devs[@]}"; do
  cur=$(mtu_of "$d" || true)
  if [ "$cur" = "$MTU" ]; then
    echo "[head]   $d already $MTU"
  else
    echo "[head]   $d: ${cur:-missing} -> $MTU"
    sudo ip link set dev "$d" mtu "$MTU"
  fi
  curw=$(worker_mtu_of "$d" || true)
  if [ "$curw" = "$MTU" ]; then
    echo "[worker] $d already $MTU"
  else
    echo "[worker] $d: ${curw:-missing} -> $MTU"
    ssh -t -o ConnectTimeout=10 "$WORKER_SSH" "sudo ip link set dev '$d' mtu $MTU"
  fi
done

show
# active_mtu can take a moment to follow the netdev MTU.
for rd in "${rds[@]}"; do
  am=""
  for _ in 1 2 3 4 5; do
    am=$(ibv_devinfo -d "$rd" -i 1 2>/dev/null | awk '/active_mtu/ {print $2; exit}')
    [ "$am" = 4096 ] && break
    sleep 1
  done
  amw=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" \
    "ibv_devinfo -d '$rd' -i 1 2>/dev/null | awk '/active_mtu/ {print \$2; exit}'" 2>/dev/null || true)
  echo "active_mtu: $rd head=${am:-unknown} worker=${amw:-unknown} (want 4096)"
done
echo
echo "done. To restore the previous MTU: $0 --undo"
