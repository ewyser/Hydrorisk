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
# once the image is saved. A .dockerignore keeps shipping/ and any stray .git
# out of the context.
# Always tear down the staging dir on exit, however the script ends (build
# failure, Ctrl-C, or success) - it's purely transient scaffolding.
trap 'rm -rf "$SH_DIR/.context"' EXIT

BUILD_CTXT="$SH_DIR"
DOCKER_DIR="$SH_DIR"
IMAGE_NAME="daemon"

# Ship-ready output: the whole shipping/ folder (loader scripts + image/
# tarball) is the deliverable - zip it and copy it to the target machine.
SHIP_DIR="$SH_DIR/shipping"
IMAGE_TAR="$SHIP_DIR/image/${IMAGE_NAME}-${STAGE}.tar"
mkdir -p "$SHIP_DIR/image"

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
BUILD_ARGS=""
read -p "Use --no-cache? (y/N): " nocache_input
if [[ "$nocache_input" =~ ^[Yy]$ ]]; then
    BUILD_ARGS="--no-cache"
fi
# The Dockerfile's `deps` stage COPYs .context/packages/, so Docker
# content-hashes it automatically - changed package files re-run `deps`
# (Pkg.instantiate/add, GBs of artifacts) and everything on top; an unchanged
# staging directory keeps the cache. No CACHEBUST / GitHub token needed.
docker build $BUILD_ARGS \
    -f "$DOCKER_DIR/Dockerfile" --target "$STAGE" \
    -t "$IMAGE_NAME:$STAGE" "$BUILD_CTXT"
echo "Saving image ${IMAGE_NAME}:${STAGE} to tarball..."
docker save -o "$IMAGE_TAR" "$IMAGE_NAME:$STAGE"

# (.context/ is removed by the EXIT trap set above.)

# Package the rest of the shipping/ deliverable: keep the loader scripts
# in sync with their source copies on every build.
cp -f "$SH_DIR/docker-load-runtime.sh" "$SHIP_DIR/docker-load-runtime.sh"
cp -f "$SH_DIR/docker-load-runtime.bat" "$SHIP_DIR/docker-load-runtime.bat"
chmod +x "$SHIP_DIR/docker-load-runtime.sh"

echo ""
echo "✅ Ready to ship: $SHIP_DIR"
echo "   Zip and copy this whole folder to the target machine, then run"
echo "   docker-load-runtime.sh (Linux/macOS) or docker-load-runtime.bat"
echo "   (Windows) from inside it."
