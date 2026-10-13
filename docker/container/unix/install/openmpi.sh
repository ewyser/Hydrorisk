#!/bin/bash
set -euo pipefail

OPENMPI_VERSION="$1"
CUDA_ROOT="$2"
OPENMPI_PREFIX="$3"

echo "=============================="
echo "🔍 Step 1: Checking CUDA installation"
echo "=============================="
if [ ! -d "$CUDA_ROOT" ]; then
    echo "❌ CUDA not found at: $CUDA_ROOT"
    exit 1
fi
echo "✅ CUDA detected at: $CUDA_ROOT"

echo "=============================="
echo "🧩 Step 2: Installing dependencies"
echo "=============================="
if [[ $EUID -ne 0 ]]; then
    echo "⚠️  Warning: It's recommended to run this script as root to install dependencies and install OpenMPI to system directories."
fi

# Install dependencies with sudo if not root
if [[ $EUID -ne 0 ]]; then
    sudo apt-get update && sudo apt-get install -y --no-install-recommends \
        build-essential gcc g++ gfortran make wget curl libnuma-dev libevent-dev \
        && sudo rm -rf /var/lib/apt/lists/*
else
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc g++ gfortran make wget curl libnuma-dev libevent-dev \
        && rm -rf /var/lib/apt/lists/*
fi

echo "=============================="
echo "🧼 Step 3: Cleaning previous installations"
echo "=============================="
rm -rf "/tmp/openmpi-${OPENMPI_VERSION}" "/tmp/openmpi-${OPENMPI_VERSION}.tar.gz" "${OPENMPI_PREFIX}"

echo "=============================="
echo "⬇️ Step 4: Downloading OpenMPI ${OPENMPI_VERSION}"
echo "=============================="
cd /tmp
wget -q "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-${OPENMPI_VERSION}.tar.gz"
tar -xzf "openmpi-${OPENMPI_VERSION}.tar.gz"
cd "openmpi-${OPENMPI_VERSION}"

echo "=============================="
echo "⚙️ Step 5: Configuring OpenMPI with CUDA support"
echo "=============================="
./configure --with-cuda="${CUDA_ROOT}" \
            --with-libevent=internal \
            --prefix="${OPENMPI_PREFIX}"

echo "=============================="
echo "🛠️ Step 6: Building and Installing"
echo "=============================="
make -j"$(nproc)"

# Use sudo for make install if not root and prefix requires permissions
if [[ $EUID -ne 0 && ! -w "${OPENMPI_PREFIX}" ]]; then
    echo "⚠️  Installing to ${OPENMPI_PREFIX} requires elevated privileges. Using sudo for make install."
    sudo make install
else
    make install
fi

echo "=============================="
echo "🧹 Step 7: Cleaning build files"
echo "=============================="
cd /
rm -rf "/tmp/openmpi-${OPENMPI_VERSION}" "/tmp/openmpi-${OPENMPI_VERSION}.tar.gz"

echo "=============================="
echo "🔍 Step 8: Verifying installation"
echo "=============================="
"${OPENMPI_PREFIX}/bin/mpiexec" --version

echo "✅ OpenMPI ${OPENMPI_VERSION} with CUDA support installed at ${OPENMPI_PREFIX}"

# Append to ~/.bashrc if not already present
if ! grep -q "${OPENMPI_PREFIX}/bin" ~/.bashrc 2>/dev/null; then
  echo "" >> ~/.bashrc
  echo "# Added by OpenMPI install script" >> ~/.bashrc
  echo "export PATH=${OPENMPI_PREFIX}/bin:\$PATH" >> ~/.bashrc
  echo "export LD_LIBRARY_PATH=${OPENMPI_PREFIX}/lib:\$LD_LIBRARY_PATH" >> ~/.bashrc
  echo "✅ Added PATH and LD_LIBRARY_PATH to ~/.bashrc"
else
  echo "⚠️ PATH and LD_LIBRARY_PATH already set in ~/.bashrc, skipping"
fi

echo "👉 To apply changes, run: source ~/.bashrc"



