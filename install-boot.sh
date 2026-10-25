#!/usr/bin/env bash
# Install/refresh the TensorFold boot scripts and systemd units on the head and the worker.
# Run on the head as spark1 from the project root; it asks for sudo on each node.
# It does not start anything: the commands to start are printed at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BOOT="$ROOT/boot"
ENV_FILE="$ROOT/.env.mia-eaq"
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${WORKER_SSH:?WORKER_SSH is not set in .env.mia-eaq}"

for f in "$BOOT/boot-prestart.sh" "$BOOT/boot-server.sh" "$BOOT/gpu_clock_limit.sh" \
         "$ROOT/setup_mtu.sh" \
         "$ROOT/systemd/tfv41-prestart.service" "$ROOT/systemd/tfv41-server.service"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

echo "[install-boot] head: /home/spark1/tfv41-boot"
install -d "$HOME/tfv41-boot"
install -m 755 "$BOOT/boot-prestart.sh" "$HOME/tfv41-boot/boot-prestart.sh"
install -m 755 "$BOOT/boot-server.sh" "$HOME/tfv41-boot/boot-server.sh"
install -m 755 "$BOOT/gpu_clock_limit.sh" "$HOME/tfv41-boot/gpu_clock_limit.sh"
install -m 755 "$ROOT/setup_mtu.sh" "$HOME/tfv41-boot/setup_mtu.sh"

echo "[install-boot] worker: $WORKER_SSH:/home/spark1/tfv41-boot"
ssh -n -o BatchMode=yes "$WORKER_SSH" 'mkdir -p /home/spark1/tfv41-boot'
scp -p "$BOOT/boot-prestart.sh" "$BOOT/gpu_clock_limit.sh" "$ROOT/setup_mtu.sh" \
  "$WORKER_SSH:/home/spark1/tfv41-boot/"
ssh -n -o BatchMode=yes "$WORKER_SSH" 'chmod +x /home/spark1/tfv41-boot/*.sh'

echo "[install-boot] head: systemd units (sudo)"
sudo install -m 644 "$ROOT/systemd/tfv41-prestart.service" /etc/systemd/system/tfv41-prestart.service
sudo install -m 644 "$ROOT/systemd/tfv41-server.service" /etc/systemd/system/tfv41-server.service
sudo systemctl daemon-reload
sudo systemctl enable tfv41-prestart.service tfv41-server.service

echo "[install-boot] worker: tfv41-prestart.service (sudo)"
scp -p "$ROOT/systemd/tfv41-prestart.service" "$WORKER_SSH:/tmp/tfv41-prestart.service"
ssh -t "$WORKER_SSH" \
  "sudo install -m 644 /tmp/tfv41-prestart.service /etc/systemd/system/tfv41-prestart.service && sudo systemctl daemon-reload && sudo systemctl enable tfv41-prestart.service && rm -f /tmp/tfv41-prestart.service"

cat <<EOF

[install-boot] installed. Nothing was started.

The boot scripts are in /home/spark1/tfv41-boot on both nodes. The GPU clock is copied from
$BOOT/gpu_clock_limit.sh; edit that copy (or this project copy and rerun install-boot.sh).
To change a pre-start step, edit /home/spark1/tfv41-boot/boot-prestart.sh.

Start now (if the manual server is running, stop it first with ./stop.sh):
  sudo systemctl start tfv41-prestart.service
  ssh $WORKER_SSH 'sudo systemctl start tfv41-prestart.service'
  sudo systemctl start tfv41-server.service

Check:
  systemctl status tfv41-prestart.service tfv41-server.service
  journalctl -u tfv41-prestart.service -u tfv41-server.service -b
  ./status.sh
  curl http://127.0.0.1:${PORT:-8888}/v1/models

The units are enabled, so the next reboot starts them automatically.
EOF
