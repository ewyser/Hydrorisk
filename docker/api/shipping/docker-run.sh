#!/bin/bash
set -euo pipefail
# docker-run.sh
#
# Interactive counterpart to docker-build.sh: runs the hydrorisk-api image,
# waits for it to actually accept connections, and points it at a Postgres
# database (the one docker/db/docker-run.sh starts) via the six env vars
# Datastore.load_env! needs.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_NAME="hydrorisk-api"

# If the image isn't already loaded (e.g. this script was copied out of
# shipping/ onto another machine, or docker-build.sh's image was pruned),
# load it from the tarball docker-build.sh produces - checked both as a
# sibling (running from inside shipping/) and under shipping/image/
# (running the docker/api/ source copy directly).
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

read -p "Container name [hydrorisk-api]: " CONTAINER
CONTAINER="${CONTAINER:-hydrorisk-api}"

# Default is 8001, not the Dockerfile CMD's own 8000 - a developer running
# Hydrorisk.jl locally (outside Docker) for testing already defaults to
# Hydrorisk.start_server(port=8000), so defaulting the container to the same
# port risks the same silent-port-shadowing confusion worked through for
# docker/db (see that script's own port default/comment).
read -p "Host port to publish [8001]: " HOST_PORT
HOST_PORT="${HOST_PORT:-8001}"

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

echo ""
echo "── Database connection ──"
# Datastore.load_env! reads six env vars (PSWD_DB, HYDRORISK_DB_HOST/PORT/
# USER/NAME, HYDRORISK_API) and drops into an interactive readline() prompt
# if *none* are set - fatal in a container. Point this at the db service's
# *published host port*, not its internal 5432: the api container and the db
# container aren't on a shared Docker network here, so "localhost" from
# inside the api container means the api container itself, not the host.
# host.docker.internal is Docker Desktop's (macOS/Windows) special DNS name
# for reaching the host machine from inside a container.
read -p "DB host [host.docker.internal]: " DB_HOST
DB_HOST="${DB_HOST:-host.docker.internal}"

read -p "DB port [5433]: " DB_PORT
DB_PORT="${DB_PORT:-5433}"

read -p "DB user [postgres]: " DB_USER
DB_USER="${DB_USER:-postgres}"

read -p "DB name [hydrorisk]: " DB_NAME
DB_NAME="${DB_NAME:-hydrorisk}"

# Hidden input: this is a credential, don't echo it to the terminal. Labeled
# with host/port since this is a third distinct password in this project's
# workflow (alongside the db container's own superuser password and the
# local-Postgres source password import-local-data.sh asks for) - easy to
# mix up without saying which one this is.
DB_PASSWORD=""
while [ -z "$DB_PASSWORD" ]; do
    read -s -p "DB password for '${DB_USER}'@'${DB_HOST}:${DB_PORT}': " DB_PASSWORD
    echo ""
    if [ -z "$DB_PASSWORD" ]; then
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
    -p "${HOST_PORT}:8000" \
    -e HYDRORISK_DB_HOST="$DB_HOST" \
    -e HYDRORISK_DB_PORT="$DB_PORT" \
    -e HYDRORISK_DB_USER="$DB_USER" \
    -e HYDRORISK_DB_NAME="$DB_NAME" \
    -e PSWD_DB="$DB_PASSWORD" \
    -e HYDRORISK_API=true \
    "$IMAGE_NAME"

# No pg_isready equivalent here - poll the published HTTP port directly with
# the same pure-bash TCP probe used above for the collision check, just
# waiting for it to *start* answering instead of warning that it already is.
echo -n "Waiting for the API to accept connections..."
READY=0
for _ in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$HOST_PORT") 2>/dev/null; then
        exec 3>&-
        READY=1
        break
    fi
    echo -n "."
    sleep 1
done
echo ""
if [ "$READY" -ne 1 ]; then
    echo "❌ API did not become ready in time. Check: docker logs $CONTAINER" >&2
    exit 1
fi
echo "✅ API is ready on localhost:${HOST_PORT} (container '$CONTAINER')."

echo ""
echo "✅ Done. Container '$CONTAINER' is running."
