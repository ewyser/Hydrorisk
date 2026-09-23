#!/bin/bash
set -euo pipefail

# prep-context.sh
#
# Stages a minimal copy of Datastore.jl into
#   docker/db/.context/packages/Datastore.jl/
# so that `docker build` (context = docker/db/) can COPY it.
# The staging dir is hidden (.context) and transient.
#
# Unlike daemon, Datastore.jl has no local path-deps, so no sibling
# layout is needed here - it is staged alone.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# docker/db/ -> docker/ -> Hydrorisk/ -> git/  (holds the packages)
GIT_ROOT=$( cd -- "$SH_DIR/../../../.." &> /dev/null && pwd )

DEST="$SH_DIR/.context/packages"
PACKAGES=("Datastore.jl")

# rsync filter: keep only what a dependency resolve / precompile needs.
INCLUDES=(
    --include="Project.toml"
    --include="Manifest.toml"
    --include="LICENSE"
    --include="README.md"
    --include="src/***"
)
# NOTE: Datastore.jl/env/ (a local, git-ignored db-config.toml holding the DB
# password) is deliberately NOT staged - the image carries no DB credentials.
# They are supplied at container start instead (see unix/entrypoint.sh).
EXCLUDES=(
    --exclude=".git/"
    --exclude=".github/"
    --exclude="env/"
    --exclude="test/"
    --exclude="*.code-workspace"
    --exclude=".DS_Store"
    --exclude="*"
)

echo "GIT_ROOT: $GIT_ROOT"
rm -rf "$SH_DIR/context" "$SH_DIR/.context"
mkdir -p "$DEST"

for pkg in "${PACKAGES[@]}"; do
    src="$GIT_ROOT/$pkg"
    if [ ! -d "$src" ]; then
        echo "❌ source package not found: $src" >&2
        exit 1
    fi
    echo "→ staging $pkg"
    rsync -a --delete "${INCLUDES[@]}" "${EXCLUDES[@]}" "$src/" "$DEST/$pkg/"
    if [ ! -f "$DEST/$pkg/Project.toml" ] || [ ! -f "$DEST/$pkg/Manifest.toml" ]; then
        echo "❌ $pkg staged without Project.toml/Manifest.toml" >&2
        exit 1
    fi
done

echo "✅ staged into $DEST:"
ls -1 "$DEST"
