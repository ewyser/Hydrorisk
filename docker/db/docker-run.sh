#!/bin/bash
set -euo pipefail
# docker-run.sh
#
# Interactive counterpart to docker-build.sh: runs the hydrorisk-db image,
# waits for Postgres to actually be ready, then optionally initializes the
# Datastore.jl schema and/or imports data from a local Postgres (via the
# existing import-local-data.sh).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_NAME="hydrorisk-db"
DEFAULT_VOLUME_DIR=$( cd -- "$SH_DIR/../.." &> /dev/null && pwd )/volume/db-data

# If the image isn't already loaded (e.g. this script was copied out of
# shipping/ onto another machine, or docker-build.sh's image was pruned),
# load it from the tarball docker-build.sh produces - checked both as a
# sibling (running from inside shipping/) and under shipping/image/
# (running the docker/db/ source copy directly).
if ! docker image inspect "${IMAGE_NAME}:latest" >/dev/null 2>&1; then
    CANDIDATE_TARS=(
        "$SH_DIR/image/${IMAGE_NAME}.tar"
        "$SH_DIR/shipping/image/${IMAGE_NAME}.tar"
    )
    IMAGE_TAR=""
    for candidate in "${CANDIDATE_TARS[@]}"; do
        if [ -f "$candidate" ]; then
            IMAGE_TAR="$candidate"
            break
        fi
    done
    if [ -z "$IMAGE_TAR" ]; then
        read -p "Image not found locally. Path to the image tarball: " IMAGE_TAR
    fi
    if [ ! -f "$IMAGE_TAR" ]; then
        echo "❌ No tarball found at: $IMAGE_TAR" >&2
        exit 1
    fi
    echo "Loading image from ${IMAGE_TAR}..."
    docker load -i "$IMAGE_TAR"
fi

read -p "Container name [hydrorisk-db]: " CONTAINER
CONTAINER="${CONTAINER:-hydrorisk-db}"

# Default is 5433, not Postgres's conventional 5432 - a locally-running
# Postgres (e.g. Postgres.app) already owns 5432 on most dev machines. If
# that local Postgres happens to be stopped when this runs, Docker would
# silently bind 5432 with no error, and every later "localhost:5432"
# connection (pgAdmin, psql, import-local-data.sh) would then talk to the
# container instead of the real local Postgres, making local data look like
# it vanished when it was only ever shadowed.
read -p "Host port to publish [5433]: " HOST_PORT
HOST_PORT="${HOST_PORT:-5433}"

# Catches the case the default above doesn't: someone explicitly choosing a
# port that's already claimed by something reachable right now.
if (exec 3<>/dev/tcp/127.0.0.1/"$HOST_PORT") 2>/dev/null; then
    exec 3>&-
    echo "⚠️  Something is already listening on localhost:${HOST_PORT}."
    read -p "Continue anyway and let Docker attempt the bind? (y/N): " port_confirm
    if [[ ! "$port_confirm" =~ ^[Yy]$ ]]; then
        echo "Aborting."
        exit 1
    fi
fi

read -p "Host directory for Postgres data [$DEFAULT_VOLUME_DIR]: " VOLUME_DIR
VOLUME_DIR="${VOLUME_DIR:-$DEFAULT_VOLUME_DIR}"
mkdir -p "$VOLUME_DIR"

# Hidden input: this is a credential, don't echo it to the terminal. Loop
# until non-empty - the entrypoint itself hard-requires POSTGRES_PASSWORD
# and would otherwise fail deep inside `docker run` instead of here. Labeled
# with the container name since import-local-data.sh prompts for a second,
# different password (the SOURCE local Postgres's) later in this same flow.
POSTGRES_PASSWORD=""
while [ -z "$POSTGRES_PASSWORD" ]; do
    read -s -p "Postgres superuser password for the NEW container '${CONTAINER}': " POSTGRES_PASSWORD
    echo ""
    if [ -z "$POSTGRES_PASSWORD" ]; then
        echo "Password cannot be empty."
    fi
done

# Guard: don't silently clobber an existing container of the same name.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "A container named '$CONTAINER' already exists."
    read -p "Stop and remove it and continue? (y/N): " replace_input
    if [[ "$replace_input" =~ ^[Yy]$ ]]; then
        docker rm -f "$CONTAINER" >/dev/null
    else
        echo "Aborting to avoid clobbering the existing container."
        exit 1
    fi
fi

echo ""
echo "── Starting container ──"
echo "Starting ${IMAGE_NAME} as '${CONTAINER}'..."
docker run -d --name "$CONTAINER" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -p "${HOST_PORT}:5432" \
    -v "${VOLUME_DIR}:/var/lib/postgresql/data" \
    "$IMAGE_NAME"

# First-run initdb takes a few seconds - poll pg_isready rather than
# declaring success the instant `docker run` returns.
echo -n "Waiting for Postgres to accept connections..."
READY=0
for _ in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        READY=1
        break
    fi
    echo -n "."
    sleep 1
done
echo ""
if [ "$READY" -ne 1 ]; then
    echo "❌ Postgres did not become ready in time. Check: docker logs $CONTAINER" >&2
    exit 1
fi
echo "✅ Postgres is ready on localhost:${HOST_PORT} (container '$CONTAINER')."

echo ""
echo "── Schema init ──"
read -p "Initialize/verify the Datastore.jl schema now? (Y/n): " schema_input
if [[ ! "$schema_input" =~ ^[Nn]$ ]]; then
    docker exec "$CONTAINER" bash -lc \
        'source /home/packages/hydrorisk.env && julia --project=$DATASTORE -e "using Datastore; Datastore.get_db()"'
fi

echo ""
echo "── Data import ──"
read -p "Import data from a local Postgres now? (y/N): " import_input
if [[ "$import_input" =~ ^[Yy]$ ]]; then
    read -p "Source host [localhost]: " SRC_HOST
    read -p "Source port [5432]: " SRC_PORT
    read -p "Source user [postgres]: " SRC_USER
    read -p "Source database [hydrorisk]: " SRC_DB
    read -p "Target database in container [hydrorisk]: " TARGET_DB

    export SRC_HOST="${SRC_HOST:-localhost}"
    export SRC_PORT="${SRC_PORT:-5432}"
    export SRC_USER="${SRC_USER:-postgres}"
    export SRC_DB="${SRC_DB:-hydrorisk}"
    "$SH_DIR/import-local-data.sh" "$CONTAINER" "${TARGET_DB:-hydrorisk}"
fi

echo ""
echo "✅ Done. Container '$CONTAINER' is running."

echo ""
echo "── Julia REPL ──"
read -p "Open a Datastore.jl REPL now? (y/N): " repl_input
if [[ "$repl_input" =~ ^[Yy]$ ]]; then
    # Postgres keeps running in the background (started with -d above) -
    # this just attaches an interactive process alongside it, same as any
    # other `docker exec`.
    docker exec -it "$CONTAINER" bash -lc \
        'source /home/packages/hydrorisk.env && julia --project=$DATASTORE'
fi
