# ------------------------------------------------------
# STAGE 1: BUILD TOOLCHAIN, JULIA, AND LIBRARIES
#
# Reuses compute-engine's heavy CUDA/OpenMPI/parallel-HDF5 toolchain: cORIUm
# and OsmotiC still need it even inside the combined image. Datastore.jl and
# Hydrorisk.jl don't need it, but sharing one toolchain/depot is simpler than
# a second base for a first end-to-end test image - see
# docker/compute-engine/Dockerfile for the line-by-line rationale of this
# stage, copied here unchanged.
# ------------------------------------------------------
FROM nvidia/cuda:12.5.0-devel-ubuntu22.04 AS toolchain

ARG CUDA_VERSION=12.5
ARG OPENMPI_VERSION=4.1.6
ARG HDF5_VERSION=1.14.3
ARG JULIA_VERSION=1.10.5

ENV CUDA_ROOT=/usr/local/cuda-${CUDA_VERSION}
ENV OPENMPI_PREFIX=/opt/openmpi-cuda
ENV HDF5_PREFIX=/opt/hdf5-parallel
ENV JULIA_PREFIX=/opt/julia

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl gnupg2 git ca-certificates software-properties-common \
    build-essential gcc g++ gfortran make libnuma-dev libevent-dev zip \
    && rm -rf /var/lib/apt/lists/*

COPY unix/install/openmpi.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/openmpi.sh && \
    /usr/local/bin/openmpi.sh "$OPENMPI_VERSION" "$CUDA_ROOT" "$OPENMPI_PREFIX"

COPY unix/install/hdf5.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/hdf5.sh && \
    /usr/local/bin/hdf5.sh "$HDF5_VERSION" "$HDF5_PREFIX" "$OPENMPI_PREFIX"

COPY unix/install/julia.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/julia.sh && \
    /usr/local/bin/julia.sh "$JULIA_VERSION" "$JULIA_PREFIX"

ENV PATH=${JULIA_PREFIX}/bin:${HDF5_PREFIX}/bin:${OPENMPI_PREFIX}/bin:${CUDA_ROOT}/bin:$PATH
ENV LD_LIBRARY_PATH=${HDF5_PREFIX}/lib:${OPENMPI_PREFIX}/lib:${CUDA_ROOT}/lib64:$LD_LIBRARY_PATH
ENV OMPI_MCA_opal_warn_on_missing_libcuda=0

# All four packages, staged sibling-layout-preserved by prep-context.sh (see
# that file for exactly why Hydrorisk.jl needs the extra wrap/ nesting).
ENV PKGROOT=/home/packages
ENV CORIUM=${PKGROOT}/cORIUm.jl
ENV OSMOTIC=${PKGROOT}/OsmotiC.jl
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV HYDRORISK=${PKGROOT}/wrap/Hydrorisk.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no
WORKDIR ${PKGROOT}

# ------------------------------------------------------
# STAGE 2: DEPENDENCY RESOLUTION
#
# All four projects share the same depot (/root/.julia). Order matters only
# in that OsmotiC/Hydrorisk's path-deps (cORIUm, Datastore) must already be
# staged on disk (they are - prep-context.sh stages everything up front);
# instantiate order itself doesn't matter to Pkg, but resolving the leaves
# first makes a failing leaf fail fast instead of failing loud inside a
# dependent's resolve.
# ------------------------------------------------------
FROM toolchain AS deps
COPY .context/packages/ ${PKGROOT}/
RUN julia --project=${DATASTORE} -e 'using Pkg; Pkg.instantiate()'
RUN julia --project=${CORIUM}    -e 'using Pkg; Pkg.instantiate(); Pkg.add("CUDA")'
RUN julia --project=${OSMOTIC}   -e 'using Pkg; Pkg.instantiate(); Pkg.add("CUDA")'
RUN julia --project=${HYDRORISK} -e 'using Pkg; Pkg.instantiate()'

# ------------------------------------------------------
# STAGE 3: BUILDER
#
# Deliberately no Pkg.precompile() here - see compute-engine/Dockerfile's
# STAGE 1c comment for why (root-owned /root/.julia paths baked into .ji
# caches would EACCES under the runtime image's non-root user).
# ------------------------------------------------------
FROM deps AS builder
CMD ["bash"]

# ------------------------------------------------------
# STAGE 4: RUNTIME IMAGE
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
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV HYDRORISK=${PKGROOT}/wrap/Hydrorisk.jl
ENV HOME=/home/mpiuser
ENV OMPI_MCA_opal_warn_on_missing_libcuda=0

ENV CORIUM_MPIEXEC_PATH=${OPENMPI_PREFIX}/bin/mpiexec
ENV CORIUM_HDF5_LIB=${HDF5_PREFIX}/lib/libhdf5.so
ENV CORIUM_HDF5_HL_LIB=${HDF5_PREFIX}/lib/libhdf5_hl.so
ARG CUDA_VERSION=12.5
ENV CORIUM_CUDA_VERSION=${CUDA_VERSION}

# libnuma1/libhwloc15/libevent-2.1-7/openssh-client: compute-engine's MPI
# runtime deps. zip: Hydrorisk.__init__ -> build_plugin() needs it.
RUN apt-get update && apt-get install -y \
    libnuma1 libhwloc15 libevent-2.1-7 openssh-client zip \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m mpiuser

COPY --from=builder /opt/openmpi-cuda /opt/openmpi-cuda
COPY --from=builder /opt/hdf5-parallel /opt/hdf5-parallel
COPY --from=builder /opt/julia /opt/julia
COPY --from=builder /home/packages /home/mpiuser/packages
COPY --from=builder ${CUDA_ROOT} ${CUDA_ROOT}
COPY --from=builder /root/.julia /home/mpiuser/.julia

COPY unix/entrypoint.sh /home/mpiuser/entrypoint.sh
RUN chmod +x /home/mpiuser/entrypoint.sh

RUN chown -R mpiuser:mpiuser /opt ${CUDA_ROOT} /home/mpiuser/packages /home/mpiuser/.julia /home/mpiuser/entrypoint.sh

# Stays root at the end - see compute-engine/Dockerfile's runtime-stage
# comment: entrypoint.sh needs root to fix a bind-mounted $VOLUME_MOUNT's
# permissions before dropping to mpiuser (via runuser) for the workload.
WORKDIR ${CORIUM}

# Precompile all four projects as mpiuser, in the same dependency-respecting
# order as the deps stage, so every .ji cache's baked-in absolute source
# paths point at /home/mpiuser/.julia/... from the start.
RUN runuser -u mpiuser -- julia --project=${DATASTORE} -e 'using Pkg; Pkg.precompile()'
RUN runuser -u mpiuser -- julia --project=${CORIUM}    -e 'using Pkg; Pkg.precompile()'
RUN runuser -u mpiuser -- julia --project=${OSMOTIC}   -e 'using Pkg; Pkg.precompile()'
RUN runuser -u mpiuser -- julia --project=${HYDRORISK} -e 'using Pkg; Pkg.precompile()'

EXPOSE 8000
ENTRYPOINT ["/home/mpiuser/entrypoint.sh"]
CMD ["/bin/bash"]
