#!/bin/bash
set -euo pipefail
# make-seed.sh
#
# Writes hydrorisk.sql next to this script: the dump a fresh db container
# restores as its initial database on first start (no hydrorisk_db-data
# volume yet - see docker/container/db/seed-db.sh). Windows: make-seed.bat /
# make-seed.ps1 do the same (keep them in sync).
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

case "$1" in
    --from-local)
        SRC_HOST="${SRC_HOST:-localhost}"
        SRC_PORT="${SRC_PORT:-5432}"
        SRC_USER="${SRC_USER:-postgres}"
        SRC_DB="${SRC_DB:-hydrorisk}"

        if ! command -v pg_dump >/dev/null 2>&1; then
            echo "❌ pg_dump not found - install Postgres client tools (Postgres.app bundles them: add its bin/ to PATH)." >&2
            exit 1
        fi
        if [ -z "${PGPASSWORD:-}" ]; then
            read -s -p "Local Postgres password ('${SRC_USER}'@'${SRC_HOST}:${SRC_PORT}'): " PGPASSWORD
            echo ""
            export PGPASSWORD
        fi

        echo "→ Dumping '$SRC_DB' from $SRC_HOST:$SRC_PORT (user $SRC_USER)..."
        pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Fp \
            --no-owner --no-privileges -f "$TMP_FILE"
        ;;
    --from-stack)
        # Same database name the stack uses (DB_NAME in aio-deploy/.env).
        DB_NAME=$(sed -n 's/^DB_NAME=//p' "$SH_DIR/../aio-deploy/.env" 2>/dev/null | tail -n1 | tr -d "\"'")
        DB_NAME="${DB_NAME:-hydrorisk}"

        if ! docker ps --format '{{.Names}}' | grep -qx hydrorisk-db; then
            echo "❌ hydrorisk-db is not running - start the stack first (aio-deploy/deploy.sh)." >&2
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
