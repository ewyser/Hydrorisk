#!/bin/bash
set -euo pipefail

# --- output-mount permissions + privilege drop --------------------------
# The image runs the solver as the unprivileged "mpiuser" (OpenMPI refuses
# to run as root). A host directory bind-mounted at $VOLUME_MOUNT (e.g.
# `-v G:\out:/mnt/output` on Docker Desktop) lands owned by root:root and
# is not writable by mpiuser, so the solver dies with
# `mkdir("/mnt/output/dump"): permission denied (EACCES)`.
#
# Fix it while we still can: the container now *starts* as root (no more
# `USER mpiuser` in the Dockerfile), makes the mount writable, then drops
# to mpiuser for everything else. chown + chmod are both attempted, each
# failure-tolerant; on mount backends that ignore them (virtiofs for Windows
# drives) the solver's resolve_dump_dir() falls back to an in-container
# directory (see cORE.jl) rather than crashing.
if [ "$(id -u)" = "0" ]; then
    mount_dir="${VOLUME_MOUNT:-}"
    if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
        # Best-effort: create the dump/ subdir and hand the whole tree to
        # mpiuser. Each step is independent and failure-tolerant - some mount
        # backends (virtiofs for Windows drives) silently ignore chown/chmod,
        # in which case the solver's own resolve_dump_dir() falls back to an
        # in-container directory rather than crashing (see cORE.jl).
        mkdir -p "$mount_dir/dump"        2>/dev/null || true
        chown -R mpiuser:mpiuser "$mount_dir" 2>/dev/null || true
        chmod -R u+rwX,go+rwX    "$mount_dir" 2>/dev/null || true
        if ! su mpiuser -s /bin/sh -c "test -w '$mount_dir'" 2>/dev/null; then
            echo "⚠️  $mount_dir is not writable by mpiuser; simulation output"
            echo "    will be kept inside the container instead. Fix the mount"
            echo "    ownership on the host to persist results."
        fi
    fi
    # Drop to the unprivileged user for the actual workload (OpenMPI refuses
    # to run as root). Prefer runuser (util-linux); fall back to su.
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u mpiuser -- "$0" "$@"
    else
        exec su mpiuser -s /bin/bash -c 'exec "$@"' bash "$0" "$@"
    fi
fi

# --- database configuration -------------------------------------------
# OsmotiC.__init__ -> Datastore.load_env!(nothing) reads the DB settings
# from six env vars (PSWD_DB, HYDRORISK_DB_HOST/PORT/USER/NAME,
# HYDRORISK_API). It never looks for a config file on its own here, and if
# *all six* are unset it drops into an interactive readline() prompt that
# hangs a no-TTY container. So the connection details must arrive as
# environment.
#
# Nothing secret is baked into the image. Provide the details at run time,
# either directly (`docker run -e PSWD_DB=... -e HYDRORISK_DB_HOST=...`) or
# by bind-mounting the db-config.toml you already keep for local use:
#   docker run -v /host/path/env:/config:ro ...
# and this block translates it. Its layout (unchanged from Datastore's
# expectation):
#   [database]
#   host = "..."  port = 5432  user = "..."  name = "..."  password = "..."
#   [server]
#   api = true
# Explicit -e values always win: a key already in the environment is left
# untouched, matching load_env!'s own "fill missing only" rule.
ENV_DIR="${HYDRORISK_ENV:-/config}"
ENV_FILE="$ENV_DIR/db-config.toml"
if [ -f "$ENV_FILE" ]; then
    echo "Translating DB config from $ENV_FILE into the environment..."
    _toml_get() {
        # flat "key = value" lookup; the six keys are unique across the two
        # sections so no section tracking is needed. Strips surrounding
        # quotes and trailing whitespace/comments.
        grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" | head -n1 \
            | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"(.*)"$/\1/'
    }
    _set_missing() {
        # $1 = env var name, $2 = TOML key
        [ -n "${!1:-}" ] && return 0
        local v; v="$(_toml_get "$2")"
        [ -n "$v" ] && export "$1=$v"
    }
    _set_missing PSWD_DB           password
    _set_missing HYDRORISK_DB_HOST host
    _set_missing HYDRORISK_DB_PORT port
    _set_missing HYDRORISK_DB_USER user
    _set_missing HYDRORISK_DB_NAME name
    _set_missing HYDRORISK_API     api
fi

# Regenerates LocalPreferences.toml (MPI + CUDA + HDF5 config) on every
# container start, against whatever GPU/MPI is actually present at that
# moment, rather than baking it into the image at build time (which would
# happen in a GPU-less build environment and could never be verified
# there). Ask first, when there's a TTY to ask on - a container started
# without one (e.g. a scripted `docker run <image> julia -e '...'`) has
# no way to answer, so it defaults to yes, matching prior behavior.
#
# CORIUM_MPIEXEC_PATH / CORIUM_CUDA_VERSION / CORIUM_HDF5_LIB /
# CORIUM_HDF5_HL_LIB are set as image ENV vars in the Dockerfile, alongside
# CORIUM and OSMOTIC (the two bundled package project dirs under
# /home/mpiuser/packages). setup_mpi.jl reconfigures HDF5.jl / MPIPreferences
# in the shared depot, which OsmotiC.jl inherits - no separate OsmotiC boot
# step is needed. See
# src/boot/needs/setup_mpi.jl for the fallback, interactive behavior used
# when those aren't set (manual/bare-metal use).
if [ -t 0 ]; then
    read -r -p "Configure MPI/CUDA/HDF5 automatically now? [Y/n]: " answer || answer="y"
else
    answer="y"
fi

if [[ ! "$answer" =~ ^[Nn]$ ]]; then
    echo "Configuring MPI/CUDA/HDF5 (see src/boot/needs/setup_mpi.jl)..."
    julia --project="${CORIUM}" -e 'include(joinpath(ENV["CORIUM"], "src", "boot", "needs", "setup_mpi.jl"))'
else
    echo "Skipping automatic configuration - dropping straight into the image."
fi

exec "$@"
