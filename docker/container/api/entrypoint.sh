#!/bin/bash
set -euo pipefail

# --- output-mount permissions + privilege drop --------------------------
# The server runs as the unprivileged "apiuser". A host directory
# bind-mounted at $VOLUME_MOUNT (docker-compose.yml: ../volume/api-data)
# lands owned by root:root on Linux and is not writable by apiuser - then
# Hydrorisk.__init__ would keep the QGIS plugin zip inside the container.
#
# Fix it while we still can: the container *starts* as root (no
# `USER apiuser` in the Dockerfile), makes the mount writable, then drops
# to apiuser for everything else - same as the daemon's entrypoint. Each
# step is failure-tolerant; on mount backends that ignore chown/chmod
# (virtiofs for Windows drives) Hydrorisk's resolve_out_dir() falls back
# to the in-package gis/ directory rather than crashing.
if [ "$(id -u)" = "0" ]; then
    mount_dir="${VOLUME_MOUNT:-}"
    if [ -n "$mount_dir" ] && [ -d "$mount_dir" ]; then
        chown -R apiuser:apiuser "$mount_dir" 2>/dev/null || true
        chmod -R u+rwX,go+rwX    "$mount_dir" 2>/dev/null || true
        if ! su apiuser -s /bin/sh -c "test -w '$mount_dir'" 2>/dev/null; then
            echo "⚠️  $mount_dir is not writable by apiuser; the QGIS plugin"
            echo "    zip will be kept inside the container instead. Fix the"
            echo "    mount ownership on the host to get it in volume/api-data/."
        fi
    fi
    # Drop to the unprivileged user for the server. Prefer runuser
    # (util-linux); fall back to su.
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u apiuser -- "$0" "$@"
    else
        exec su apiuser -s /bin/bash -c 'exec "$@"' bash "$0" "$@"
    fi
fi

# --- database configuration -------------------------------------------
# Datastore.load_env!(nothing) reads DB settings from six env vars (PSWD_DB,
# HYDRORISK_DB_HOST/PORT/USER/NAME, HYDRORISK_API). It never looks for a
# config file on its own, and if *all six* are unset it drops into an
# interactive readline() prompt that hangs a no-TTY container. So the
# connection details must arrive as environment.
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

exec "$@"
