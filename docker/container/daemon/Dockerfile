# ------------------------------------------------------
# STAGE 1: BUILD TOOLCHAIN, JULIA, AND LIBRARIES
# ------------------------------------------------------
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS toolchain

# Arguments
ARG CUDA_VERSION=12.5
ARG OPENMPI_VERSION=4.1.6
ARG HDF5_VERSION=1.14.3
ARG JULIA_VERSION=1.10.5

# Environment variables (for runtime)
ENV CUDA_ROOT=/usr/local/cuda-${CUDA_VERSION}
ENV OPENMPI_PREFIX=/opt/openmpi-cuda
ENV HDF5_PREFIX=/opt/hdf5-parallel
ENV JULIA_PREFIX=/opt/julia

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl gnupg2 git ca-certificates software-properties-common \
    build-essential gcc g++ gfortran make libnuma-dev libevent-dev \
    && rm -rf /var/lib/apt/lists/*

# Install OpenMPI with CUDA support
COPY unix/install/openmpi.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/openmpi.sh && \
    /usr/local/bin/openmpi.sh "$OPENMPI_VERSION" "$CUDA_ROOT" "$OPENMPI_PREFIX"

# Install parallel HDF5 with OpenMPI
COPY unix/install/hdf5.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/hdf5.sh && \
    /usr/local/bin/hdf5.sh "$HDF5_VERSION" "$HDF5_PREFIX" "$OPENMPI_PREFIX"

# Install Julia
COPY unix/install/julia.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/julia.sh && \
    /usr/local/bin/julia.sh "$JULIA_VERSION" "$JULIA_PREFIX"

# Configure environment variables PATH and LD_LIBRARY_PATH + add julia
ENV PATH=${JULIA_PREFIX}/bin:${HDF5_PREFIX}/bin:${OPENMPI_PREFIX}/bin:${CUDA_ROOT}/bin:$PATH
ENV LD_LIBRARY_PATH=${HDF5_PREFIX}/lib:${OPENMPI_PREFIX}/lib:${CUDA_ROOT}/lib64:$LD_LIBRARY_PATH
ENV OMPI_MCA_opal_warn_on_missing_libcuda=0

# The daemon bundles two packages side by side: cORIUm.jl (the solver)
# and OsmotiC.jl (which path-depends on ../cORIUm.jl and ../Datastore.jl - see
# OsmotiC.jl/Manifest.toml). They are staged into the build context by
# prep-context.sh, preserving that sibling layout so an offline
# Pkg.instantiate() resolves the relative path-deps. The staging dir is
# .context/ (hidden, transient - see prep-context.sh / docker-build.sh).
ENV PKGROOT=/home/packages
ENV CORIUM=${PKGROOT}/cORIUm.jl
ENV OSMOTIC=${PKGROOT}/OsmotiC.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no
WORKDIR ${PKGROOT}

# ------------------------------------------------------
# STAGE 1b: DEPENDENCY RESOLUTION - cached on the staged package files' content
# alone (the COPY below is content-hashed by Docker), so this expensive step
# (Pkg.instantiate()/add("CUDA") downloads GBs of artifacts) only re-runs when
# the staged packages actually change, not on every source edit. This replaces the old
# CACHEBUST arg / git-clone `source` stage.
#
# The committed Manifest.toml of each package is kept on purpose: it is a
# known-good resolve for Julia 1.10. `Pkg.add("CUDA")` then adds only CUDA on
# top of it, bounded by the [compat] section in cORIUm.jl/Project.toml
# (CUDA "~5.5", KernelAbstractions "0.9"). Without those bounds an
# unconstrained resolve inside the container pulled Julia-1.11-only releases of
# CUDA (CUDACore split -> `ptxas_path not defined`) and Atomix
# (`__precompile__(false) is not allowed`) that fail to precompile.
#
# Both projects share the default root depot (/root/.julia). OsmotiC also needs
# CUDA (its cORIUm CUDAExt) - add it there too; the second add resolves against
# the already-populated depot and is close to a no-op.
#
# NOTE: deliberately no separate Pkg.resolve() after Pkg.add("CUDA"). CUDA is
# listed in both [deps] (added by Pkg.add) and [weakdeps] (from cORIUm's own
# Project.toml, for the CUDAExt extension) - an explicit Pkg.resolve() strips
# CUDA back out of the Manifest entirely, leaving `using CUDA` failing at
# runtime. Pkg.add() already performs its own resolve - no extra call needed.
FROM toolchain AS deps
COPY daemon/.context/packages/ ${PKGROOT}/
RUN julia --project=${CORIUM}  -e 'using Pkg; Pkg.instantiate(); Pkg.add("CUDA")'
RUN julia --project=${OSMOTIC} -e 'using Pkg; Pkg.instantiate(); Pkg.add("CUDA")'

# ------------------------------------------------------
# STAGE 1c: BUILDER
#
# Deliberately NOT running Pkg.precompile() here: precompiling as root bakes
# /root/.julia/... absolute source paths into the .ji cache files for staleness
# checks. The runtime stage copies the depot to /home/mpiuser/.julia, but those
# baked-in /root/... paths don't move with it - and since /root is 0700
# root:root, mpiuser's stat() on them fails with EACCES (not a clean "missing,
# recompile") the first time a package loads - a hard `ERROR: LoadError`. So
# there is nothing safe to keep from a build-time precompile; the runtime stage
# precompiles fresh as mpiuser instead, into mpiuser's own depot with correct
# paths from the start.
#
# MPI/CUDA (LocalPreferences.toml) is intentionally NOT configured here: this
# build stage has no GPU access to verify against. It's regenerated every
# container start instead, by entrypoint.sh (see
# src/boot/needs/setup_mpi.jl).
FROM deps AS builder
CMD ["bash"]

# ------------------------------------------------------
# STAGE 2: RUNTIME IMAGE
# ------------------------------------------------------
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

ENV CUDA_ROOT=/usr/local/cuda-12.5
ENV OPENMPI_PREFIX=/opt/openmpi-cuda
ENV HDF5_PREFIX=/opt/hdf5-parallel
ENV JULIA_DIR=/opt/julia
ENV PATH=${CUDA_ROOT}/bin:${OPENMPI_PREFIX}/bin:${HDF5_PREFIX}/bin:${JULIA_DIR}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_ROOT}/lib64:${OPENMPI_PREFIX}/lib:${HDF5_PREFIX}/lib
ENV PKGROOT=/home/mpiuser/packages
ENV CORIUM=${PKGROOT}/cORIUm.jl
ENV OSMOTIC=${PKGROOT}/OsmotiC.jl
ENV HOME=/home/mpiuser
# Silences OpenMPI's "libcuda.so.1: cannot open shared object file" warning
# (repeated once per rank) when running without a GPU/driver present -
# harmless, but noisy.
ENV OMPI_MCA_opal_warn_on_missing_libcuda=0

# MPI/CUDA/HDF5 configuration, regenerated at container start by entrypoint.sh
# (see src/boot/needs/setup_mpi.jl) rather than baked in at build time.
# CORIUM_HDF5_LIB/CORIUM_HDF5_HL_LIB point HDF5.jl at this system parallel HDF5
# (built against the same system OpenMPI above) instead of HDF5_jll's bundled
# MPI-enabled artifact, which pulls in a *different* OpenMPI_jll binary that
# collides with the system one on LD_LIBRARY_PATH (dlopen "undefined symbol:
# ompi_instance_count").
ENV CORIUM_MPIEXEC_PATH=${OPENMPI_PREFIX}/bin/mpiexec
ENV CORIUM_HDF5_LIB=${HDF5_PREFIX}/lib/libhdf5.so
ENV CORIUM_HDF5_HL_LIB=${HDF5_PREFIX}/lib/libhdf5_hl.so
ARG CUDA_VERSION=12.5
ENV CORIUM_CUDA_VERSION=${CUDA_VERSION}

# Install runtime dependencies only. openssh-client provides `ssh`, which
# OpenMPI's default process launcher (plm_rsh_agent) needs even for
# same-node/single-container multi-rank runs. libsqlite3-0 is required by
# GDAL_jll's bundled libproj.so, which links against sqlite3 for its
# projection database - without it, precompiling GDAL/ArchGDAL (pulled in by
# OsmotiC's Datastore.jl path-dep) fails with "libsqlite3.so.0: cannot open
# shared object file".
RUN apt-get update && apt-get install -y \
    libnuma1 libhwloc15 libevent-2.1-7 openssh-client libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m mpiuser

# Copy built software from builder stage
COPY --from=builder /opt/openmpi-cuda /opt/openmpi-cuda
COPY --from=builder /opt/hdf5-parallel /opt/hdf5-parallel
COPY --from=builder /opt/julia /opt/julia
COPY --from=builder /home/packages /home/mpiuser/packages

# The CUDA toolkit itself (ptxas, nvcc, headers, static libs) - this stage is
# plain ubuntu:22.04, not the nvidia/cuda:...-devel image the builder stage
# uses. --gpus all / the NVIDIA container runtime only injects driver libraries
# at container start, not the toolkit - CUDA.jl still needs ptxas at runtime to
# JIT-compile GPU kernels.
COPY --from=builder ${CUDA_ROOT} ${CUDA_ROOT}

# The Julia package depot itself (installed packages + downloaded artifacts) -
# built by Pkg.instantiate() in the deps stage under root's default depot,
# /root/.julia. Without this, Project.toml/Manifest.toml describe what should be
# installed, but nothing here actually is.
COPY --from=builder /root/.julia /home/mpiuser/.julia

# Entrypoint: regenerates LocalPreferences.toml (MPI/CUDA config) on every
# container start - see entrypoint.sh and src/boot/needs/setup_mpi.jl
COPY daemon/entrypoint.sh /home/mpiuser/entrypoint.sh
RUN chmod +x /home/mpiuser/entrypoint.sh

# Fix ownership
RUN chown -R mpiuser:mpiuser /opt ${CUDA_ROOT} /home/mpiuser/packages /home/mpiuser/.julia /home/mpiuser/entrypoint.sh

# NOTE: the container deliberately starts as root so entrypoint.sh can make a
# bind-mounted $VOLUME_MOUNT writable before dropping to mpiuser (via `runuser`)
# for the actual workload. Do not add `USER mpiuser` back here - that
# reintroduces the `mkdir("/mnt/output/dump"): EACCES` failure on root-owned
# host mounts (Docker Desktop / virtiofs).
WORKDIR ${CORIUM}

# Precompile as mpiuser (ownership above is already fixed), not root, so the
# .ji cache's baked-in absolute source paths point at /home/mpiuser/.julia/... -
# where the depot actually lives at runtime - instead of /root/.julia/...,
# which is 0700 root:root and made mpiuser's cache-staleness stat() calls fail
# with EACCES. The first `using cORIUm` / `using OsmotiC` inside a delivered
# container is then fast instead of a ~10+ min cold precompile. No GPU is needed
# for this - CUDA.jl precompiles fine without one.
RUN runuser -u mpiuser -- julia --project=${CORIUM}  -e 'using Pkg; Pkg.precompile()'
RUN runuser -u mpiuser -- julia --project=${OSMOTIC} -e 'using Pkg; Pkg.precompile()'

ENTRYPOINT ["/home/mpiuser/entrypoint.sh"]
CMD ["/bin/bash"]
