#!/bin/bash
set -euo pipefail
# deploy.sh
#
# One-command entry point for the whole stack: makes sure .env exists,
# checks that the first-start seed (docker/seed/hydrorisk.sql) exists when
# the database volume doesn't exist yet, loads each image tarball from
# ./images/ whose image isn't already in the local Docker daemon, brings db+api up (and
# daemon, if asked for), then waits for db to be healthy and api to actually
# accept connections before returning.
#
# Usage: ./deploy.sh [--reload]
#   --reload   always (re)load every ./images/*.tar, even if the loaded
#              images already match them. Without it, only tarballs whose
#              image differs from (or is missing in) the local Docker daemon
#              are loaded - freshly built tarballs are picked up on their own.
#
# Deploying never creates the seed - that's a separate, earlier step:
# docker/seed/make-seed.sh --from-local | --from-stack.
#
# Windows: deploy.bat runs this same script through WSL - there is no
# separate Windows version to keep in sync. Windows-only checks below are
# guarded by is_wsl.
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

# Prints the image IDs a tarball's image can have once loaded (without the
# sha256: prefix): the index digest (containerd image store, e.g. Docker
# Desktop's default) and the config digest (classic image store). Read from
# the tarball's small index.json/manifest.json - tar seeks past the layers,
# so this is instant even for multi-GB tarballs.
tar_image_ids() {
    { tar -xOf "$1" index.json 2>/dev/null | grep -o '"digest":"sha256:[0-9a-f]*"' | head -n1
      tar -xOf "$1" manifest.json 2>/dev/null | grep -o '"Config":"[^"]*"'
    } | grep -o '[0-9a-f]\{64\}' || true
}

# Prints the tag a tarball's image is loaded as (e.g. hydrorisk-db:latest).
tar_image_tag() {
    tar -xOf "$1" manifest.json 2>/dev/null \
        | grep -o '"RepoTags":\["[^"]*"' | head -n1 | sed 's/.*\["//; s/"$//' || true
}

# Loads each image tarball in ./images/ into the local Docker daemon, so
# docker-compose.yml's `image:` references (hydrorisk-db:latest,
# hydrorisk-api:latest, hydrorisk-daemon:runtime) resolve without a
# `build:` step - but only the ones whose image isn't already loaded
# (unless --reload). An image a load replaces is remembered in
# REPLACED_IMAGES and removed once the stack runs on the new one.
REPLACED_IMAGES=()
sync_images() {
    local images_dir="$SH_DIR/images"
    local tars tar tag current ids
    shopt -s nullglob
    tars=("$images_dir"/*.tar)
    shopt -u nullglob

    if [ ${#tars[@]} -eq 0 ]; then
        echo "❌ No .tar files found in $images_dir - build the images first (docker/container/{db,api,daemon} each have their own docker-build.sh)." >&2
        exit 1
    fi

    for tar in "${tars[@]}"; do
        tag=$(tar_image_tag "$tar")
        current=""
        if [ -n "$tag" ]; then
            current=$(docker image inspect --format '{{.Id}}' "$tag" 2>/dev/null || true)
        fi
        if [ "$RELOAD" -eq 0 ] && [ -n "$current" ]; then
            ids=$(tar_image_ids "$tar")
            if grep -qx "${current#sha256:}" <<< "$ids"; then
                echo "$tag is up to date."
                continue
            fi
            echo "$tag differs from $(basename "$tar") - replacing it."
        fi
        echo "Loading $(basename "$tar")..."
        docker load -i "$tar"
        if [ -n "$current" ]; then
            REPLACED_IMAGES+=("$current")
        fi
    done

    for img in hydrorisk-db:latest hydrorisk-api:latest hydrorisk-daemon:runtime; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            echo "❌ $img is neither loaded nor in any images/*.tar - build it first (docker/container/*/docker-build.sh)." >&2
            exit 1
        fi
    done
}

