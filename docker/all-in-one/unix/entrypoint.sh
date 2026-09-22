#!/bin/bash
set -euo pipefail

# --- output-mount permissions + privilege drop --------------------------
# Same rationale as docker/daemon/unix/entrypoint.sh: the container
# starts as root so a bind-mounted $VOLUME_MOUNT can be made writable by
# mpiuser before anything else runs (OpenMPI refuses to run as root anyway).
if [ "$(id -u)" = "0" ]; then
    mount_dir="${VOLUME_MOUNT:-}"
    if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
        mkdir -p "$mount_dir/dump"        2>/dev/null || true
        chown -R mpiuser:mpiuser "$mount_dir" 2>/dev/null || true
        chmod -R u+rwX,go+rwX    "$mount_dir" 2>/dev/null || true
        if ! su mpiuser -s /bin/sh -c "test -w '$mount_dir'" 2>/dev/null; then
            echo "⚠️  $mount_dir is not writable by mpiuser; simulation output"
            echo "    will be kept inside the container instead. Fix the mount"
            echo "    ownership on the host to persist results."
        fi
    fi
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u mpiuser -- "$0" "$@"
    else
        exec su mpiuser -s /bin/bash -c 'exec "$@"' bash "$0" "$@"
    fi
fi

# --- database configuration -------------------------------------------
# Same six env vars as docker/db and docker/api's entrypoints - see those
# for the full rationale. Datastore/OsmotiC/Hydorisk all read them via
# Datastore.load_env!.
ENV_DIR="${HYDRORISK_ENV:-/config}"
ENV_FILE="$ENV_DIR/db-config.toml"
if [ -f "$ENV_FILE" ]; then
    echo "Translating DB config from $ENV_FILE into the environment..."
    _toml_get() {
        grep -E "^[[:space:]]*$1[[:space:]]*=" "$ENV_FILE" | head -n1 \
            | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^"(.*)"$/\1/'
    }
    _set_missing() {
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

# --- MPI/CUDA/HDF5 configuration ---------------------------------------
# Only relevant to the compute role - skipped entirely for db/api, which
# never touch MPI or a GPU. See docker/daemon/unix/entrypoint.sh for
# the full rationale (regenerated fresh every start against whatever
# GPU/MPI is actually present, rather than baked in at build time).
_configure_mpi() {
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
}

# --- role dispatch -------------------------------------------------------
# This image bundles all three eventual services (daemon, db, api)
# for a first combined end-to-end test. ROLE picks which one to act as;
# unset/anything else falls back to a bare shell, same as before ROLE
# existed. `docker run` still lets you override with an explicit CMD too.
case "${ROLE:-}" in
    compute)
        _configure_mpi
        exec "$@"
        ;;
    api)
        exec julia --project="${HYDRORISK}" -e 'using Hydrorisk; Hydrorisk.start_server(port=8000, cli=false)'
        ;;
    db)
        exec julia --project="${DATASTORE}"
        ;;
    *)
        exec "$@"
        ;;
esac
