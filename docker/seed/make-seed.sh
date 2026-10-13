#!/bin/bash
set -euo pipefail
# make-seed.sh
#
# Writes hydrorisk.sql next to this script: the dump a fresh db container
# restores as its initial database on first start (no hydrorisk_db-data
# volume yet - see docker/container/db/seed-db.sh). Windows: make-seed.bat
# runs this same script through WSL.
#
# Usage: ./make-seed.sh --from-local | --from-stack
#   --from-local   dump your local Postgres (e.g. Postgres.app). Source is
#                  configurable via env vars: SRC_HOST (localhost), SRC_PORT
#                  (5432), SRC_USER (postgres), SRC_DB (hydrorisk), and
#                  PGPASSWORD (prompted for if unset).
#   --from-stack   dump the running stack's database (hydrorisk-db), e.g. to
#                  move the deployment: run this, copy docker/ to the other
#                  machine, deploy there.
#
# Any plain-SQL dump of a Hydrorisk database can serve as the seed:
#  - Plain SQL (-Fp), not pg_dump's custom format: the custom format embeds a
#    version tag a newer pg_dump (e.g. Postgres.app's) can bump past what the
#    container's Postgres 16 understands. Plain SQL has no such header; the
#    few newer-only lines it may contain are stripped by seed-db.sh.
#  - --no-owner --no-privileges: the container's roles don't necessarily
#    match the source's, so don't try to reproduce ownership/grants.
#  - Written to a temp file and only moved into place once complete, so a
#    failed dump never replaces a good seed with a truncated one.

SH_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SEED_FILE="$SH_DIR/hydrorisk.sql"
TMP_FILE="$SEED_FILE.tmp"

usage() {
    echo "Usage: $0 --from-local | --from-stack" >&2
    exit 1
}
[ $# -eq 1 ] || usage

trap 'rm -f "$TMP_FILE"' EXIT

# True when running inside WSL, i.e. launched from Windows (make-seed.bat).
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# Finds pg_dump. Under WSL, the *Windows* pg_dump.exe comes first: the
# "local Postgres" is then a Windows service, and under WSL 2 "localhost"
# means WSL itself, not Windows - a Windows binary connects from the Windows
# side, where localhost is right. Found on the Windows PATH (which WSL
# appends to its own by default), or else in the newest EnterpriseDB install
# under Program Files (that installer doesn't add itself to PATH).
find_pg_dump() {
    if is_wsl; then
        if command -v pg_dump.exe >/dev/null 2>&1; then
            command -v pg_dump.exe; return
        fi
        local c
        c=$(ls -d /mnt/c/Program\ Files/PostgreSQL/*/bin/pg_dump.exe 2>/dev/null | sort -V | tail -n1)
        if [ -n "$c" ]; then echo "$c"; return; fi
    fi
    command -v pg_dump 2>/dev/null || true
}

case "$1" in
    --from-local)
        SRC_HOST="${SRC_HOST:-localhost}"
        SRC_PORT="${SRC_PORT:-5432}"
        SRC_USER="${SRC_USER:-postgres}"
        SRC_DB="${SRC_DB:-hydrorisk}"

        PG_DUMP=$(find_pg_dump)
        if [ -z "$PG_DUMP" ]; then
            echo "❌ pg_dump not found - install Postgres client tools (Postgres.app bundles them: add its bin/ to PATH; on Windows, add PostgreSQL's bin\\ folder to PATH)." >&2
            exit 1
        fi
        if [ -z "${PGPASSWORD:-}" ]; then
            read -s -p "Local Postgres password ('${SRC_USER}'@'${SRC_HOST}:${SRC_PORT}'): " PGPASSWORD
            echo ""
            export PGPASSWORD
        fi

        OUT_FILE="$TMP_FILE"
        if [[ "$PG_DUMP" == *.exe ]]; then
            # A Windows binary: gets env vars only through WSLENV, and needs
            # a Windows path for its output file.
            export WSLENV="PGPASSWORD${WSLENV:+:$WSLENV}"
            OUT_FILE=$(wslpath -w "$TMP_FILE")
        fi

        echo "→ Dumping '$SRC_DB' from $SRC_HOST:$SRC_PORT (user $SRC_USER)..."
        if ! "$PG_DUMP" -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Fp \
            --no-owner --no-privileges -f "$OUT_FILE"; then
            echo "❌ pg_dump failed - is your local Postgres running?" >&2
            exit 1
        fi
        ;;
    --from-stack)
        # Same database name the stack uses (DB_NAME in deploy/.env).
        # (\r stripped too: a .env edited in Windows Notepad has CRLF endings.)
        DB_NAME=$(sed -n 's/^DB_NAME=//p' "$SH_DIR/../deploy/.env" 2>/dev/null | tail -n1 | tr -d "\"'\r")
        DB_NAME="${DB_NAME:-hydrorisk}"

        if ! docker ps --format '{{.Names}}' | grep -qx hydrorisk-db; then
            echo "❌ hydrorisk-db is not running - start the stack first (deploy/deploy.sh, or deploy.bat)." >&2
            exit 1
        fi

        # pg_dump runs inside the db container: its version always matches
        # the server, and nothing needs installing on the host.
        echo "→ Dumping '$DB_NAME' from the running hydrorisk-db..."
        docker exec hydrorisk-db pg_dump -U postgres -d "$DB_NAME" -Fp \
            --no-owner --no-privileges > "$TMP_FILE"
        ;;
    *)
        usage
        ;;
esac

mv "$TMP_FILE" "$SEED_FILE"
echo "✅ Seed written: docker/seed/hydrorisk.sql ($(du -h "$SEED_FILE" | awk '{print $1}'))."