# Runs $2 (a sh command line) in a throwaway container with host folder $1
# bind-mounted at /probe, exactly like docker-compose.yml's own bind mounts.
# A host folder Docker can't actually see doesn't make the mount fail - it
# shows up empty - so this is the only reliable check. hydrorisk-db's image
# is used just for its sh; its entrypoint is bypassed.
test_docker_mount() {
    docker run --rm --mount "type=bind,source=$1,target=/probe" \
        --entrypoint sh hydrorisk-db:latest -c "$2" >/dev/null 2>&1
}

docker_mount_hint() {
    echo "   Docker cannot see this folder. If it is on an external drive: plug it in," >&2
    if is_wsl; then
        echo "   restart Docker Desktop (or run \"wsl --shutdown\" in a Windows terminal), then" >&2
        echo "   run this again - or copy the Hydrorisk folder to a local disk (e.g. C:\\)." >&2
    else
        echo "   check that it's shared with Docker (Docker Desktop > Settings > Resources >" >&2
        echo "   File sharing), or copy the Hydrorisk folder to a local disk and deploy from there." >&2
    fi
}

# True when running inside WSL, i.e. launched from Windows (deploy.bat).
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# True if $1 is a Dropbox/OneDrive "online-only" placeholder on the Windows
# side: it exists and has a size, but its content is only downloaded when
# Windows itself opens it - not when Docker reads it through a bind mount.
# OFFLINE (0x1000) | RECALL_ON_DATA_ACCESS (0x400000). WSL only; asks
# Windows for the attributes, which Linux can't see.
is_cloud_placeholder() {
    is_wsl && command -v powershell.exe >/dev/null 2>&1 || return 1
    local attrs
    attrs=$(powershell.exe -NoProfile -Command \
        "[int](Get-Item -LiteralPath '$(wslpath -w "$1")' -Force).Attributes" 2>/dev/null | tr -d '\r')
    [[ "$attrs" =~ ^[0-9]+$ ]] && (( attrs & (0x1000 | 0x400000) ))
}

# Prints db's seed-db lines, i.e. whether the first-start seed was restored
# and if not, why.
show_seed_log() {
    local lines
    lines=$(docker logs hydrorisk-db 2>&1 | grep 'seed-db' || true)
    if [ -n "$lines" ]; then
        echo "Seed (docker compose logs db):"
        echo "$lines" | sed 's/^/    /'
    fi
}

DB_VOLUME="hydrorisk_db-data"   # compose project "hydrorisk" + volume "db-data"
SEED_DIR="$(cd "$SH_DIR/../seed" && pwd)"
SEED_FILE="$SEED_DIR/hydrorisk.sql"
DAEMON_DIR="$SH_DIR/../volume/daemon-data"

# First start (no db-data volume yet): the db container restores the seed as
# the initial database (docker/container/db/seed-db.sh). Without one, the
# database would start empty - no users, every client gets 401 - so refuse
# to start at all: first thing, before asking for anything (password) or
# the (slow) image loading below. Once the volume exists the seed is never
# read again, so it isn't needed then.
FIRST_START=0
if ! docker volume inspect "$DB_VOLUME" >/dev/null 2>&1; then
    FIRST_START=1
    if [ ! -f "$SEED_FILE" ]; then
        echo "❌ First start (no $DB_VOLUME volume yet), but no seed at docker/seed/hydrorisk.sql." >&2
        echo "   Create it first: docker/seed/make-seed.sh --from-local  (Windows: make-seed.bat --from-local)," >&2
        echo "   or --from-stack on the machine the stack runs on now." >&2
        exit 1
    fi
    if is_cloud_placeholder "$SEED_FILE"; then
        echo "❌ docker/seed/hydrorisk.sql is an online-only cloud placeholder - make it \"available offline\" (Dropbox/OneDrive), then re-run." >&2
        exit 1
    fi
    if [ ! -s "$SEED_FILE" ]; then
        echo "❌ docker/seed/hydrorisk.sql is empty - copy it again (or recreate it with docker/seed/make-seed.sh)." >&2
        exit 1
    fi
    echo "First start - the database will be seeded from docker/seed/hydrorisk.sql ($(du -h "$SEED_FILE" | awk '{print $1}'), $(date -r "$SEED_FILE" '+%Y-%m-%d %H:%M'))."
