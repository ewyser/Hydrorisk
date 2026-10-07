#!/bin/bash
set -euo pipefail
# docker-build.sh
#
# Builds the hydrorisk-api image (Julia + Datastore.jl + Hydrorisk.jl) and
# saves it into ../../deploy/images/ - docker-compose.yml is the only
# supported way to actually run it (see docker/deploy/).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGE_NAME="hydrorisk-api"
DEPLOY_IMAGES_DIR="$SH_DIR/../../deploy/images"
IMAGE_TAR="$DEPLOY_IMAGES_DIR/${IMAGE_NAME}.tar.gz"

# prep-context.sh stages Datastore.jl + Hydrorisk.jl into .context/packages/
# before building; always tear it down again, however the script ends.
trap 'rm -rf "$SH_DIR/.context"' EXIT

echo "Staging package sources (prep-context.sh)..."
"$SH_DIR/prep-context.sh" || { echo "❌ prep-context.sh failed"; exit 1; }

for pkg in "Datastore.jl" "wrap/Hydrorisk.jl"; do
    if [ ! -f "$SH_DIR/.context/packages/$pkg/Project.toml" ]; then
        echo "❌ .context/packages/$pkg is missing or empty after staging - aborting." >&2
        exit 1
    fi
done

mkdir -p "$DEPLOY_IMAGES_DIR"
if [ -f "$IMAGE_TAR" ]; then
    echo "Image tarball already exists at: $IMAGE_TAR"
    read -p "Delete it and continue? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$IMAGE_TAR" "$IMAGE_TAR.ids"
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

# No --target needed: `runtime` is the Dockerfile's last stage, so a plain
# build already produces it. Context is docker/ (one level up), not this
# directory alone - Dockerfile COPYs the shared docker/unix/install/*.sh
# directly (no per-service sync copy needed) alongside this service's own
# api/.context/packages/ and api/entrypoint.sh, both prefixed
# accordingly in the Dockerfile's COPY instructions.
echo "Building Docker image '$IMAGE_NAME'..."
# "${arr[@]+"${arr[@]}"}" (not just "${arr[@]}") because macOS's default
# bash (3.2) treats expanding an empty array as an unbound variable under
# `set -u`, even though modern bash doesn't.
docker build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" -f "$SH_DIR/Dockerfile" -t "$IMAGE_NAME" "$SH_DIR/.."

# gzip-compressed, written atomically, plus a .ids sidecar for deploy.sh -
# see ../save-image.sh. `docker load -i` reads the .tar.gz as is.
"$SH_DIR/../save-image.sh" "$IMAGE_NAME:latest" "$IMAGE_TAR"

echo ""
echo "✅ Ready: $IMAGE_TAR"
echo "   docker/deploy/deploy.sh --reload loads it and starts the stack."
