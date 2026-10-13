#!/bin/bash
set -euo pipefail

HDF5_VERSION="$1"         # e.g., 1.14.3
HDF5_PREFIX="$2"          # e.g., /opt/hdf5-parallel
OPENMPI_PREFIX="$3"       # e.g., /opt/openmpi-cuda

echo "=============================="
echo "🔧 Step 1: Checking OpenMPI path"
echo "=============================="
if [ ! -d "$OPENMPI_PREFIX" ]; then
    echo "❌ CUDA-aware OpenMPI not found at $OPENMPI_PREFIX"
    exit 1
fi
echo "✅ OpenMPI found at: $OPENMPI_PREFIX"

echo "=============================="
echo "⬇️ Step 2: Downloading HDF5 ${HDF5_VERSION}"
echo "=============================="
cd /tmp
wget -q "https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-${HDF5_VERSION:0:4}/hdf5-${HDF5_VERSION}/src/hdf5-${HDF5_VERSION}.tar.gz"
tar -xzf "hdf5-${HDF5_VERSION}.tar.gz"
cd "hdf5-${HDF5_VERSION}"

echo "=============================="
echo "⚙️ Step 3: Configuring with MPI support"
echo "=============================="
export CC=${OPENMPI_PREFIX}/bin/mpicc
export CXX=${OPENMPI_PREFIX}/bin/mpicxx
export FC=${OPENMPI_PREFIX}/bin/mpifort

./configure --enable-parallel \
            --enable-shared \
            --prefix="${HDF5_PREFIX}"

echo "=============================="
echo "🛠️ Step 4: Building and Installing"
echo "=============================="
make -j"$(nproc)"
make install

# Use sudo if installing to protected path
#if [[ ! -w "$HDF5_PREFIX" ]]; then
#    echo "⚠️ Installing to ${HDF5_PREFIX} requires sudo..."
#    sudo make install
#else
#    make install
#fi

echo "=============================="
echo "🧹 Step 5: Cleaning build files"
echo "=============================="
cd /
rm -rf "/tmp/hdf5-${HDF5_VERSION}" "/tmp/hdf5-${HDF5_VERSION}.tar.gz"

echo "=============================="
echo "🔍 Step 6: Verifying installation"
echo "=============================="
"${HDF5_PREFIX}/bin/h5pcc" -showconfig || echo "⚠️ Warning: h5pcc not found"

echo "✅ HDF5 ${HDF5_VERSION} parallel installed at ${HDF5_PREFIX}"

echo "=============================="
echo "🔧 Step 7: Updating environment"
echo "=============================="
if ! grep -q "${HDF5_PREFIX}/bin" ~/.bashrc 2>/dev/null; then
  echo "" >> ~/.bashrc
  echo "# Added by HDF5 install script" >> ~/.bashrc
  echo "export PATH=${HDF5_PREFIX}/bin:\$PATH" >> ~/.bashrc
  echo "export LD_LIBRARY_PATH=${HDF5_PREFIX}/lib:\$LD_LIBRARY_PATH" >> ~/.bashrc
  echo "✅ Added HDF5 paths to ~/.bashrc"
else
  echo "⚠️ HDF5 paths already present in ~/.bashrc, skipping..."
fi

echo "👉 To apply the changes, run: source ~/.bashrc"

