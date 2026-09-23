#!/bin/bash
set -euo pipefail
# deploy.sh
#
# One-command entry point for the whole stack: makes sure .env exists,
# loads image tarballs if they aren't already in the local Docker daemon,
# brings db+api up (and daemon, if asked for), then waits for db to be
# healthy and api to actually accept connections before returning.
#
# Images themselves aren't built here - each service's own docker-build.sh
# does that (see docker/db, docker/api, docker/daemon).

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SH_DIR"

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

# Only load from images/*.tar if at least one of the three images isn't
# already present locally - on the machine that built them, this is a no-op.
NEED_LOAD=0
for img in hydrorisk-db:latest hydrorisk-api:latest daemon:runtime; do
    docker image inspect "$img" >/dev/null 2>&1 || NEED_LOAD=1
done
if [ "$NEED_LOAD" -eq 1 ]; then
    echo "One or more images aren't loaded locally yet."
    "$SH_DIR/load-images.sh"
fi

read -p "Also start daemon? (needs a GPU, or falls back to CPU) [y/N]: " with_daemon
COMPOSE_ARGS=(up -d)
if [[ "$with_daemon" =~ ^[Yy]$ ]]; then
    COMPOSE_ARGS=(--profile daemon up -d)
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
