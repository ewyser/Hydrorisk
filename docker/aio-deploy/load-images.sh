#!/bin/bash
set -euo pipefail
# load-images.sh
#
# Loads every image tarball in ./images/ into the local Docker daemon, so
# docker-compose.yml's `image:` references (hydrorisk-db:latest,
# hydrorisk-api:latest, hydrorisk-daemon:runtime) resolve without a
# `build:` step.
#
# Needed whenever this directory (aio-deploy/) was copied to a machine that
# didn't build the images itself - on the machine that ran each service's
# docker-build.sh, the images are already in the local Docker daemon and
# this is a no-op-ish re-load of the same content.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
IMAGES_DIR="$SH_DIR/images"

shopt -s nullglob
TARS=("$IMAGES_DIR"/*.tar)
shopt -u nullglob

if [ ${#TARS[@]} -eq 0 ]; then
    echo "❌ No .tar files found in $IMAGES_DIR - build the images first (docker/db, docker/api, docker/daemon each have their own docker-build.sh)." >&2
    exit 1
fi

for tar in "${TARS[@]}"; do
    echo "Loading $(basename "$tar")..."
    docker load -i "$tar"
done

echo ""
echo "✅ Done. Run 'docker compose up -d' (or --profile daemon) next."
