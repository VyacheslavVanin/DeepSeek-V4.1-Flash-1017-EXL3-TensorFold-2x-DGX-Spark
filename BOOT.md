# Automatic start at boot

Two systemd units:

| Unit | Where | Runs as | What |
|---|---|---|---|
| `tfv41-prestart.service` | both Sparks | root | waits for the CX7 link, sets the GPU clock (`nvidia-smi -lgc 2200`), sets MTU 9000 on both rails with `setup_mtu.sh --local`, verifies `active_mtu=4096`, writes `/run/tfv41-prestart-ready` |
| `tfv41-server.service` | head | `spark1` | waits for both prestart markers, runs `./start.sh` (current `.env.mia-eaq`), then monitors rank 0, rank 1 and `/v1/models`; on failure systemd restarts it |

## Files

```text
boot/boot-prestart.sh        # root pre-start; copied to /home/spark1/tfv41-boot
boot/boot-server.sh          # head server; copied to /home/spark1/tfv41-boot
boot/gpu_clock_limit.sh      # edit the clock here; copied to both nodes
setup_mtu.sh                 # added --local for the boot service
systemd/tfv41-prestart.service
systemd/tfv41-server.service
install-boot.sh              # installs/updates the copies and units
```

On a node the runtime copies are in `/home/spark1/tfv41-boot/`. Edit
`boot-prestart.sh` there to add pre-start steps. On the head, edit the project
copy and run `./install-boot.sh` again to sync both nodes, or edit the copies
directly on each node.

## First checkout

```bash
cd /home/spark1/projects/DeepSeek-V4.1-Flash-1017-EXL3-TensorFold-2x-DGX-Spark
./prepare.sh          # models, Docker image, view, sync to worker, CUDA extensions
./install-boot.sh     # boot units (asks for sudo)
sudo reboot           # both Sparks; or start the units now, see below
```

`./prepare.sh --check` only reports what is present/missing; it downloads nothing.
`prepare.sh` creates `.env.mia-eaq` from the tracked example if it is missing; review
`WORKER_SSH`/`HEAD_IP`/`WORKER_IP` before the first run if they differ.

The first service start writes the ~100 GiB rank caches on each node (~15 min).

## Install (once, on the head)

```bash
cd /home/spark1/projects/DeepSeek-V4.1-Flash-1017-EXL3-TensorFold-2x-DGX-Spark
./install-boot.sh        # asks for sudo on the head and the worker
```

Then start once (stop a manually started server first):

```bash
./stop.sh
sudo systemctl start tfv41-prestart.service
ssh spark1@192.168.100.11 'sudo systemctl start tfv41-prestart.service'
sudo systemctl start tfv41-server.service
```

The units are enabled; the next reboot starts them automatically.

## Check

```bash
systemctl status tfv41-prestart.service tfv41-server.service
journalctl -u tfv41-prestart.service -u tfv41-server.service -b
./status.sh
curl http://127.0.0.1:8888/v1/models
```

The server's own startup output is in `journalctl`; the per-request logs remain in
the containers (`docker logs -f tfv41-r0`, and `ssh … docker logs -f tfv41-r1`)
and in `logs/` when the project's `stop.sh` saves them.

## Notes

- MTU is set with `ip link` at boot, not persisted in NetworkManager. If the
  CX7 connection flaps and NM restores MTU 1500, run
  `sudo systemctl restart tfv41-prestart.service` (or `./setup_mtu.sh` for both
  nodes). Adding `802-3-ethernet.mtu 9000` in NM is the permanent alternative.
- The worker runs only `tfv41-prestart.service`; `boot-server.sh` waits for
  `/run/tfv41-prestart-ready` there before starting rank 1.
- `tfv41-server.service` uses `Restart=on-failure`; if a rank or the API dies,
  the service is restarted after 30 s.
- To stop/disable:
  ```bash
  sudo systemctl stop tfv41-server.service
  sudo systemctl disable tfv41-server.service tfv41-prestart.service
  ssh spark1@192.168.100.11 'sudo systemctl disable tfv41-prestart.service'
  ```
