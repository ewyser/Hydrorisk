# Postgres + PostGIS server, with Julia + Datastore.jl bundled in the same
# image so the container can both serve the database and run Datastore.jl
# directly against it (schema init, data ingestion, ad-hoc queries).
#
# postgis/postgis already ships Postgres, PostGIS, postgis_raster, and the
# shp2pgsql/raster2pgsql/psql client tools Datastore.jl's db_create()/
# db_add_data() need - Datastore only issues CREATE EXTENSION, it can't
# install the extension binaries itself.
FROM postgis/postgis:16-3.4

ARG JULIA_VERSION=1.10.5
ENV JULIA_PREFIX=/opt/julia
ENV PKGROOT=/home/packages
ENV DATASTORE=${PKGROOT}/Datastore.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no

# ca-certificates is already present in the base image; only wget is needed
# here. Installing ca-certificates again pulls in a security-repo upgrade
# that isn't always available for this base's Debian point release.
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    && rm -rf /var/lib/apt/lists/*

COPY unix/install/julia.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/julia.sh && \
    /usr/local/bin/julia.sh "$JULIA_VERSION" "$JULIA_PREFIX"
ENV PATH=${JULIA_PREFIX}/bin:$PATH

# Datastore.jl, staged by prep-context.sh (no sibling packages needed - it
# has zero local path-deps).
COPY db/.context/packages/ ${PKGROOT}/
RUN julia --project=${DATASTORE} -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

# No POSTGRES_DB/POSTGRES_USER/HYDRORISK_* defaults here - see
# unix/entrypoint.sh, which derives Datastore.jl's env vars from whatever
# Postgres config was actually passed to `docker run`, rather than
# duplicating fixed values here that would go stale the moment someone
# overrides POSTGRES_DB/POSTGRES_USER.
COPY db/unix/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5432
ENTRYPOINT ["/entrypoint.sh"]
# Setting ENTRYPOINT resets any CMD inherited from the base image to empty -
# restore the base postgis/postgis image's own default explicitly.
CMD ["postgres"]
