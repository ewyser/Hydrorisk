# ------------------------------------------------------
# STAGE 1: TOOLCHAIN - Julia only. Hydrorisk.jl is an Oxygen/HTTP API server
# with a Datastore.jl path-dep; no CUDA/OpenMPI/parallel-HDF5 needed.
# ------------------------------------------------------
FROM ubuntu:22.04 AS toolchain

ARG JULIA_VERSION=1.10.5
ENV DEBIAN_FRONTEND=noninteractive
ENV JULIA_PREFIX=/opt/julia

# zip is required at runtime: Hydrorisk.__init__ -> build_plugin() zips
# gis/hydrorisk_plugin/ into gis/hydrorisk_plugin.zip on every module load.
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates zip \
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
# alone. Datastore.jl is instantiated first: Hydrorisk.jl's Manifest pins it
# by relative path (../../Datastore.jl, see prep-context.sh), so the sibling
# layout staged by prep-context.sh must already be in place before
# Hydrorisk's own instantiate runs.
# ------------------------------------------------------
FROM toolchain AS deps
COPY .context/packages/ ${PKGROOT}/
RUN julia --project=${DATASTORE} -e 'using Pkg; Pkg.instantiate()'
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
RUN apt-get update && apt-get install -y --no-install-recommends \
    zip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV JULIA_DIR=/opt/julia
ENV PATH=${JULIA_DIR}/bin:${PATH}
ENV PKGROOT=/home/apiuser/packages
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV HYDRORISK=${PKGROOT}/wrap/Hydrorisk.jl
ENV HOME=/home/apiuser

RUN useradd -m apiuser

COPY --from=builder /opt/julia /opt/julia
COPY --from=builder /home/packages /home/apiuser/packages
COPY --from=builder /root/.julia /home/apiuser/.julia

COPY unix/entrypoint.sh /home/apiuser/entrypoint.sh
RUN chmod +x /home/apiuser/entrypoint.sh && \
    chown -R apiuser:apiuser /opt /home/apiuser

# Hydrorisk.__init__ writes gis/hydrorisk_plugin.zip and creates jobs/ and
# files/ under its own package root at every module load, so that dir - not
# just the depot - must be writable by apiuser (chown above already covers
# it via /home/apiuser).
USER apiuser
WORKDIR ${HYDRORISK}

RUN julia --project=${DATASTORE} -e 'using Pkg; Pkg.precompile()'
RUN julia --project=${HYDRORISK} -e 'using Pkg; Pkg.precompile()'

EXPOSE 8000
ENTRYPOINT ["/home/apiuser/entrypoint.sh"]
CMD ["julia", "--project=/home/apiuser/packages/wrap/Hydrorisk.jl", "-e", "using Hydrorisk; Hydrorisk.start_server(port=8000, cli=false)"]
