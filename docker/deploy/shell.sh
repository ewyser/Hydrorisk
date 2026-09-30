#!/bin/bash
set -euo pipefail
# shell.sh
#
# Opens an interactive bash shell in one of the stack's containers, for
# testing/debugging. Prompts for the service (db, api, daemon), then:
#   - if its container is running: enter it (docker exec), or start a
#     fresh throwaway copy instead;
#   - otherwise: start a fresh throwaway copy.
#
# "Enter running" = `docker exec` into the live container (e.g. to watch the
#   daemon at work). exec skips the image's entrypoint, so the shell is
#   opened as the service's own unprivileged user explicitly - a root shell
#   in daemon/api would leave root-owned files in that user's Julia depot.
# "Fresh copy" = `docker compose run --rm <service> bash`: same image,
#   environment, network, volumes (and GPU for daemon, when the host has
#   one) as the real service, but running bash instead of the service's
#   program. Removed again on exit; the real container is not touched.
#   Starts db first if a service needs it and it isn't up.
#   Not offered for db: its entrypoint always starts Postgres itself
#   (ignoring the command), and a second Postgres on the same db-data
#   volume as the live one risks corrupting it. db = enter running only.
#
# Usage: ./shell.sh [db|api|daemon]
#
# Windows: shell.bat runs this same script through WSL.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SH_DIR"

SERVICES=("db" "api" "daemon")
# Container name and shell user per service (see docker-compose.yml and each
# service's Dockerfile).
container_of() { echo "hydrorisk-$1"; }
user_of() {
    case "$1" in
        db)     echo "postgres" ;;
        api)    echo "apiuser" ;;
        daemon) echo "mpiuser" ;;
    esac
}
status_of() {
    # Captured first: for a missing container, docker inspect still prints an
    # empty line before failing, which would end up in the menu.
    local s
    s=$(docker inspect -f '{{.State.Status}}' "$(container_of "$1")" 2>/dev/null || true)
    echo "${s:-not created}"
}

# --- pick the service ---------------------------------------------------
SERVICE="${1:-}"
if [ -z "$SERVICE" ]; then
    echo "Which container?"
    for i in "${!SERVICES[@]}"; do
        s="${SERVICES[$i]}"
        printf "  %d) %-7s (%s)\n" $((i + 1)) "$s" "$(status_of "$s")"
    done
    read -r -p "Choice [1-${#SERVICES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SERVICES[@]} )); then
        SERVICE="${SERVICES[$((choice - 1))]}"
    else
        echo "❌ Invalid choice: $choice" >&2
        exit 1
    fi
fi
if [ -z "$(user_of "$SERVICE")" ]; then
    echo "❌ Unknown service '$SERVICE' (expected: ${SERVICES[*]})" >&2
    exit 1
fi

CONTAINER=$(container_of "$SERVICE")
USER_NAME=$(user_of "$SERVICE")

# --- enter running, or fresh copy ----------------------------------------
MODE="fresh"
if [ "$SERVICE" = "db" ]; then
    if [ "$(status_of db)" != "running" ]; then
        echo "❌ $CONTAINER is not running - start the stack first (deploy)." >&2
        exit 1
    fi
    MODE="exec"
elif [ "$(status_of "$SERVICE")" = "running" ]; then
    echo ""
    echo "$CONTAINER is running."
    echo "  1) Enter the running container"
    echo "  2) Start a fresh test copy (the running one is left alone)"
    read -r -p "Choice [1]: " how
    case "${how:-1}" in
        1) MODE="exec" ;;
        2) MODE="fresh" ;;
        *) echo "❌ Invalid choice: $how" >&2; exit 1 ;;
    esac
fi

if [ "$MODE" = "exec" ]; then
    echo "Entering $CONTAINER as $USER_NAME (type 'exit' to leave)..."
    exec docker exec -it -u "$USER_NAME" "$CONTAINER" bash
fi

# A fresh copy goes through docker compose, which needs .env (the database
# password); entering a running container above doesn't.
if [ ! -f .env ]; then
    echo "❌ No .env in $SH_DIR - run deploy once first (it creates it)." >&2
    exit 1
fi

COMPOSE_ARGS=()
RUN_SERVICE="$SERVICE"
if [ "$SERVICE" = "daemon" ]; then
    # Same rule as deploy.sh: the GPU variant (daemon-gpu, see
    # docker-compose.yml) only when the host has a working NVIDIA GPU, or
    # Docker refuses to create the container.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "NVIDIA GPU found - the test container gets GPU access."
        RUN_SERVICE="daemon-gpu"
    else
        echo "No NVIDIA GPU found on this host - the test container runs on CPU."
    fi
    COMPOSE_ARGS+=(--profile "$RUN_SERVICE")
fi

# `compose run` names its container <project>-<service>-run-<id> (it ignores
# container_name), so it never clashes with the running hydrorisk-* ones.
echo "Starting a fresh $SERVICE test container (removed on exit - type 'exit' to leave)..."
exec docker compose ${COMPOSE_ARGS[@]+"${COMPOSE_ARGS[@]}"} run --rm --pull never "$RUN_SERVICE" bash
