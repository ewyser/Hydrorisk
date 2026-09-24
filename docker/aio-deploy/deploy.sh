#!/bin/bash
set -euo pipefail
# deploy.sh
#
# One-command entry point for the whole stack: makes sure .env exists,
# loads image tarballs from ./images/ if they aren't already in the local
# Docker daemon, offers to dump the local Postgres into the first-start seed
# (volume/db-seed/hydrorisk.sql) when volume/db-data is still empty, brings
# db+api up (and daemon, if asked for), then waits for db to be healthy and
# api to actually accept connections before returning.
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

# First start on an empty db-data: the db container restores
# volume/db-seed/hydrorisk.sql, if present, as the initial database before
# Datastore.jl gets to bootstrap an empty one (see
# docker/container/db/seed-db.sh). Offer to (re)create that dump from the
# local Postgres now - before anything starts, so a failing dump (local
# Postgres down, wrong password) stops here instead of mid-deploy. Once
# db-data is populated the seed is never read again, so skip all of this.
DB_DATA_DIR="$SH_DIR/../volume/db-data"
SEED_FILE="$SH_DIR/../volume/db-seed/hydrorisk.sql"
if [ -z "$(ls -A "$DB_DATA_DIR" 2>/dev/null)" ]; then
    echo ""
    echo "── Database seed ──"
    echo "volume/db-data is empty - the database will be created on this start."
    if [ -f "$SEED_FILE" ]; then
        echo "Existing seed: volume/db-seed/hydrorisk.sql ($(du -h "$SEED_FILE" | cut -f1), $(date -r "$SEED_FILE" '+%Y-%m-%d %H:%M'))"
        read -p "Refresh it from your local Postgres first? [y/N]: " do_dump
    else
        echo "No seed dump found - without one, the database starts empty (no users, clients get 401)."
        read -p "Dump your local Postgres into volume/db-seed/hydrorisk.sql now? [y/N]: " do_dump
    fi
    if [[ "$do_dump" =~ ^[Yy]$ ]]; then
        "$SH_DIR/import-local-db-data.sh" --dump "$SEED_FILE" || {
            echo "❌ Dump failed - nothing was started. Is your local Postgres running?" >&2
            exit 1
        }
    fi
fi

echo ""
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

# Started without a seed (or on an old db-data that never got data), the
# database only has Datastore.jl's empty schemas - no users, so every client
# request is answered 401. Say so, with the two ways out.
DB_NAME_EFFECTIVE="${DB_NAME:-hydrorisk}"
USER_COUNT=$(docker exec hydrorisk-db psql -U postgres -d "$DB_NAME_EFFECTIVE" -Atc \
    "select count(*) from core.users" 2>/dev/null || echo "?")
if [ "$USER_COUNT" = "0" ]; then
    echo ""
    echo "⚠️  Database '$DB_NAME_EFFECTIVE' has no users - clients will get 401 Unauthorized."
    # A failed first-start seed leaves exactly this state (seed-db.sh drops
    # the half-restored database, Datastore then bootstraps an empty one).
    if docker logs hydrorisk-db 2>&1 | grep -q "❌ seed-db"; then
        echo "   The seed restore failed on first start - see: docker compose logs db | grep -B5 seed-db"
    fi
    echo "   Import into the running db:  $SH_DIR/import-local-db-data.sh"
    echo "   Or reseed from scratch:      docker compose down, delete volume/db-data, re-run ./deploy.sh"
fi
