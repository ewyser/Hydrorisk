#!/bin/bash
set -euo pipefail

# prep-context.sh
#
# Stages Datastore.jl and Hydrorisk.jl into docker/api/.context/packages/,
# preserving Hydrorisk.jl/Manifest.toml's RELATIVE path-dep:
#   path = "../../Datastore.jl"
# (two levels, because in the real source tree Hydrorisk.jl lives nested one
# extra level inside crealp-hydrorisk/). To reproduce that same relative
# distance here, Hydrorisk.jl is staged one level deeper than Datastore.jl:
#
#   .context/packages/Datastore.jl/
#   .context/packages/wrap/Hydrorisk.jl/   (../.. from here == .context/packages/)
#
# Also stages gis/ (Hydrorisk.__init__ calls build_plugin(), which zips
# gis/hydrorisk_plugin/ on module load - without it `using Hydrorisk` fails).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# docker/api/ -> docker/ -> Hydrorisk/ -> git/  (holds Datastore.jl)
GIT_ROOT=$( cd -- "$SH_DIR/../../../.." &> /dev/null && pwd )
HYDRORISK_JL_SRC="$GIT_ROOT/crealp-hydrorisk/Hydrorisk.jl"

DEST="$SH_DIR/.context/packages"

INCLUDES=(
    --include="Project.toml"
    --include="Manifest.toml"
    --include="LICENSE"
    --include="README.md"
    --include="src/***"
    --include="gis/***"
)
EXCLUDES=(
    --exclude=".git/"
    --exclude=".github/"
    --exclude="env/"
    --exclude="test/"
    --exclude="jobs/"
    --exclude="files/"
    --exclude=".vscode/"
    --exclude="*.code-workspace"
    --exclude="*.zip"
    --exclude=".DS_Store"
    --exclude="*"
)

echo "GIT_ROOT: $GIT_ROOT"
rm -rf "$SH_DIR/context" "$SH_DIR/.context"
mkdir -p "$DEST/wrap"

if [ ! -d "$GIT_ROOT/Datastore.jl" ]; then
    echo "❌ source package not found: $GIT_ROOT/Datastore.jl" >&2
    exit 1
fi
if [ ! -d "$HYDRORISK_JL_SRC" ]; then
    echo "❌ source package not found: $HYDRORISK_JL_SRC" >&2
    exit 1
fi

echo "→ staging Datastore.jl"
rsync -a --delete "${INCLUDES[@]}" "${EXCLUDES[@]}" "$GIT_ROOT/Datastore.jl/" "$DEST/Datastore.jl/"

echo "→ staging Hydrorisk.jl"
rsync -a --delete "${INCLUDES[@]}" "${EXCLUDES[@]}" "$HYDRORISK_JL_SRC/" "$DEST/wrap/Hydrorisk.jl/"

for pkg in "Datastore.jl" "wrap/Hydrorisk.jl"; do
    if [ ! -f "$DEST/$pkg/Project.toml" ] || [ ! -f "$DEST/$pkg/Manifest.toml" ]; then
        echo "❌ $pkg staged without Project.toml/Manifest.toml" >&2
        exit 1
    fi
done

echo "✅ staged into $DEST:"
find "$DEST" -maxdepth 2
