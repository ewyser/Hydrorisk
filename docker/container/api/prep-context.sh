#!/bin/bash
set -euo pipefail

# prep-context.sh
#
# Stages Datastore.jl and Gateway.jl into docker/api/.context/packages/, side
# by side as in the source tree, preserving Gateway.jl/Manifest.toml's
# RELATIVE path-dep:
#   path = "../Datastore.jl"
#
#   .context/packages/Datastore.jl/
#   .context/packages/Gateway.jl/
#
# Also stages gis/ (Gateway.__init__ calls build_plugin(), which zips
# gis/hydrorisk_plugin/ on module load - without it `using Gateway` fails).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# docker/api/ -> docker/ -> Hydrorisk/ -> git/  (holds Datastore.jl)
GIT_ROOT=$( cd -- "$SH_DIR/../../../.." &> /dev/null && pwd )
GATEWAY_SRC="$GIT_ROOT/Gateway.jl"

DEST="$SH_DIR/.context/packages"

# rsync applies the first matching rule, so excludes that must also apply
# inside an included dir (e.g. a stale gis/hydrorisk_plugin.zip - the api
# builds a fresh one at startup) go here, before INCLUDES.
PRE_EXCLUDES=(
    --exclude="*.zip"
    --exclude=".DS_Store"
)
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
    --exclude="*"
)

echo "GIT_ROOT: $GIT_ROOT"
rm -rf "$SH_DIR/context" "$SH_DIR/.context"
mkdir -p "$DEST"

if [ ! -d "$GIT_ROOT/Datastore.jl" ]; then
    echo "❌ source package not found: $GIT_ROOT/Datastore.jl" >&2
    exit 1
fi
if [ ! -d "$GATEWAY_SRC" ]; then
    echo "❌ source package not found: $GATEWAY_SRC" >&2
    exit 1
fi

echo "→ staging Datastore.jl"
rsync -a --delete "${PRE_EXCLUDES[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" "$GIT_ROOT/Datastore.jl/" "$DEST/Datastore.jl/"

echo "→ staging Gateway.jl"
rsync -a --delete "${PRE_EXCLUDES[@]}" "${INCLUDES[@]}" "${EXCLUDES[@]}" "$GATEWAY_SRC/" "$DEST/Gateway.jl/"

for pkg in "Datastore.jl" "Gateway.jl"; do
    if [ ! -f "$DEST/$pkg/Project.toml" ]; then
        echo "❌ $pkg staged without Project.toml" >&2
        exit 1
    fi
done
# Only Gateway.jl is instantiated (see the Dockerfile's deps stage), so only
# it needs a Manifest. Datastore.jl is resolved through Gateway.jl's Manifest
# - and its repo gitignores Manifest.toml, so a fresh clone has none.
if [ ! -f "$DEST/Gateway.jl/Manifest.toml" ]; then
    echo "❌ Gateway.jl staged without Manifest.toml" >&2
    exit 1
fi

echo "✅ staged into $DEST:"
find "$DEST" -maxdepth 2
