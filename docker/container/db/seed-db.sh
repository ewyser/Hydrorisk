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

#
# SEED_REQUIRED=1 (set by docker/deploy/docker-compose.yml): a missing,
# unreadable or empty dump - or a failed restore - is fatal instead of
# silently leaving Datastore to bootstrap an empty '$DB'. Typical cause: the
# host folder behind the /seed bind mount isn't visible to Docker (e.g. an
# external drive plugged in after Docker Desktop started), which Docker
# answers with an empty directory rather than an error. A marker file in
# PGDATA makes entrypoint.sh refuse every later start too, since init is
# never re-run once PGDATA is populated.

SEED_FILE="${SEED_FILE:-/seed/hydrorisk.sql}"
DB="${HYDRORISK_DB_NAME:-hydrorisk}"
PG_USER="${POSTGRES_USER:-postgres}"
SEED_REQUIRED="${SEED_REQUIRED:-0}"
FAILED_MARKER="${PGDATA:-/var/lib/postgresql/data}/.hydrorisk-seed-failed"

seed_failed() {
    echo "❌ seed-db: $1" >&2
    echo "   Fix it, then: docker compose down && docker volume rm hydrorisk_db-data, and start again." >&2
    if [ "$SEED_REQUIRED" = "1" ]; then
        echo "$1" > "$FAILED_MARKER"
    fi
    exit 1
}

if [ ! -s "$SEED_FILE" ] || [ ! -r "$SEED_FILE" ]; then
    if [ "$SEED_REQUIRED" = "1" ]; then
        seed_failed "no readable, non-empty seed dump at $SEED_FILE (contents of $(dirname "$SEED_FILE"): $(ls -A "$(dirname "$SEED_FILE")" 2>/dev/null | tr '\n' ' ')) - is the host folder visible to Docker?"
    fi
    echo "seed-db: no seed dump at $SEED_FILE - Datastore will create an empty '$DB'."
    exit 0
fi

echo "seed-db: restoring $SEED_FILE ($(stat -c %s "$SEED_FILE") bytes) into '$DB'..."

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
    seed_failed "restoring $SEED_FILE failed - see the psql error above."
fi

echo "seed-db: '$DB' restored from $SEED_FILE."
