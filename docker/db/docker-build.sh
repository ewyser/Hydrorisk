#!/bin/bash
set -euo pipefail
# docker-build.sh
#
# Builds the hydrorisk-db image (Postgres + PostGIS + Datastore.jl) and
# saves it into shipping/, alongside docker-run.sh and import-local-data.sh,
# so the whole shipping/ folder is the deliverable - same pattern as
# daemon's docker-build.sh / shipping/ output.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_NAME="hydrorisk-db"
SHIP_DIR="$SH_DIR/shipping"
IMAGE_TAR="$SHIP_DIR/image/${IMAGE_NAME}.tar"

# prep-context.sh stages Datastore.jl into .context/packages/ before
# building; always tear it down again, however the script ends.
trap 'rm -rf "$SH_DIR/.context"' EXIT

echo "Staging package sources (prep-context.sh)..."
"$SH_DIR/prep-context.sh" || { echo "❌ prep-context.sh failed"; exit 1; }

if [ ! -f "$SH_DIR/.context/packages/Datastore.jl/Project.toml" ]; then
    echo "❌ .context/packages/Datastore.jl is missing or empty after staging - aborting." >&2
    exit 1
fi

mkdir -p "$SHIP_DIR/image"
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

echo "Building Docker image '$IMAGE_NAME'..."
# "${arr[@]+"${arr[@]}"}" (not just "${arr[@]}") because macOS's default
# bash (3.2) treats expanding an empty array as an unbound variable under
# `set -u`, even though modern bash doesn't.
docker build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" -t "$IMAGE_NAME" "$SH_DIR"

echo "Saving image ${IMAGE_NAME}:latest to tarball..."
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:latest"

# Keep the run/import scripts in shipping/ in sync with their source copies
# on every build, so the folder is self-contained.
cp -f "$SH_DIR/docker-run.sh" "$SHIP_DIR/docker-run.sh"
cp -f "$SH_DIR/import-local-data.sh" "$SHIP_DIR/import-local-data.sh"
chmod +x "$SHIP_DIR/docker-run.sh" "$SHIP_DIR/import-local-data.sh"

echo ""
echo "✅ Ready: $SHIP_DIR"
echo "   Run ./shipping/docker-run.sh (it loads the tarball if the image"
echo "   isn't already present, then starts the container)."
