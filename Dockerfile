# Dockerfile for vLLM development
# Use a CUDA base image.
FROM docker.io/nvidia/cuda:12.9.1-devel-ubuntu22.04 AS base

WORKDIR /app

ENV CUDA_MAJOR=12
ENV CUDA_MINOR=9
ENV PYTHON_VERSION=3.12
ENV UCX_VERSION=1.19.0
ENV UCX_HOME=/opt/ucx
ENV CUDA_HOME=/usr/local/cuda/
ENV GDRCOPY_VERSION=2.4
ENV GDRCOPY_HOME=/usr/local
ENV NVSHMEM_VERSION=3.3.20
ENV NVSHMEM_PREFIX=/usr/local/nvshmem
ENV TORCH_BACKEND=cpu
# Work around https://github.com/vllm-project/vllm/issues/18859 and mount gIB if they
# are found for NCCL.
ENV LD_LIBRARY_PATH=/usr/local/gib/lib64:/usr/local/nvidia/lib64:${LD_LIBRARY_PATH}:

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'tzdata tzdata/Areas select America' | debconf-set-selections \
    && echo 'tzdata tzdata/Zones/America select New_York' | debconf-set-selections \
    && apt-get -qq update \
    && apt-get -qq install -y ccache software-properties-common git wget curl \
    && for i in 1 2 3; do \
        add-apt-repository -y ppa:deadsnakes/ppa && break || \
        { echo "Attempt $i failed, retrying in 5s..."; sleep 5; }; \
    done \
    # NVSHMEM
    #&& wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    #&& dpkg -i cuda-keyring_1.1-1_all.deb \
    # Mellanox OFED
    && wget -qO - https://www.mellanox.com/downloads/ofed/RPM-GPG-KEY-Mellanox | apt-key add - \
    && cd /etc/apt/sources.list.d/ && wget https://linux.mellanox.com/public/repo/mlnx_ofed/24.10-0.7.0.0/ubuntu22.04/mellanox_mlnx_ofed.list \
    # Update all
    && apt-get -qq update \
    && apt-get -qq install -y --no-install-recommends \
      # Python and related tools
      python${PYTHON_VERSION} \
      python${PYTHON_VERSION}-dev \
      python${PYTHON_VERSION}-venv \
      python${PYTHON_VERSION}-dbg \
      ca-certificates \
      htop \
      iputils-ping net-tools dnsutils \
      vim ripgrep bat clangd fuse fzf \
      nodejs npm clang fd-find xclip \
      zsh \
      # Build tools for UCX, NVSHMEM, etc.
      build-essential \
      autoconf automake libtool pkg-config \
      ninja-build cmake \
      # Other dependencies
      libnuma1 libsubunit0 libpci-dev libibverbs-dev \
      # MPI / PMIx / libfabric for NVSHMEM
      libopenmpi-dev openmpi-bin \
      libpmix-dev libfabric-dev \
      datacenter-gpu-manager \
      # Debugging tools
      kmod pciutils binutils \
      gdb strace lsof \
      # Should be included for GCP setup, uncomment if they go missing
      libnl-3-200 libnl-route-3-200 \
      # NVSHMEM - disabled due to link errors on DeepEP python package
      # nvshmem-cuda-${CUDA_MAJOR} \
      # Allow NVSHMEM to build nvshmem4py
      python3.10-venv python3.10-dev \
      # Mellanox OFED
      ibverbs-utils libibverbs-dev libibumad3 libibumad-dev librdmacm-dev rdmacm-utils infiniband-diags ibverbs-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \

    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && python${PYTHON_VERSION} -m ensurepip --upgrade \
    && python${PYTHON_VERSION} -m pip install --upgrade pip setuptools wheel

# Install UV
RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR="/usr/local/bin/" sh

# Install dependencies and NIXL (python)
COPY install-scripts/ /install-scripts/
RUN chmod +x /install-scripts/*.sh \
    && cd /install-scripts \
    && ./base-deps.sh

# For neovim.appimage
ENV APPIMAGE_EXTRACT_AND_RUN=1

ENTRYPOINT ["/app/code/venv/bin/vllm", "serve"]

#==============================================================================

FROM base AS deepep

# Install specific versions
SHELL ["/bin/bash", "-ec"]
RUN CMAKE_DISABLE_FIND_PACKAGE_CUDA=ON VLLM_TARGET_DEVICE=cpu VLLM_USE_PRECOMPILED=0 MAX_JOBS=$(( "$(nproc)" * 3 / 4 )) /install-scripts/vllm.sh

ENTRYPOINT ["/app/code/venv/bin/vllm", "serve"]
