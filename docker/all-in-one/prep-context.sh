#!/bin/bash
set -euo pipefail

# prep-context.sh
#
# Stages all four Julia packages (cORIUm.jl, OsmotiC.jl, Datastore.jl,
# Hydrorisk.jl) into docker/all-in-one/.context/packages/, preserving both
# sibling-relative-path requirements at once:
#   OsmotiC.jl/Manifest.toml:   path = "../cORIUm.jl", path = "../Datastore.jl"
#   Hydrorisk.jl/Manifest.toml: path = "../../Datastore.jl"
#
#   .context/packages/cORIUm.jl/
#   .context/packages/Datastore.jl/
#   .context/packages/OsmotiC.jl/          (../cORIUm.jl, ../Datastore.jl OK)
#   .context/packages/wrap/Hydrorisk.jl/   (../../Datastore.jl OK)
#
# This is a superset/union of docker/daemon/prep-context.sh and
# docker/api/prep-context.sh - see those for the per-service rationale.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# docker/all-in-one/ -> docker/ -> Hydrorisk/ -> git/  (holds the packages)
GIT_ROOT=$( cd -- "$SH_DIR/../../.." &> /dev/null && pwd )
HYDRORISK_JL_SRC="$GIT_ROOT/crealp-hydrorisk/Hydrorisk.jl"

DEST="$SH_DIR/.context/packages"

INCLUDES=(
    --include="Project.toml"
    --include="Manifest.toml"
    --include="LICENSE"
    --include="README.md"
    --include="src/***"
    --include="ext/***"
    --include="gis/***"
)
EXCLUDES=(
    --exclude=".git/"
    --exclude=".github/"
    --exclude="env/"
    --exclude="dump/"
    --exclude="**/dump/"
    --exclude="job/"
    --exclude="jobs/"
    --exclude="files/"
    --exclude="logs/"
    --exclude="docs/"
    --exclude="test/"
    --exclude="reproduction/"
    --exclude="build/"
    --exclude=".vscode/"
    --exclude="LocalPreferences.toml"
    --exclude="*.code-workspace"
    --exclude="*.h5"
    --exclude="*.jld2"
    --exclude="*.tar"
    --exclude="*.zip"
    --exclude=".DS_Store"
    --exclude="*"
)

echo "GIT_ROOT: $GIT_ROOT"
rm -rf "$SH_DIR/context" "$SH_DIR/.context"
mkdir -p "$DEST/wrap"

for pkg in "cORIUm.jl" "OsmotiC.jl" "Datastore.jl"; do
    src="$GIT_ROOT/$pkg"
    if [ ! -d "$src" ]; then
        echo "❌ source package not found: $src" >&2
        exit 1
    fi
    echo "→ staging $pkg"
    rsync -a --delete "${INCLUDES[@]}" "${EXCLUDES[@]}" "$src/" "$DEST/$pkg/"
done

if [ ! -d "$HYDRORISK_JL_SRC" ]; then
    echo "❌ source package not found: $HYDRORISK_JL_SRC" >&2
    exit 1
fi
echo "→ staging Hydrorisk.jl"
rsync -a --delete "${INCLUDES[@]}" "${EXCLUDES[@]}" "$HYDRORISK_JL_SRC/" "$DEST/wrap/Hydrorisk.jl/"

for pkg in "cORIUm.jl" "OsmotiC.jl" "Datastore.jl" "wrap/Hydrorisk.jl"; do
    if [ ! -f "$DEST/$pkg/Project.toml" ] || [ ! -f "$DEST/$pkg/Manifest.toml" ]; then
        echo "❌ $pkg staged without Project.toml/Manifest.toml" >&2
        exit 1
    fi
done

echo "✅ staged into $DEST:"
find "$DEST" -maxdepth 2
