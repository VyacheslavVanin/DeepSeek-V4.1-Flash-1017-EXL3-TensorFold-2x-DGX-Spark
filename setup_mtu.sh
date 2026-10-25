#!/usr/bin/env bash
# Set MTU 9000 on the direct ConnectX-7 link of both Sparks (both rails), or show/undo it.
# Runtime only: no NetworkManager/networkd change, so a reboot restores the old MTU. The Wi-Fi interface is not touched.
# Run on the head; sudo will ask for a password here and on the worker. Run it only if the Python engine reports
# "transport retry counter exceeded" (its RDMA gather needs an active MTU of 4096).
#
# Usage: ./setup_mtu.sh [--check|--set|--undo] [--local] [--env FILE] [--yes]
#   (no action)  show the current MTU, ask, then set 9000
#   --check      only show the current MTU
#   --undo       restore 1500
#   --local      this node only: no SSH; defaults when no env file (for the boot service, as root)
#   --yes, -y    do not ask for confirmation (sudo still asks for its password)
set -euo pipefail
export HOME="${HOME:-/home/spark1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env.mia-eaq}"
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac
ACTION=set
LOCAL=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) ACTION=check ;;
    --set) ACTION=set ;;
    --undo) ACTION=undo ;;
    --local) LOCAL=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --env) ENV_FILE=$2; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$ENV_FILE" in /*) ;; *) ENV_FILE="$ROOT/$ENV_FILE" ;; esac
# A boot service has no TTY: never wait for a confirmation there.
if [ "$LOCAL" = 1 ] && [ ! -t 0 ]; then ASSUME_YES=1; fi

# The boot service runs this as root from /home/spark1/tfv41-boot, where there is no .env.
# In --local mode the defaults below are enough; a .env is used when present.
if [ "$LOCAL" = 1 ]; then
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
  : "${NCCL_SOCKET_IFNAME:=enp1s0f1np1}"
  : "${RDMA_DEVICES:=rocep1s0f1,roceP2p1s0f1}"
else
  [ -f "$ENV_FILE" ] || { echo "no $ENV_FILE: cp .env.mia-eaq.example .env.mia-eaq (or run scripts/bootstrap-mia-eaq.sh)" >&2; exit 1; }
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  : "${WORKER_SSH:?WORKER_SSH is not set in $ENV_FILE}"
fi

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
  if [ "$LOCAL" = 1 ]; then
    printf '%-18s %-10s\n' netdev mtu
    for d in "${devs[@]}"; do printf '%-18s %-10s\n' "$d" "$(mtu_of "$d" || true)"; done
  else
    printf '%-18s %-10s %-10s\n' netdev head worker
    for d in "${devs[@]}"; do
      printf '%-18s %-10s %-10s\n' "$d" "$(mtu_of "$d" || true)" "$(worker_mtu_of "$d" || true)"
    done
  fi
}
run_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

show
[ "$ACTION" = check ] && exit 0
if [ "$ASSUME_YES" != 1 ]; then
  if [ "$LOCAL" = 1 ]; then
    printf 'Set MTU %s on this node (%s)? [y/N] ' "$MTU" "${devs[*]}"
  else
    printf 'Set MTU %s on %s (head and %s)? [y/N] ' "$MTU" "${devs[*]}" "$WORKER_SSH"
  fi
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi

for d in "${devs[@]}"; do
  cur=$(mtu_of "$d" || true)
  if [ "$cur" = "$MTU" ]; then
    echo "[local]  $d already $MTU"
  else
    echo "[local]  $d: ${cur:-missing} -> $MTU"
    run_root ip link set dev "$d" mtu "$MTU"
  fi
  [ "$LOCAL" = 1 ] && continue
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
  if [ "$LOCAL" = 1 ]; then
    echo "active_mtu: $rd local=${am:-unknown} (want 4096)"
  else
    amw=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_SSH" \
      "ibv_devinfo -d '$rd' -i 1 2>/dev/null | awk '/active_mtu/ {print \$2; exit}'" 2>/dev/null || true)
    echo "active_mtu: $rd head=${am:-unknown} worker=${amw:-unknown} (want 4096)"
  fi
done
echo
echo "done. To restore the previous MTU: $0 --undo"
