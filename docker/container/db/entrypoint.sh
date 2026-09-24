#!/bin/bash
set -euo pipefail

# Chains in front of the base postgis/postgis image's own entrypoint -
# Postgres's normal initdb/startup sequence is untouched below.
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"

# Datastore.get_db()/load_env! reads six ENV vars (PSWD_DB,
# HYDRORISK_DB_HOST/PORT/USER/NAME, HYDRORISK_API) and drops into an
# interactive readline() prompt if *none* are set - fatal in a container.
# Mirror host/port/user from Postgres's *actual* runtime config (whatever
# the caller passed to `docker run`), never a value hardcoded at build time,
# so overriding POSTGRES_USER/PGPORT at `docker run` automatically keeps
# Datastore pointed at the right place. Only host is a true constant: Julia
# and Postgres share this one container.
#
# HYDRORISK_DB_NAME is deliberately NOT mirrored from POSTGRES_DB: Datastore's
# db_create() only creates its schemas/tables/PostGIS setup the first time it
# sees its target database missing (it skips all of that once the database
# already exists - see Datastore.jl/src/db/initialize/db_create.jl). If
# POSTGRES_DB were set to Datastore's target name, the base image's own
# first-run init would create that database before Datastore ever connects,
# so db_create() would find it already there and silently skip its own
# schema bootstrap. Leaving POSTGRES_DB unset (or set to anything other than
# HYDRORISK_DB_NAME) keeps Datastore's target database entirely under its
# own creation path. HYDRORISK_DB_NAME can still be overridden explicitly at
# `docker run` if a different target name is wanted; it defaults to
# Datastore.jl's own "hydrorisk" default otherwise.
#
# Written to a sourceable file, not just exported here, because a later
# `docker exec` only sees the container's image/`-e` ENV config - not a
# separate process's exports - so exporting alone would leave Datastore.jl
# invoked via `docker exec` back at square one (interactive prompt).
{
    echo "export HYDRORISK_DB_HOST=localhost"
    echo "export HYDRORISK_DB_PORT=${PGPORT:-5432}"
    echo "export HYDRORISK_DB_USER=${POSTGRES_USER:-postgres}"
    echo "export HYDRORISK_DB_NAME=${HYDRORISK_DB_NAME:-hydrorisk}"
    echo "export HYDRORISK_API=true"
    echo "export PSWD_DB=${POSTGRES_PASSWORD}"
} > /home/packages/hydrorisk.env
chmod 644 /home/packages/hydrorisk.env
source /home/packages/hydrorisk.env

# Run Postgres in the background (instead of exec'ing straight into it) so
# this script can wait for it to accept connections and run Datastore's
# schema init on every start - cheap once the target database already
# exists (db_create() skips its own bootstrap in that case, see the
# HYDRORISK_DB_NAME comment above). The trap forwards SIGTERM/SIGINT to
# Postgres so `docker stop`/`docker compose down` still shut it down
# promptly instead of waiting out the default force-kill timeout.
docker-entrypoint.sh "$@" &
PG_PID=$!
trap 'kill -TERM "$PG_PID" 2>/dev/null; wait "$PG_PID"' TERM INT

until pg_isready -U "${POSTGRES_USER:-postgres}" -h localhost -p "${PGPORT:-5432}" >/dev/null 2>&1; do
    sleep 1
done

julia --project="${DATASTORE}" -e 'using Datastore; Datastore.get_db()' \
    || echo "⚠️  Datastore schema init failed - continuing, Postgres is still up" >&2

wait "$PG_PID"
