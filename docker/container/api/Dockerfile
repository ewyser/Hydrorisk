# ------------------------------------------------------
# STAGE 1: TOOLCHAIN - Julia only. Hydrorisk.jl is an Oxygen/HTTP API server
# with a Datastore.jl path-dep; no CUDA/OpenMPI/parallel-HDF5 needed.
# ------------------------------------------------------
FROM ubuntu:22.04 AS toolchain

# Latest 1.10 LTS patch, same as the daemon image. At least 1.10.10:
# Datastore.jl's [compat] requires julia = "1.10.10".
ARG JULIA_VERSION=1.10.12
ENV DEBIAN_FRONTEND=noninteractive
ENV JULIA_PREFIX=/opt/julia

# zip is required at runtime: Hydrorisk.__init__ -> build_plugin() zips
# gis/hydrorisk_plugin/ into gis/hydrorisk_plugin.zip on every module load.
# libsqlite3-0 is required by GDAL_jll's bundled libproj.so, which links
# against sqlite3 for its projection database - without it, precompiling
# GDAL/ArchGDAL fails with "libsqlite3.so.0: cannot open shared object file".
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates zip libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

COPY unix/install/julia.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/julia.sh && \
    /usr/local/bin/julia.sh "$JULIA_VERSION" "$JULIA_PREFIX"

ENV PATH=${JULIA_PREFIX}/bin:$PATH
ENV PKGROOT=/home/packages
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV HYDRORISK=${PKGROOT}/wrap/Hydrorisk.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no
WORKDIR ${PKGROOT}

# ------------------------------------------------------
# STAGE 2: DEPENDENCY RESOLUTION - cached on the staged packages' content
# alone. Only Hydrorisk.jl is instantiated: it's the only project the api
# runs. Datastore.jl is its path-dep (../../Datastore.jl - the sibling layout
# staged by prep-context.sh and copied here), and Hydrorisk.jl's Manifest
# already pins all of Datastore's dependencies, so Datastore needs neither
# its own instantiate nor its own Manifest.toml (its repo gitignores it).
# ------------------------------------------------------
FROM toolchain AS deps
COPY api/.context/packages/ ${PKGROOT}/
RUN julia --project=${HYDRORISK} -e 'using Pkg; Pkg.instantiate()'

# ------------------------------------------------------
# STAGE 3: BUILDER
# ------------------------------------------------------
FROM deps AS builder
CMD ["bash"]

# ------------------------------------------------------
# STAGE 4: RUNTIME IMAGE
# ------------------------------------------------------
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
# libsqlite3-0 needed here too - GDAL_jll's libproj.so is dlopen'd again at
# runtime (Hydrorisk.jl's own GDAL/ArchGDAL usage), not just during the
# precompile step above.
RUN apt-get update && apt-get install -y --no-install-recommends \
    zip ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

ENV JULIA_DIR=/opt/julia
ENV PATH=${JULIA_DIR}/bin:${PATH}
ENV PKGROOT=/home/apiuser/packages
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV HYDRORISK=${PKGROOT}/wrap/Hydrorisk.jl
ENV HOME=/home/apiuser
# Build the precompile cache for several x86-64 generations (the same targets
# as the official Julia binary's sysimage, and as the daemon image), not just
# the build machine's CPU. Otherwise a deployment host with a different CPU
# rejects the whole cache and recompiles everything at container start (slow,
# and noisy: e.g. Revise/LoweredCodeUtils "skipping callee" warnings).
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

RUN useradd -m apiuser

COPY --from=builder /opt/julia /opt/julia
COPY --from=builder /home/packages /home/apiuser/packages
COPY --from=builder /root/.julia /home/apiuser/.julia

COPY api/entrypoint.sh /home/apiuser/entrypoint.sh
RUN chmod +x /home/apiuser/entrypoint.sh && \
    chown -R apiuser:apiuser /opt /home/apiuser

# Hydrorisk.__init__ creates jobs/ and files/ under its own package root at
# every module load, and writes the QGIS plugin zip to $VOLUME_MOUNT (the
# host bind mount, see docker-compose.yml) - or to gis/ in the package root
# when nothing writable is mounted there. So the package root - not just the
# depot - must be writable by apiuser (chown above already covers it via
# /home/apiuser).
#
# The container starts as root on purpose: entrypoint.sh makes the
# bind-mounted $VOLUME_MOUNT writable, then drops to apiuser (via `runuser`)
# for the server. Do not add `USER apiuser` back here - build-time steps run
# as apiuser through runuser instead.
WORKDIR ${HYDRORISK}

# Precompiles Datastore.jl too, as Hydrorisk.jl's dependency.
RUN runuser -u apiuser -- julia --project=${HYDRORISK} -e 'using Pkg; Pkg.precompile()'

EXPOSE 8000
ENTRYPOINT ["/home/apiuser/entrypoint.sh"]
CMD ["julia", "--project=/home/apiuser/packages/wrap/Hydrorisk.jl", "-e", "using Hydrorisk; Hydrorisk.start_server(port=8000, host=\"0.0.0.0\", cli=false)"]
