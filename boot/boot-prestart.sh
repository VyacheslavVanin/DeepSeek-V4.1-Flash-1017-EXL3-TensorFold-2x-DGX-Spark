#!/usr/bin/env bash
# tfv41-prestart.service (root, both Sparks): wait for the CX7 link, limit the GPU clock, set the local MTU,
# verify the RDMA active MTU, and leave /run/tfv41-prestart-ready for tfv41-server.service.
# Easy to extend: add steps between the numbered sections below.
set -euo pipefail
export HOME="${HOME:-/home/spark1}"
BOOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT=/home/spark1/projects/DeepSeek-V4.1-Flash-1017-EXL3-TensorFold-2x-DGX-Spark
MARKER=/run/tfv41-prestart-ready
rm -f "$MARKER"

# The head has the project .env; the worker uses the defaults below.
if [ -f "$PROJECT/.env.mia-eaq" ]; then
  # shellcheck disable=SC1090
  set -a; . "$PROJECT/.env.mia-eaq"; set +a
fi
NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f1np1}"
RDMA_DEVICES="${RDMA_DEVICES:-rocep1s0f1,roceP2p1s0f1}"

# 1. the two CX7 rails: UP and with an IPv4 address
devs=()
[ -n "$NCCL_SOCKET_IFNAME" ] && devs+=("$NCCL_SOCKET_IFNAME")
IFS=, read -ra rds <<< "$RDMA_DEVICES"
for rd in "${rds[@]}"; do
  nd=$(ls "/sys/class/infiniband/$rd/device/net" 2>/dev/null | head -1) || true
  [ -n "$nd" ] && devs+=("$nd")
done
mapfile -t devs < <(printf '%s\n' "${devs[@]}" | awk 'NF && !seen[$0]++')
echo "[tfv41-prestart] waiting for CX7: ${devs[*]}"
ok=0
for _ in $(seq 1 120); do
  ok=1
  for d in "${devs[@]}"; do
    ip -o link show dev "$d" 2>/dev/null | grep -q "state UP" || ok=0
    ip -o -4 addr show dev "$d" 2>/dev/null | grep -q "inet " || ok=0
  done
  [ "$ok" = 1 ] && break
  sleep 1
done
[ "$ok" = 1 ] || { echo "[tfv41-prestart] ERROR: CX7 link is not ready: ${devs[*]}" >&2; exit 1; }

# 2. NVIDIA driver
echo "[tfv41-prestart] waiting for nvidia-smi"
for _ in $(seq 1 60); do nvidia-smi -L >/dev/null 2>&1 && break; sleep 2; done
nvidia-smi -L >/dev/null 2>&1 || { echo "[tfv41-prestart] ERROR: nvidia-smi is not ready" >&2; exit 1; }

# 3. GPU clock limit (the same script the head keeps in projects/temperatures)
GPU="$BOOT_DIR/gpu_clock_limit.sh"
[ -x "$GPU" ] || GPU="$PROJECT/../temperatures/gpu_clock_limit.sh"
if [ -x "$GPU" ]; then
  echo "[tfv41-prestart] GPU clock: $GPU"
  "$GPU" || echo "[tfv41-prestart] WARN: GPU clock script failed; continuing" >&2
else
  echo "[tfv41-prestart] GPU clock: nvidia-smi -lgc 2200"
  nvidia-smi -lgc 2200 || echo "[tfv41-prestart] WARN: nvidia-smi -lgc failed; continuing" >&2
fi

# 4. MTU on this node only (no SSH, no password prompt: the service runs as root)
SETUP="$BOOT_DIR/setup_mtu.sh"
[ -x "$SETUP" ] || SETUP="$PROJECT/setup_mtu.sh"
if [ -f "$PROJECT/.env.mia-eaq" ]; then
  "$SETUP" --local --yes --env "$PROJECT/.env.mia-eaq"
else
  "$SETUP" --local --yes
fi

# 5. the RDMA ports must have an active MTU of 4096
for rd in "${rds[@]}"; do
  am=""
  for _ in 1 2 3 4 5; do
    am=$(ibv_devinfo -d "$rd" -i 1 2>/dev/null | awk '/active_mtu/ {print $2; exit}')
    [ "$am" = 4096 ] && break
    sleep 1
  done
  [ "$am" = 4096 ] || { echo "[tfv41-prestart] ERROR: $rd active_mtu=${am:-unknown}, want 4096" >&2; exit 1; }
done

install -m 644 /dev/null "$MARKER"
echo "[tfv41-prestart] ready"
