# Dockerfile for llm-d on GKE
# This image works around an issue with UBI RDMA drivers and NVSHMEM
# which has not yet been resolved.

# Use a CUDA base image.
FROM docker.io/nvidia/cuda:12.9.1-devel-ubuntu22.04 AS base

WORKDIR /app

ENV CUDA_MAJOR=12
ENV CUDA_MINOR=9
ENV PYTHON_VERSION=3.12
ENV UCX_VERSION=1.19.0
ENV UCX_HOME=/opt/ucx
ENV CUDA_HOME=/usr/local/cuda/
ENV GDRCOPY_VERSION=2.5.1
ENV GDRCOPY_HOME=/usr/local
ENV NVSHMEM_VERSION=3.3.20
ENV NVSHMEM_PREFIX=/usr/local/nvshmem
ENV TORCH_CUDA_ARCH_LIST="9.0a 10.0+PTX"
ENV CMAKE_CUDA_ARCHITECTURES="90a;100"
# Work around https://github.com/vllm-project/vllm/issues/18859 and mount gIB if they
# are found for NCCL.
ENV LD_LIBRARY_PATH=/usr/local/gib/lib64:/usr/local/nvidia/lib64:${LD_LIBRARY_PATH}:
# For neovim.appimage
ENV APPIMAGE_EXTRACT_AND_RUN=1
ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'tzdata tzdata/Areas select America' | debconf-set-selections \
    && echo 'tzdata tzdata/Zones/America select New_York' | debconf-set-selections \
    && apt-get -qq update \
    && apt-get -qq install -y ccache software-properties-common git wget curl \
    && for i in 1 2 3; do \
        add-apt-repository -y ppa:deadsnakes/ppa && break || \
        { echo "Attempt $i failed, retrying in 5s..."; sleep 5; }; \
    done \
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
      libnuma1 libsubunit0 libpci-dev \
      # NVSHMEM dependency
      datacenter-gpu-manager \
      # Allows NVSHMEM to build nvshmem4py
      python3.10-venv python3.10-dev \
      # Debugging tools
      kmod pciutils binutils \
      gdb strace lsof \
      # GCP leverages these libraries for NCCL initialization
      libnl-3-200 libnl-route-3-200 \
      # Mellanox OFED
      ibverbs-utils libibumad3 \
      # Debugging tools for RDMA
      rdmacm-utils ibverbs-utils libibumad-dev librdmacm-dev infiniband-diags libibverbs-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \

    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && python${PYTHON_VERSION} -m ensurepip --upgrade \
    && python${PYTHON_VERSION} -m pip install --upgrade pip setuptools wheel

# --- Build and Install GDRCopy from Source ---
RUN cd /tmp && \
    git clone https://github.com/NVIDIA/gdrcopy.git && \
    cd gdrcopy && \
    git checkout tags/v${GDRCOPY_VERSION} && \
    make prefix=${GDRCOPY_HOME} lib_install exes_install && \
    ldconfig && \
    rm -rf /tmp/gdrcopy