fi

# --- .env and the database password --------------------------------------
# POSTGRES_PASSWORD (.env) is the password of the database's `postgres`
# superuser: api/daemon log in with it, and so do external clients (QGIS,
# pgAdmin, ...) on localhost:$DB_HOST_PORT. Postgres only takes it from .env
# ONCE, when the db-data volume is created - afterwards the database keeps
# its own copy, and .env must keep matching it. It always comes from the
# user (never generated): clients are set up with a known one.

# Prints KEY's value from .env (\r and surrounding quotes stripped).
get_env_var() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" .env 2>/dev/null | tail -n1 | tr -d '\r' \
        | sed -E "s/^'(.*)'\$/\1/; s/^\"(.*)\"\$/\1/"
}

# Sets KEY=VALUE in .env: replaces KEY's line (or appends it), keeps every
# other line, writes LF endings. VALUE goes in as-is - quote it yourself.
# Via ENVIRON, not awk -v, which would mangle backslashes in VALUE.
set_env_var() {
    local tmp
    tmp=$(mktemp)
    tr -d '\r' < .env | K="$1" V="$2" awk '
        $0 ~ "^[[:space:]]*" ENVIRON["K"] "[[:space:]]*=" { if (!done) print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' > "$tmp"
    cat "$tmp" > .env
    rm -f "$tmp"
}

# Writes a fresh .env from .env.example with password $1. Single-quoted:
# literal for both docker compose and bash (no $-expansion, # kept) - which
# is why a password may not contain a single quote itself.
write_env() {
    tr -d '\r' < .env.example > .env
    set_env_var POSTGRES_PASSWORD "'$1'"
    chmod 600 .env 2>/dev/null || true
}

backup_note() {
    echo "🔑 The database password is in docker/deploy/.env (POSTGRES_PASSWORD) - keep a backup of that file with this deployment."
}

# Asks for the password (hidden, twice) and prints it on stdout.
prompt_password() {
    local p1 p2
    if [ ! -t 0 ]; then
        echo "❌ No terminal to ask for the database password on - create docker/deploy/.env with POSTGRES_PASSWORD set (see .env.example)." >&2
        exit 1
    fi
    while true; do
        read -r -s -p "Database password (the one your clients - QGIS, pgAdmin, ... - will use): " p1; echo "" >&2
        if [ -z "$p1" ] || [ "$p1" = "changeme" ]; then
            echo "   Please choose a real password (not empty, not 'changeme')." >&2; continue
        fi
        if [[ "$p1" == *"'"* ]]; then
            echo "   The password can't contain a single quote (')." >&2; continue
        fi
        read -r -s -p "Type it again: " p2; echo "" >&2
        [ "$p1" = "$p2" ] && break
        echo "   The two entries differ - try again." >&2
    done
    printf '%s' "$p1"
}

if [ ! -f .env ]; then
    if ! docker volume inspect "$DB_VOLUME" >/dev/null 2>&1; then
        # First deploy: the database will be created with this password.
        echo "No .env yet - first deploy, setting the database password."
        NEW_PW=$(prompt_password)   # own assignment, so set -e stops on failure
        write_env "$NEW_PW"
        unset NEW_PW
        echo "✅ .env created."
        backup_note
    else
        # The database already exists with a password .env no longer has.
        # The db container (if still there) was created with it - recover.
        RECOVERED=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' hydrorisk-db 2>/dev/null \
            | sed -n 's/^POSTGRES_PASSWORD=//p' | head -n1 || true)
        if [ -z "$RECOVERED" ] || [[ "$RECOVERED" == *"'"* ]]; then
            echo "❌ No .env, but the database ($DB_VOLUME) already exists - and its password can't be recovered." >&2
            echo "   Restore the old docker/deploy/.env, or create one from .env.example with the password" >&2
            echo "   the database was set up with. Or start over from the seed:" >&2
            echo "   docker compose --profile daemon --profile daemon-gpu down && docker volume rm $DB_VOLUME, then deploy again." >&2
            exit 1
        fi
        write_env "$RECOVERED"
        unset RECOVERED
        echo "✅ .env was missing - recreated it with the database password recovered from the hydrorisk-db container."
        backup_note
    fi
fi

# docker compose loads .env on its own; sourced here too so this script's
# own checks and status lines reflect the same values instead of falling
# back to their hardcoded defaults. \r stripped: a .env edited in Windows
# Notepad has CRLF line endings, which would leave e.g. DB_NAME as
# "hydrorisk\r" - the user-count check below would then fail and wrongly
# offer to delete the database volume.
set -a
source <(tr -d '\r' < .env)
set +a

if [ -z "${POSTGRES_PASSWORD:-}" ] || [ "$POSTGRES_PASSWORD" = "changeme" ]; then
    if ! docker volume inspect "$DB_VOLUME" >/dev/null 2>&1; then
        # Still a first deploy (e.g. .env copied from .env.example): the
        # database gets created with this password, so ask for a real one.
        echo "docker/deploy/.env has no real database password yet - first deploy, setting it."
        NEW_PW=$(prompt_password)
        set_env_var POSTGRES_PASSWORD "'$NEW_PW'"
        POSTGRES_PASSWORD="$NEW_PW"
        unset NEW_PW
        echo "✅ Password saved in .env."
        backup_note
    elif [ -z "${POSTGRES_PASSWORD:-}" ]; then
        echo "❌ POSTGRES_PASSWORD is empty in docker/deploy/.env - set it to the database password." >&2
        exit 1
    fi
fi
if [ "$POSTGRES_PASSWORD" = "changeme" ]; then
    echo "⚠️  The database password is still the default 'changeme' - and the database is reachable on"
    echo "   localhost:${DB_HOST_PORT:-5433}. To change it: put the new password in docker/deploy/.env, then deploy"
    echo "   again - it offers to apply it to the database."
fi

echo "── Images ──"
sync_images

# The seed existing on this machine isn't enough - the db container must
# see it through the ../seed bind mount too, or it starts without it.
if [ "$FIRST_START" -eq 1 ] && ! test_docker_mount "$SEED_DIR" "test -s /probe/hydrorisk.sql"; then
    echo "❌ docker/seed/hydrorisk.sql exists, but a container mounting $SEED_DIR doesn't see it." >&2
    docker_mount_hint
    exit 1
fi

echo ""
read -p "Also start daemon? (needs a GPU, or falls back to CPU) [y/N]: " with_daemon

# daemon's output goes to ../volume/daemon-data (bind mount) - check that
# what the container writes there actually lands in this folder.
mkdir -p "$DAEMON_DIR"
DAEMON_DIR="$(cd "$DAEMON_DIR" && pwd)"
if [[ "$with_daemon" =~ ^[Yy]$ ]]; then
    rm -f "$DAEMON_DIR/.docker-probe"
    test_docker_mount "$DAEMON_DIR" "touch /probe/.docker-probe" || true
    if [ ! -f "$DAEMON_DIR/.docker-probe" ]; then
        echo "❌ A container mounting $DAEMON_DIR can't write into it - daemon output wouldn't reach volume/." >&2
        docker_mount_hint
        exit 1
    fi
    rm -f "$DAEMON_DIR/.docker-probe"
fi
# --pull never: these images only ever come from images/*.tar, never a
# registry - a missing image should fail as such, not as a confusing
# "pull access denied".
# --wait: return only once db and api are healthy (daemon: running) - api's
# healthcheck (docker-compose.yml) passes once it really answers HTTP, so
# compose shows it as "Waiting" until then instead of an early "Started".
COMPOSE_ARGS=(up -d --pull never --wait --wait-timeout 900)
if [[ "$with_daemon" =~ ^[Yy]$ ]]; then
    COMPOSE_ARGS=(--profile daemon "${COMPOSE_ARGS[@]}")
    # Give daemon the GPU (docker-compose.gpu.yml) only when the host has a
    # working NVIDIA one - requesting it on a host without makes Docker
    # refuse to create the container.
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        echo "NVIDIA GPU found - daemon gets GPU access (docker-compose.gpu.yml)."
        COMPOSE_ARGS=(-f docker-compose.yml -f docker-compose.gpu.yml "${COMPOSE_ARGS[@]}")
    else
        echo "No NVIDIA GPU found on this host - daemon runs on CPU."
    fi
fi

echo ""
echo "── Starting containers ──"
if ! docker compose "${COMPOSE_ARGS[@]}"; then
    show_seed_log
    API_STATE=$(docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' hydrorisk-api 2>/dev/null || echo "not created")
    echo "❌ The stack did not become healthy (api: $API_STATE). Last api log lines:" >&2
    docker logs --tail 20 hydrorisk-api 2>&1 | sed 's/^/    /' >&2
    echo "   More: docker compose logs api  (and: docker compose logs db)" >&2
    exit 1
fi

API_PORT="${API_HOST_PORT:-8001}"
echo "✅ Stack is up. API: http://localhost:${API_PORT}/  ·  DB: localhost:${DB_HOST_PORT:-5433}"
docker compose ps

# Images replaced by sync_images above: the recreated containers now run on
# the new ones, so the old ones are just disk space. One still used by a
# container (e.g. a daemon not started this time) stays - rm refuses it.
if [ ${#REPLACED_IMAGES[@]} -gt 0 ]; then
    for id in "${REPLACED_IMAGES[@]}"; do
        docker image rm "$id" >/dev/null 2>&1 && echo "Removed replaced image ${id:7:12}." || true
    done
fi

if [ "$FIRST_START" -eq 1 ]; then
    echo ""
    show_seed_log
fi

# Started without a seed (or on an old volume that never got data), the
# database only has Datastore.jl's empty schemas - no users, so every client
# request is answered 401. A failed query (e.g. core.users missing) is just
# as bad. Say so, and offer the way out: once the db-data volume exists the
# seed is never read again, so reseeding means removing it.
DB_NAME_EFFECTIVE="${DB_NAME:-hydrorisk}"
USER_COUNT=$(docker exec hydrorisk-db psql -U postgres -d "$DB_NAME_EFFECTIVE" -Atc \
    "select count(*) from core.users" 2>/dev/null || echo "?")
if [ "$USER_COUNT" = "0" ] || [ "$USER_COUNT" = "?" ]; then
    echo ""
    if [ "$USER_COUNT" = "?" ]; then
        echo "⚠️  Could not read users from database '$DB_NAME_EFFECTIVE' - clients will likely get 401 Unauthorized."
    else
        echo "⚠️  Database '$DB_NAME_EFFECTIVE' has no users - clients will get 401 Unauthorized."
    fi
    if [ "$FIRST_START" -eq 0 ]; then
        echo "   The $DB_VOLUME volume already existed, so docker/seed/hydrorisk.sql was not read."
    fi
    show_seed_log
    if [ -s "$SEED_FILE" ]; then
        read -p "Delete the database volume ($DB_VOLUME) now, to reseed from docker/seed/hydrorisk.sql on the next run? [y/N]: " reset
        if [[ "$reset" =~ ^[Yy]$ ]]; then
            docker compose --profile daemon down
            docker volume rm "$DB_VOLUME"
            echo "✅ $DB_VOLUME removed - re-run ./deploy.sh to start with the seed."
            exit 0
        fi
    fi
    echo "   To reseed: docker compose down && docker volume rm $DB_VOLUME, then re-run ./deploy.sh"
fi

# daemon's entrypoint warns (and keeps output inside the container) when the
# volume/ mount isn't writable for its user - surface that here.
if [[ "$with_daemon" =~ ^[Yy]$ ]] && docker logs hydrorisk-daemon 2>&1 | grep -q "not writable by mpiuser"; then
    echo ""
    echo "⚠️  daemon can't write to $DAEMON_DIR - its output stays inside the container. See: docker compose logs daemon"
fi
