#!/bin/bash
# docker-build.sh

# Define valid STAGE options & interactive selection. `deps` is the Dockerfile's
# intermediate stage (dependency resolution) - useful to target directly when
# debugging Pkg.instantiate/add in isolation without a full runtime build.
VALID_STAGES=("builder" "runtime" "deps")
echo "Please select the stage:"
select STAGE in "${VALID_STAGES[@]}" "Cancel"; do
    # Check if the selected STAGE is valid by matching with VALID_STAGES array
    if [[ " ${VALID_STAGES[@]} " =~ " ${STAGE} " ]]; then
        echo "You selected: $STAGE"
        break
    elif [ "$STAGE" == "Cancel" ]; then
        echo "Operation canceled."
        exit 0
    else
        echo "Invalid selection. Please choose a valid option."
    fi
done

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Build context is this directory (docker/daemon/). prep-context.sh
# stages cORIUm.jl + OsmotiC.jl + Datastore.jl into .context/packages/ first;
# the Dockerfile COPYs from there. That hidden staging dir is removed again
# once the image is saved.
# Always tear down the staging dir on exit, however the script ends (build
# failure, Ctrl-C, or success) - it's purely transient scaffolding.
trap 'rm -rf "$SH_DIR/.context"' EXIT

# Context is docker/ (one level up), not this directory alone - Dockerfile
# COPYs the shared docker/unix/install/{julia,hdf5,openmpi}.sh directly (no
# per-service sync copy needed) alongside this service's own
# daemon/.context/packages/ and daemon/entrypoint.sh, both prefixed
# accordingly in the Dockerfile's COPY instructions.
BUILD_CTXT="$SH_DIR/.."
DOCKER_DIR="$SH_DIR"
IMAGE_NAME="hydrorisk-daemon"

# Only the `runtime` stage is ever actually run (via docker-compose.yml,
# see docker/deploy/) - it's the only one saved as a tarball, into the
# centralized ../deploy/images/. `builder`/`deps` stay local-image-only,
# for debugging Pkg.instantiate/add or the pre-precompile layer in isolation.
DEPLOY_IMAGES_DIR="$SH_DIR/../../deploy/images"
IMAGE_TAR="$DEPLOY_IMAGES_DIR/${IMAGE_NAME}.tar"

if [ "$STAGE" = "runtime" ]; then
    mkdir -p "$DEPLOY_IMAGES_DIR"
    if [ -f "$IMAGE_TAR" ]; then
        echo "Image tarball already exists at: $IMAGE_TAR"
        read -p "Delete it and continue? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Deleting existing tarball..."
            rm "$IMAGE_TAR"
        else
            echo "Aborting to avoid overwriting existing tarball."
            exit 1
        fi
    fi
fi

# Stage the package sources into .context/packages/ before building.
echo "Staging package sources (prep-context.sh)..."
"$SH_DIR/prep-context.sh" || { echo "❌ prep-context.sh failed"; exit 1; }

# Guard: the Dockerfile's `deps` stage does `COPY .context/packages/ ...`, which
# fails obscurely ("/.context/packages: not found") if staging silently produced
# nothing. Verify all three package trees landed before handing off to Docker.
for pkg in cORIUm.jl OsmotiC.jl Datastore.jl; do
    if [ ! -f "$SH_DIR/.context/packages/$pkg/Project.toml" ]; then
        echo "❌ .context/packages/$pkg is missing or empty after staging - aborting."
        exit 1
    fi
done

export DOCKER_BUILDKIT=1

# Build & save the image to a tarball
echo "Building Docker image '$IMAGE_NAME' for stage '$STAGE'..."
# Phrased positively (docker has no literal --use-cache flag - caching is
# just its default behavior) so "no" clearly maps to disabling it, instead
# of the double-negative "Use --no-cache? (y/N)".
BUILD_ARGS=""
read -p "Use --use-cache? (Y/n): " cache_input
if [[ "$cache_input" =~ ^[Nn]$ ]]; then
    BUILD_ARGS="--no-cache"
fi
# The Dockerfile's `deps` stage COPYs .context/packages/, so Docker
# content-hashes it automatically - changed package files re-run `deps`
# (Pkg.instantiate/add, GBs of artifacts) and everything on top; an unchanged
# staging directory keeps the cache. No CACHEBUST / GitHub token needed.
docker build $BUILD_ARGS \
    -f "$DOCKER_DIR/Dockerfile" --target "$STAGE" \
    -t "$IMAGE_NAME:$STAGE" "$BUILD_CTXT"

if [ "$STAGE" = "runtime" ]; then
    echo "Saving image ${IMAGE_NAME}:${STAGE} to tarball..."
    docker save -o "$IMAGE_TAR" "$IMAGE_NAME:$STAGE"
    echo ""
    echo "✅ Ready: $IMAGE_TAR"
    echo "   docker/deploy/deploy.sh --reload loads it and starts the"
    echo "   stack (answer y to start the daemon)."
else
    echo ""
    echo "✅ Built ${IMAGE_NAME}:${STAGE} (local image only, not saved as a tarball)."
fi
