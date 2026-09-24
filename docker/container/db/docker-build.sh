#!/bin/bash
set -euo pipefail
# docker-build.sh
#
# Builds the hydrorisk-db image (Postgres + PostGIS + Datastore.jl) and
# saves it into ../../aio-deploy/images/ - docker-compose.yml is the only
# supported way to actually run it (see docker/aio-deploy/).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_NAME="hydrorisk-db"
AIO_IMAGES_DIR="$SH_DIR/../../aio-deploy/images"
IMAGE_TAR="$AIO_IMAGES_DIR/${IMAGE_NAME}.tar"

# prep-context.sh stages Datastore.jl into .context/packages/ before
# building; always tear it down again, however the script ends.
trap 'rm -rf "$SH_DIR/.context"' EXIT

echo "Staging package sources (prep-context.sh)..."
"$SH_DIR/prep-context.sh" || { echo "❌ prep-context.sh failed"; exit 1; }

if [ ! -f "$SH_DIR/.context/packages/Datastore.jl/Project.toml" ]; then
    echo "❌ .context/packages/Datastore.jl is missing or empty after staging - aborting." >&2
    exit 1
fi

mkdir -p "$AIO_IMAGES_DIR"
if [ -f "$IMAGE_TAR" ]; then
    echo "Image tarball already exists at: $IMAGE_TAR"
    read -p "Delete it and continue? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm "$IMAGE_TAR"
    else
        echo "Aborting to avoid overwriting existing tarball."
        exit 1
    fi
fi

# Phrased positively (docker has no literal --use-cache flag - caching is
# just its default behavior) so "no" clearly maps to disabling it, instead
# of the double-negative "Use --no-cache? (y/N)".
BUILD_ARGS=()
read -p "Use --use-cache? (Y/n): " cache_input
if [[ "$cache_input" =~ ^[Nn]$ ]]; then
    BUILD_ARGS+=(--no-cache)
fi

export DOCKER_BUILDKIT=1

# Context is docker/ (one level up), not this directory alone - Dockerfile
# COPYs the shared docker/unix/install/julia.sh directly (no per-service
# sync copy needed) alongside this service's own db/.context/packages/ and
# db/entrypoint.sh, both prefixed accordingly in the Dockerfile's COPY
# instructions.
echo "Building Docker image '$IMAGE_NAME'..."
# "${arr[@]+"${arr[@]}"}" (not just "${arr[@]}") because macOS's default
# bash (3.2) treats expanding an empty array as an unbound variable under
# `set -u`, even though modern bash doesn't.
docker build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" -f "$SH_DIR/Dockerfile" -t "$IMAGE_NAME" "$SH_DIR/.."

echo "Saving image ${IMAGE_NAME}:latest to tarball..."
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:latest"

echo ""
echo "✅ Ready: $IMAGE_TAR"
echo "   docker/aio-deploy/deploy.sh --reload loads it and starts the stack."
echo "   For a one-off data import from a local Postgres, see"
echo "   docker/aio-deploy/import-local-db-data.sh."
