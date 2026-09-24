#!/bin/bash
set -euo pipefail
# deploy.sh
#
# One-command entry point for the whole stack: makes sure .env exists,
# loads image tarballs from ./images/ if they aren't already in the local
# Docker daemon, brings db+api up (and daemon, if asked for), then waits for
# db to be healthy and api to actually accept connections, and finally
# offers to import data from a local Postgres via import-local-db-data.sh.
#
# Usage: ./deploy.sh [--reload]
#   --reload   always (re)load every ./images/*.tar, even if images with the
#              same tags already exist locally - use after copying over
#              freshly built tarballs.
#
# Images themselves aren't built here - each service's own docker-build.sh
# does that (see docker/container/{db,api,daemon}).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SH_DIR"

RELOAD=0
for arg in "$@"; do
    case "$arg" in
        --reload) RELOAD=1 ;;
        *)
            echo "Usage: $0 [--reload]" >&2
            exit 1
            ;;
    esac
done

# Loads every image tarball in ./images/ into the local Docker daemon, so
# docker-compose.yml's `image:` references (hydrorisk-db:latest,
# hydrorisk-api:latest, hydrorisk-daemon:runtime) resolve without a
# `build:` step.
load_images() {
    local images_dir="$SH_DIR/images"
    local tars
    shopt -s nullglob
    tars=("$images_dir"/*.tar)
    shopt -u nullglob

    if [ ${#tars[@]} -eq 0 ]; then
        echo "❌ No .tar files found in $images_dir - build the images first (docker/container/{db,api,daemon} each have their own docker-build.sh)." >&2
        exit 1
    fi

    for tar in "${tars[@]}"; do
        echo "Loading $(basename "$tar")..."
        docker load -i "$tar"
    done
}

if [ ! -f .env ]; then
    echo "No .env found - copying .env.example to .env."
    cp .env.example .env
    echo "❌ Edit .env (set POSTGRES_PASSWORD at least), then re-run this script." >&2
    exit 1
fi
# docker compose loads .env on its own; sourced here too so this script's
# own port-wait/status lines below reflect the same values instead of
# falling back to their hardcoded defaults.
set -a
source .env
set +a

# Unless --reload, only load from images/*.tar if at least one of the three
# images isn't already present locally - on the machine that built them,
# this is a no-op.
if [ "$RELOAD" -eq 1 ]; then
    echo "── Reloading images ──"
    load_images
else
    NEED_LOAD=0
    for img in hydrorisk-db:latest hydrorisk-api:latest hydrorisk-daemon:runtime; do
        docker image inspect "$img" >/dev/null 2>&1 || NEED_LOAD=1
    done
    if [ "$NEED_LOAD" -eq 1 ]; then
        echo "One or more images aren't loaded locally yet."
        load_images
    fi
fi

read -p "Also start daemon? (needs a GPU, or falls back to CPU) [y/N]: " with_daemon
# --pull never: these images only ever come from images/*.tar, never a
# registry - a missing image should fail as such, not as a confusing
# "pull access denied".
COMPOSE_ARGS=(up -d --pull never)
if [[ "$with_daemon" =~ ^[Yy]$ ]]; then
    COMPOSE_ARGS=(--profile daemon up -d --pull never)
fi

echo ""
echo "── Starting containers ──"
docker compose "${COMPOSE_ARGS[@]}"

# db's own healthcheck (pg_isready) already gates api's startup via
# depends_on: condition: service_healthy - this just waits for api's
# published port to actually start accepting connections too, same
# TCP-probe pattern used by docker-run.sh.
API_PORT="${API_HOST_PORT:-8001}"
echo ""
echo -n "Waiting for the API to accept connections..."
READY=0
for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$API_PORT") 2>/dev/null; then
        exec 3>&-
        READY=1
        break
    fi
    echo -n "."
    sleep 1
done
echo ""
if [ "$READY" -ne 1 ]; then
    echo "❌ API did not become ready in time. Check: docker compose logs api" >&2
    exit 1
fi

echo "✅ Stack is up. API: http://localhost:${API_PORT}/  ·  DB: localhost:${DB_HOST_PORT:-5433}"
docker compose ps

# A fresh db-data volume only gets Datastore.jl's empty schemas - no users,
# so every client request is answered 401 until data is imported. Flag that
# case explicitly before offering the import.
DB_NAME_EFFECTIVE="${DB_NAME:-hydrorisk}"
USER_COUNT=$(docker exec hydrorisk-db psql -U postgres -d "$DB_NAME_EFFECTIVE" -Atc \
    "select count(*) from core.users" 2>/dev/null || echo "?")
echo ""
if [ "$USER_COUNT" = "0" ]; then
    echo "⚠️  Database '$DB_NAME_EFFECTIVE' has no users yet - clients will get 401 Unauthorized until data is imported."
fi
read -p "Import data from your local Postgres (import-local-db-data.sh)? [y/N]: " do_import
if [[ "$do_import" =~ ^[Yy]$ ]]; then
    # Not fatal: the stack is already up, a failed import (e.g. local
    # Postgres not running) can just be retried on its own.
    if ! "$SH_DIR/import-local-db-data.sh" hydrorisk-db "$DB_NAME_EFFECTIVE"; then
        echo "❌ Import failed - the stack is still running. Fix the cause (is your local Postgres up?) and re-run: $SH_DIR/import-local-db-data.sh" >&2
        exit 1
    fi
fi
