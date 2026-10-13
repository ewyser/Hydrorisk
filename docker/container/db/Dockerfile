# Postgres + PostGIS server, with Julia + Datastore.jl bundled in the same
# image so the container can both serve the database and run Datastore.jl
# directly against it (schema init, data ingestion, ad-hoc queries).
#
# postgis/postgis already ships Postgres, PostGIS, postgis_raster, and the
# shp2pgsql/raster2pgsql/psql client tools Datastore.jl's db_create()/
# db_add_data() need - Datastore only issues CREATE EXTENSION, it can't
# install the extension binaries itself.

# Latest 1.10 LTS patch, same as the daemon image. At least 1.10.10:
# Datastore.jl's [compat] requires julia = "1.10.10".
ARG JULIA_VERSION=1.10.12

# ------------------------------------------------------
# Julia is downloaded in its own Ubuntu stage and only copied into the db
# image below - so the db image needs no apt-get at all. Its base,
# postgis/postgis:16-3.4, is Debian 11 (bullseye), whose security repo is
# being retired: apt-get there fails with 404s for packages its own index
# still lists (e.g. wget). The official Julia binaries are self-contained
# and run on bullseye's glibc as-is.
# ------------------------------------------------------
FROM ubuntu:22.04 AS julia
ARG JULIA_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY unix/install/julia.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/julia.sh && \
    /usr/local/bin/julia.sh "$JULIA_VERSION" /opt/julia

# ------------------------------------------------------
FROM postgis/postgis:16-3.4

ENV JULIA_PREFIX=/opt/julia
ENV PKGROOT=/home/packages
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no
# Precompile cache for several x86-64 generations (same targets as the daemon
# and api images), so a deployment host with a different CPU than the build
# machine doesn't reject it and recompile Datastore.jl at every container start.
ENV JULIA_CPU_TARGET="generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

COPY --from=julia /opt/julia ${JULIA_PREFIX}
ENV PATH=${JULIA_PREFIX}/bin:$PATH

# Datastore.jl, staged by prep-context.sh (no sibling packages needed - it
# has zero local path-deps).
COPY db/.context/packages/ ${PKGROOT}/
RUN julia --project=${DATASTORE} -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# No POSTGRES_DB/POSTGRES_USER/HYDRORISK_* defaults here - see
# entrypoint.sh, which derives Datastore.jl's env vars from whatever
# Postgres config was actually passed to `docker run`, rather than
# duplicating fixed values here that would go stale the moment someone
# overrides POSTGRES_DB/POSTGRES_USER.
COPY db/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# First-start seeding from a mounted dump (/seed/hydrorisk.sql) - see
# seed-db.sh. Numbered after the base image's own 10_postgis.sh.
COPY db/seed-db.sh /docker-entrypoint-initdb.d/20_seed_hydrorisk.sh
RUN chmod +x /docker-entrypoint-initdb.d/20_seed_hydrorisk.sh

EXPOSE 5432
ENTRYPOINT ["/entrypoint.sh"]
# Setting ENTRYPOINT resets any CMD inherited from the base image to empty -
# restore the base postgis/postgis image's own default explicitly.
CMD ["postgres"]
