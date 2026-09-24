#!/bin/bash
set -euo pipefail

# import-local-db-data.sh
#
# Dumps a database from your local Postgres (e.g. Postgres.app) and restores
# it into the running `hydrorisk-db` container - without needing the two
# Postgres instances to share a port or a data directory. The dump is piped
# straight through `docker exec -i`, so it never touches the host filesystem
# and never needs the container's 5432 to be free on the host.
#
# Usage:
#   ./import-local-db-data.sh [container] [target_db]
#
# Configure the SOURCE (your local Postgres.app) via env vars:
#   SRC_HOST (default: localhost)
#   SRC_PORT (default: 5432)
#   SRC_USER (default: postgres)
#   SRC_DB   (default: hydrorisk)
#   PGPASSWORD - set if your local Postgres needs a password (pg_dump reads it)
#
# Configure the TARGET (inside the container) via env vars:
#   TARGET_USER (default: postgres)
#
# Example:
#   SRC_DB=hydrorisk ./import-local-db-data.sh hydrorisk-db hydrorisk

CONTAINER="${1:-hydrorisk-db}"
TARGET_DB="${2:-hydrorisk}"

SRC_HOST="${SRC_HOST:-localhost}"
SRC_PORT="${SRC_PORT:-5432}"
SRC_USER="${SRC_USER:-postgres}"
SRC_DB="${SRC_DB:-hydrorisk}"
TARGET_USER="${TARGET_USER:-postgres}"

if ! command -v pg_dump >/dev/null 2>&1; then
    echo "❌ pg_dump not found on this machine. Install Postgres client tools" >&2
    echo "   (Postgres.app already bundles them - add its bin/ dir to PATH)." >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "❌ container '$CONTAINER' is not running. Start it first." >&2
    exit 1
fi

# Prompted explicitly and labeled here, rather than left to pg_dump's own
# bare "Password:" prompt, so it isn't mistaken for the container's own
# postgres password prompted by docker-run.sh earlier in the same flow.
# Skipped if the caller already set PGPASSWORD (e.g. non-interactive use per
# this script's usage comment above).
if [ -z "${PGPASSWORD:-}" ]; then
    read -s -p "Source Postgres password (local '${SRC_USER}'@'${SRC_HOST}:${SRC_PORT}'): " PGPASSWORD
    echo ""
    export PGPASSWORD
fi
# No corresponding target-side password prompt: the container's psql
# connection below goes over `docker exec`'s local Unix socket, which the
# base postgis/postgis image trusts unconditionally - only TCP connections
# to the container require a password.

echo "→ Dumping '$SRC_DB' from $SRC_HOST:$SRC_PORT (user $SRC_USER)..."
echo "→ Restoring into '$TARGET_DB' inside container '$CONTAINER' (user $TARGET_USER)..."

# Plain SQL format (-Fp), piped straight into psql, not pg_dump's custom
# format piped into pg_restore: the custom format embeds a version tag that
# a newer pg_dump (e.g. Postgres.app's own, ahead of the container's fixed
# Postgres 16) can bump past what an older pg_restore understands
# ("unsupported version in file header"), even though the actual SQL is
# perfectly portable. Plain SQL has no such header, so it isn't affected by
# that version skew.
# --clean --if-exists: drop existing objects before recreating them, so this
# is safe to re-run even if Datastore.jl's own db_create() already
# initialized empty core/processing/metadata/data schemas in the target.
# --no-owner --no-privileges: the container's roles don't necessarily match
# your local Postgres.app roles, so skip trying to reproduce ownership/grants.
# `sed` strips lines only a newer source pg_dump (e.g. Postgres.app running
# a later major Postgres than the container's fixed Postgres 16) adds, which
# an older target doesn't understand:
#  - \restrict/\unrestrict: a psql-18+ dump-integrity meta-command.
#  - `SET transaction_timeout = ...`: a session GUC introduced in Postgres 17.
# Both are harmless to drop - dump-format/session bookkeeping, not part of
# the actual schema/data being restored.
pg_dump -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_DB" -Fp \
    --clean --if-exists --no-owner --no-privileges \
    | sed '/^\\restrict/d; /^\\unrestrict/d; /^SET transaction_timeout/d' \
    | docker exec -i "$CONTAINER" psql -U "$TARGET_USER" -d "$TARGET_DB" -v ON_ERROR_STOP=1

echo "✅ Import complete."
