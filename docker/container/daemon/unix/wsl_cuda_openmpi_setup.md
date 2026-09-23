# 🐛 Installing Windows Subsystem for Linux (WSL)

I (madmax) installed **Windows Subsystem for Linux (WSL)** on Touranum.\
Here are the steps and some useful notes about using it.

---

## 📾 Installation Information

During the installation, here's what was requested:

```powershell
PS C:\Users\Terranum> wsl --list --verbose
  NAME              STATE           VERSION
* docker-desktop    Stopped         2
PS C:\Users\Terranum> wsl --install -d Ubuntu
Téléchargement : Ubuntu
Installation : Ubuntu
La distribution a été installée. Il peut être lancé via 'wsl.exe -d Ubuntu'
Lancement : Ubuntu...
Provisioning the new WSL instance Ubuntu
This might take a while...
Create a default Unix user account: terranum
New password: dolly
Retype new password: dolly
passwd: password updated successfully
To run a command as administrator (user "root"), use "sudo <command>".
See "man sudo_root" for details.

terranum@TerranumTour:/mnt/c/Users/Terranum$
```

---

## 💻 Launching the Unix Shell

Once installed, I access the Unix shell via **PowerShell**:

```powershell
Windows PowerShell  
Copyright (C) Microsoft Corporation. All rights reserved.

Install the latest version of PowerShell for new features and improvements!  
https://aka.ms/PSWindows

PS C:\Users\Terranum> wsl -d Ubuntu
terranum@TerranumTour:/mnt/c/Users/Terranum$
```

---

## 💾 Accessing Windows Drives

- Windows drives are mounted under: `/mnt/host`
- From this point, all of **Touranum**'s content is accessible.
- Files are **synchronized**: anything done in WSL is reflected in Windows.

---

## 🧠 MPI and HDF5

Installing UNIX was necessary because configuring HDF5 with MPI parallelism under Windows would have been a nightmare. So for MPI implementation in Julia, it worked smoothly and only took me 10 minutes to configure.

---

---

# ⚙️ Installing MPI, HDF5 and Configuring Julia under UNIX

This document summarizes the steps to:

1. Install **MPI** and **HDF5**
2. Configure **Julia** to use these libraries

---

## 🧰 1. Install MPI and HDF5

### 🔹 System update

```bash
sudo apt update && sudo apt upgrade -y
```

### 🔹 Install MPI (OpenMPI)

```bash
sudo apt install -y libopenmpi-dev openmpi-bin
```

### 🔹 Install HDF5 with MPI support

```bash
sudo apt install -y libhdf5-dev libhdf5-mpi-dev
```

> ✅ Check that the `mpicc` compiler is available:

```bash
mpicc --version
```

---

## 💪 2. Install Julia

### 🔹 Download Julia (latest stable version)

```bash
wget https://julialang-s3.julialang.org/bin/linux/x64/1.10/julia-1.10.3-linux-x86_64.tar.gz
```

### 🔹 Extract and move Julia

```bash
tar -xvzf julia-1.10.3-linux-x86_64.tar.gz
sudo mv julia-1.10.3 /opt/
sudo ln -s /opt/julia-1.10.3/bin/julia /usr/local/bin/julia
```

### 🔹 Verify

```bash
julia --version
```

---

## 📦 3. Configure Julia with MPI and HDF5

### 🔹 Launch Julia

```bash
julia
```

### 🔹 Install required packages

```julia
using Pkg

Pkg.add("MPI")
Pkg.add("HDF5")
```

### 🔹 Configure MPI (optional but recommended)

```julia
using MPI
MPI.versioninfo()
```

> If MPI doesn't find the right binaries, set:

```julia
ENV["JULIA_MPI_BINARY"] = "system"
Pkg.build("MPI")
```

---

## ✅ 4. Tests

### 🔹 MPI Test

```julia
using MPI
MPI.Init()
rank = MPI.Comm_rank(MPI.COMM_WORLD)
println("Hello from rank \$rank")
MPI.Finalize()
```

### 🔹 HDF5 Test

```julia
using HDF5
h5write("data.h5", "mydataset", [1, 2, 3])
data = h5read("data.h5", "mydataset")
println(data)
```

---

# 🚀 Installing CUDA and OpenMPI with GPU support in WSL

This guide enables **direct GPU↔GPU communication** in Julia using `CUDA.jl` and `MPI.jl`, by installing CUDA in WSL and compiling OpenMPI with CUDA support.

---

## ⚙️ 1. Install CUDA Toolkit for WSL

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/3bf863cc.pub -O- | sudo apt-key add -
echo "deb https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64 /" | sudo tee /etc/apt/sources.list.d/cuda-wsl.list

sudo apt update
sudo apt install -y cuda-toolkit-12-5

# Add to ~/.bashrc
echo 'export PATH=/usr/local/cuda-12.5/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.5/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc
```

---

## ✅ 2. Build OpenMPI with CUDA support

```bash
cd ~
wget https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.6.tar.gz
tar -xzf openmpi-4.1.6.tar.gz
cd openmpi-4.1.6

./configure --with-cuda=/usr/local/cuda-12.5 --prefix=$HOME/.local/openmpi-cuda
make -j$(nproc)
make install

# Environment variables

echo 'export PATH=$HOME/.local/openmpi-cuda/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=$HOME/.local/openmpi-cuda/lib:$LD_LIBRARY_PATH' >> ~/.bashrc
echo 'export OMPI_MCA_opal_warn_on_missing_libcuda=0' >> ~/.bashrc
source ~/.bashrc
```

---

## 🔹 3. Configure Julia to use MPI with CUDA

> ⚠️ **Note (kept for history, not accurate against the current
> `MPIPreferences.jl`):** `use_system_binary` no longer takes a positional
> path argument — it's keyword-only (`mpiexec=...`) — and
> `MPIPreferences.set_cuda_aware` doesn't exist in the current API at all;
> CUDA-awareness is auto-detected from the linked `libmpi` rather than
> declared as a preference. See `src/boot/needs/setup_mpi.jl` in the repo
> for the current, working equivalent of this step.

Create a `setup_julia_mpi.jl` file:

```julia
using MPIPreferences

openmpi_path = joinpath(ENV["HOME"], ".local", "openmpi-cuda", "bin", "mpiexec")

MPIPreferences.use_system_binary(openmpi_path)
MPIPreferences.set_cuda_aware(true)

println("✅ MPI.jl configured to use:")
println("   \$openmpi_path")
println("   with CUDA-aware = true")
```

Then run:

```bash
julia setup_julia_mpi.jl
```

---

## 🌌 4. Test GPU-GPU communication using MPI

```julia
using MPI, CUDA

MPI.Init()
rank = MPI.Comm_rank(MPI.COMM_WORLD)

if rank == 0
    data = CUDA.fill(42, 5)
    MPI.Send!(data, 1, 0, MPI.COMM_WORLD)
elseif rank == 1
    data = CuArray{Int}(undef, 5)
    MPI.Recv!(data, 0, 0, MPI.COMM_WORLD)
    println("Received on GPU: ", Array(data))
end

MPI.Finalize()
```

---

🎉 **You can now use CUDA + MPI in Julia on WSL with direct GPU access!**

