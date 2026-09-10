#!/bin/bash
# docker-load-run.sh
#
# Deployment-side counterpart to docker-build-tar.sh: loads a saved
# cORIUm.jl runtime image tarball and runs it. Run this on the machine
# that will actually execute the container (the GPU host) - see
# docs/src/mpi.md, "Docker deployment", for the full build-vs-run story.

set -e

IMAGE_NAME="ubuntu-corium"
STAGE="runtime"
IMAGE_TAG="${IMAGE_NAME}:${STAGE}"

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# --- locate the tarball ---
DEFAULT_TAR="${SH_DIR}/image/${IMAGE_NAME}-${STAGE}.tar"
read -p "Path to the image tarball [${DEFAULT_TAR}]: " IMAGE_TAR
IMAGE_TAR="${IMAGE_TAR:-$DEFAULT_TAR}"

if [ ! -f "$IMAGE_TAR" ]; then
    echo "No tarball found at: $IMAGE_TAR"
    exit 1
fi

echo "Loading image from ${IMAGE_TAR}..."
docker load -i "$IMAGE_TAR"

# --- optional host mount for simulation output ---
# The entrypoint/solver honor a VOLUME_MOUNT env var (see cORE!/cORES! in
# src/home/program/workflow/cORE.jl) to redirect output under a mounted
# host path, so it survives past the container's lifetime.
read -p "Host directory to mount as simulation output (leave empty to skip): " HOST_DIR
VOLUME_ARGS=()
if [[ -n "$HOST_DIR" ]]; then
    mkdir -p "$HOST_DIR"
    VOLUME_ARGS=(-v "${HOST_DIR}:/mnt/output" -e "VOLUME_MOUNT=/mnt/output")
    echo "Mounting ${HOST_DIR} -> /mnt/output (VOLUME_MOUNT)"
fi

# --- GPU access ---
GPU_ARGS=()
read -p "Enable GPU passthrough with --gpus all? [Y/n]: " gpu_input
if [[ ! "$gpu_input" =~ ^[Nn]$ ]]; then
    GPU_ARGS=(--gpus all)
fi

# entrypoint.sh (baked into the image) regenerates LocalPreferences.toml
# here, against whatever GPU/MPI is actually present in this container,
# before dropping into bash.
echo "Starting container from ${IMAGE_TAG}..."
docker run "${GPU_ARGS[@]}" "${VOLUME_ARGS[@]}" -it "$IMAGE_TAG"
