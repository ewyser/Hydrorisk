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

read -p "Host port to publish [5432]: " HOST_PORT
HOST_PORT="${HOST_PORT:-5432}"

read -p "Host directory for Postgres data [$DEFAULT_VOLUME_DIR]: " VOLUME_DIR
VOLUME_DIR="${VOLUME_DIR:-$DEFAULT_VOLUME_DIR}"
mkdir -p "$VOLUME_DIR"

# Hidden input: this is a credential, don't echo it to the terminal. Loop
# until non-empty - the entrypoint itself hard-requires POSTGRES_PASSWORD
# and would otherwise fail deep inside `docker run` instead of here.
POSTGRES_PASSWORD=""
while [ -z "$POSTGRES_PASSWORD" ]; do
    read -s -p "Postgres password: " POSTGRES_PASSWORD
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

read -p "Initialize/verify the Datastore.jl schema now? (Y/n): " schema_input
if [[ ! "$schema_input" =~ ^[Nn]$ ]]; then
    docker exec "$CONTAINER" bash -lc \
        'source /home/packages/hydrorisk.env && julia --project=$DATASTORE -e "using Datastore; Datastore.get_db()"'
fi

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
