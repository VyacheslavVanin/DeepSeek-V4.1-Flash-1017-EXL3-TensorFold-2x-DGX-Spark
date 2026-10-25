#!/bin/bash
# GPU clock limit, run as root by tfv41-prestart.service on both Sparks.
# Edit the clock here; install-boot.sh copies this file to /home/spark1/tfv41-boot on both nodes.
sudo nvidia-smi -lgc 2200