ENV PATH=${GDRCOPY_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${GDRCOPY_HOME}/lib:${LD_LIBRARY_PATH}
ENV CPATH=${GDRCOPY_HOME}/include:${CPATH}
ENV LIBRARY_PATH=${GDRCOPY_HOME}/lib:${LIBRARY_PATH}

# --- Build and Install UCX from Source ---
RUN cd /tmp \
    && wget https://github.com/openucx/ucx/releases/download/v${UCX_VERSION}/ucx-${UCX_VERSION}.tar.gz \
    && tar -zxf ucx-${UCX_VERSION}.tar.gz \
    && cd ucx-${UCX_VERSION} \
    && ./contrib/configure-release      \
        --prefix=${UCX_HOME}            \
        --with-cuda=${CUDA_HOME}        \
        --with-gdrcopy=${GDRCOPY_HOME}  \
        --enable-shared         \
        --disable-static        \
        --disable-doxygen-doc   \
        --enable-optimizations  \
        --enable-cma            \ 
        --enable-devel-headers  \
        --with-verbs            \
        --with-dm               \ 
        --enable-mt             \
    && make -j$(nproc) && make install-strip \
    && rm -rf /tmp/ucx-${UCX_VERSION}*

ENV PATH=${UCX_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${UCX_HOME}/lib:${LD_LIBRARY_PATH}
ENV CPATH=${UCX_HOME}/include:${CPATH}
ENV LIBRARY_PATH=${UCX_HOME}/lib:${LIBRARY_PATH}
ENV PKG_CONFIG_PATH=${UCX_HOME}/lib/pkgconfig:${PKG_CONFIG_PATH}

# --- Build and Install NVSHMEM from Source ---
ENV MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi
ENV CPATH=${MPI_HOME}/include:${CPATH}
RUN cd /tmp \
    && wget https://developer.download.nvidia.com/compute/redist/nvshmem/${NVSHMEM_VERSION}/source/nvshmem_src_cuda${CUDA_MAJOR}-all-all-${NVSHMEM_VERSION}.tar.gz \
    && tar -xzf nvshmem_src_cuda${CUDA_MAJOR}-all-all-${NVSHMEM_VERSION}.tar.gz \
    && cd nvshmem_src \
    && mkdir -p build \
    && cd build \
    && cmake \
      -G Ninja \
      -DNVSHMEM_PREFIX=${NVSHMEM_PREFIX} \
      -DCMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES} \
      -DNVSHMEM_PMIX_SUPPORT=0           \
      -DNVSHMEM_LIBFABRIC_SUPPORT=0      \
      -DNVSHMEM_IBRC_SUPPORT=1           \
      -DNVSHMEM_IBGDA_SUPPORT=1          \
      -DNVSHMEM_IBDEVX_SUPPORT=1         \
      -DNVSHMEM_SHMEM_SUPPORT=0          \
      -DNVSHMEM_USE_GDRCOPY=1            \
      -DNVSHMEM_USE_NCCL=0               \
      -DNVSHMEM_BUILD_TESTS=0            \
      -DNVSHMEM_BUILD_EXAMPLES=0         \
      -DNVSHMEM_TIMEOUT_DEVICE_POLLING=0 \
      -DLIBFABRIC_HOME=/usr              \
      -DGDRCOPY_HOME=${GDRCOPY_HOME}     \
      -DNVSHMEM_MPI_SUPPORT=0            \
      -DNVSHMEM_DISABLE_CUDA_VMM=1       \
      .. \
    && ninja -j$(nproc) \
    && ninja -j$(nproc) install \
    && rm -rf /tmp/nvshmem_src*

ENV PATH=${NVSHMEM_PREFIX}/bin:${PATH}
ENV LD_LIBRARY_PATH=${NVSHMEM_PREFIX}/lib:${LD_LIBRARY_PATH}
ENV CPATH=${NVSHMEM_PREFIX}/include:${CPATH}
ENV LIBRARY_PATH=${NVSHMEM_PREFIX}/lib:${LIBRARY_PATH}
ENV PKG_CONFIG_PATH=${NVSHMEM_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}

# Install UV, dependencies and NIXL (python)
SHELL ["/bin/bash", "-ec"]
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin/" sh && \
    # Python / toolchain
    VENV_PATH="${VENV_PATH:-/app/venv}" && \
    PYTHON_VERSION="${PYTHON_VERSION:-3.12}" && \
    PYTHON_COMMAND="${PYTHON_COMMAND:-python${PYTHON_VERSION}}" && \
    PY_TAG="${PYTHON_VERSION//./}" && \
    UV="${UV_INSTALL_PATH:-/usr/local/bin/uv}" && \
    PYTHON="${VENV_PATH}/bin/python" && \
    PATH="${VENV_PATH}/bin:${PATH}" && \
    "${UV}" venv "${VENV_PATH}" && \
    # Base dependencies
    upip() { "${UV}" pip install --python "${PYTHON}" --no-progress --no-cache-dir --torch-backend=cu${CUDA_MAJOR}${CUDA_MINOR} "$@"; } && \
    upip pandas datasets rust-just regex setuptools-scm cmake && \
    upip nixl "nvshmem4py-cu${CUDA_MAJOR}" cuda-python && \
    # PIP in venv so 'python -m pip' works inside DeepEP build step
    "${PYTHON}" -m ensurepip --upgrade && \
    "${PYTHON}" -m pip install -U pip wheel setuptools && \
    # Clone and change directory
    git_clone_and_cd() { local url=$1 dir=$2 branch=${3:-main} commit=${4:-}; git clone --depth=1 --branch "${branch}" "${url}" "${dir}"; if [[ -n "${commit}" ]]; then git -C "${dir}" fetch --unshallow origin "${branch}"; git -C "${dir}" checkout "${commit}"; fi; git config --global url."https://github.com/".insteadOf "git@github.com:"; git -C "${dir}" submodule update --init --recursive; cd "${dir}"; } && \
    # DeepEP
    git_clone_and_cd https://github.com/deepseek-ai/DeepEP /app/deepep main 9af0e0d0e74f3577af1979c9b9e1ac2cad0104ee && \
    NVSHMEM_DIR="${NVSHMEM_PREFIX:-/opt/nvshmem}" "${PYTHON}" -m pip install --no-build-isolation --no-cache-dir . && \
    BUILD_DIR="build/lib.linux-$(uname -m)-cpython-${PY_TAG}" && \
    SO_NAME="deep_ep_cpp.cpython-${PY_TAG}-$(uname -m)-linux-gnu.so" && \
    [[ -f "${BUILD_DIR}/${SO_NAME}" ]] && ln -sf "${BUILD_DIR}/${SO_NAME}" . && \
    # DeepGEMM
    git_clone_and_cd https://github.com/deepseek-ai/DeepGEMM /app/deepgemm main ea9c5d92 && \
    "${UV}" pip uninstall --python "${PYTHON}" deep_gemm && \
    ./install.sh && \
    # FlashInfer
    upip flashinfer-python && \
    # vLLM
    git_clone_and_cd https://github.com/vllm-project/vllm.git /app/vllm releases/v0.11.0 && \
    VLLM_USE_PRECOMPILED=0 MAX_JOBS=$(( "$(nproc)" * 1 / 2 )) upip -e .

ENTRYPOINT ["/app/code/venv/bin/vllm", "serve"]
