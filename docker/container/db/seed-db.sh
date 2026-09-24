#!/bin/bash
set -euo pipefail

# seed-db.sh
#
# Installed as /docker-entrypoint-initdb.d/20_seed_hydrorisk.sh. The base
# postgres image runs initdb.d scripts exactly once: on the very first start
# with an empty data directory (the hydrorisk_db-data volume), against a temporary server
# that only listens on the local Unix socket - so nothing outside the
# container (healthcheck, api, daemon) can connect until this is done.
#
# If a plain-SQL dump is mounted at $SEED_FILE, it becomes the initial
# content of the Hydrorisk database. entrypoint.sh's Datastore.get_db() runs
# only after this, finds the database already there, and skips its own
# empty-schema bootstrap. Without a dump this is a no-op, and Datastore
# bootstraps an empty database exactly as before.
#
# Any plain-SQL (pg_dump -Fp) dump of a Hydrorisk database works, from any
# source Postgres version: lines only a newer pg_dump emits (\restrict/
# \unrestrict, SET transaction_timeout) are stripped here.

SEED_FILE="${SEED_FILE:-/seed/hydrorisk.sql}"
DB="${HYDRORISK_DB_NAME:-hydrorisk}"
PG_USER="${POSTGRES_USER:-postgres}"

if [ ! -f "$SEED_FILE" ]; then
    echo "seed-db: no seed dump at $SEED_FILE - Datastore will create an empty '$DB'."
    exit 0
fi

echo "seed-db: restoring $SEED_FILE into '$DB'..."

# Created here rather than by the dump (pg_dump --create) so the new
# database gets this container's own encoding/locale - a dump taken on
# macOS would otherwise request a locale this Linux image may not have.
createdb -U "$PG_USER" -T template0 -E UTF8 "$DB"

# --single-transaction: a failed restore leaves nothing half-loaded. The
# database is then dropped again so that, when the container restarts
# (init is never re-run once db-data is populated), Datastore bootstraps a
# clean empty one instead of finding an existing-but-schema-less '$DB'.
if ! sed '/^\\restrict/d; /^\\unrestrict/d; /^SET transaction_timeout/d' "$SEED_FILE" \
    | psql -U "$PG_USER" -d "$DB" -v ON_ERROR_STOP=1 --single-transaction --quiet >/dev/null; then
    dropdb -U "$PG_USER" "$DB" || true
    echo "❌ seed-db: restoring $SEED_FILE failed - see the psql error above." >&2
    echo "   Fix the dump, then: docker compose down && docker volume rm hydrorisk_db-data, and start again." >&2
    exit 1
fi

echo "seed-db: '$DB' restored from $SEED_FILE."
