#!/bin/bash
set -euo pipefail

# prep-context.sh
#
# Stages a minimal, sibling-layout-preserving copy of the three Julia packages
# that make up the daemon image into
#   docker/daemon/.context/packages/<pkg>/
# so that `docker build` (context = docker/daemon/) can COPY them.
# The staging dir is hidden (.context) and transient - docker-build.sh
# removes it after the build.
#
# Why staging: the real source trees carry multi-GB .git dirs (cORIUm.jl ~6G,
# OsmotiC.jl ~1G) plus dump/ docs/ job/ logs/ test/ that the build never needs.
# Why sibling layout: OsmotiC.jl/Manifest.toml pins its deps by RELATIVE path
#   path = "../cORIUm.jl"  and  path = "../Datastore.jl"
# so all three must sit side by side for Pkg.instantiate() to resolve offline.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# docker/daemon/ -> docker/ -> Hydrorisk/ -> git/  (holds the packages)
GIT_ROOT=$( cd -- "$SH_DIR/../../../.." &> /dev/null && pwd )

DEST="$SH_DIR/.context/packages"
PACKAGES=("cORIUm.jl" "OsmotiC.jl" "Datastore.jl")

# rsync filter: keep only what a dependency resolve / precompile needs.
INCLUDES=(
    --include="Project.toml"
    --include="Manifest.toml"
    --include="LICENSE"
    --include="README.md"
    --include="src/***"
    --include="ext/***"
)
# NOTE: Datastore.jl/env/ (a local, git-ignored db-config.toml holding the DB
# password) is deliberately NOT staged - the image carries no DB credentials.
# They are supplied at container start instead (see entrypoint.sh).
EXCLUDES=(
    --exclude=".git/"
    --exclude=".github/"
    --exclude="dump/"
    --exclude="**/dump/"
    --exclude="job/"
    --exclude="logs/"
    --exclude="docs/"
    --exclude="test/"
    --exclude="reproduction/"
    --exclude="build/"
    --exclude="LocalPreferences.toml"
    --exclude="*.code-workspace"
    --exclude="*.h5"
    --exclude="*.jld2"
    --exclude="*.tar"
    --exclude=".DS_Store"
    --exclude="*"
)

echo "GIT_ROOT: $GIT_ROOT"
# Wipe any prior staging, including a stale non-hidden "context/" from an
# earlier layout so the Dockerfile's `COPY .context/...` can't pick it up.
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
