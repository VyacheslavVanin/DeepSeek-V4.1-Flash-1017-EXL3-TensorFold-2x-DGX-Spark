# TensorFold (Python engine, DeepSeek-V4.1 family) on NVIDIA's NGC PyTorch 26.07 base for DGX Spark (GB10, sm_121,
# aarch64, CUDA 13). The "grammar" extra adds xgrammar (structured output). The constraint file holds NGC's own torch
# build, so pip does not replace it with a PyPI wheel. Build with docker/build.sh (it passes TF_REPO and TF_COMMIT).
# BASE_IMAGE can be overridden for a local fallback base; the default is the clean NGC image.
ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3
FROM ${BASE_IMAGE}

ARG TF_REPO=https://github.com/Elevatormusic/TensorFold.git
ARG TF_COMMIT
# A fallback base (the Mia Zig image) already has /opt/tensorfold; clear it so the clone below can use that path.
RUN rm -rf /opt/tensorfold
RUN test -n "$TF_COMMIT" || { echo "set --build-arg TF_COMMIT=<commit>"; exit 1; } \
 && git clone --filter=blob:none "$TF_REPO" /opt/tensorfold \
 && git -C /opt/tensorfold checkout --detach "$TF_COMMIT"
RUN pip freeze | grep -iE "^(torch|torchvision|triton|numpy)==" > /tmp/ngc-pins.txt \
 && pip install --no-cache-dir -c /tmp/ngc-pins.txt -e "/opt/tensorfold[grammar]" \
 && python -c "import importlib.metadata, tensorfold, torch; print('tensorfold', tensorfold.__file__, 'xgrammar', importlib.metadata.version('xgrammar'), 'torch', torch.__version__)"
ENV TORCH_EXTENSIONS_DIR=/cache/torch_extensions
WORKDIR /opt/tensorfold
