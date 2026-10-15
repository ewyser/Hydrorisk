# Configuration

Every setting of the platform, in one place. The packages' pages repeat the
ones they read.

## The database connection

Read by Datastore — so by Gateway, the daemon (and its workers) and OsmotiC —
from six environment variables:

| Variable | Meaning | Docker deployment | Local example |
|:--|:--|:--|:--|
| `HYDRORISK_DB_HOST` | PostgreSQL host | `db` (the container) | `localhost` |
| `HYDRORISK_DB_PORT` | PostgreSQL port | `5432` | `5432` |
| `HYDRORISK_DB_USER` | user | `DB_USER` | `postgres` |
| `HYDRORISK_DB_NAME` | database | `DB_NAME` | `hydrorisk` |
| `HYDRORISK_DB_PASSWORD` | password | `POSTGRES_PASSWORD` | `****` |
| `HYDRORISK_API` | `true` for Gateway, `false` otherwise | set per service | |

Set all six, or none: some but not all is an error. Instead of the variables,
a folder holding a `db-config.toml` can be given (in a REPL, Datastore asks
for it when no variable is set):

```toml
[database]
password = "****"
host     = "localhost"
port     = 5432
user     = "postgres"
name     = "hydrorisk"

[server]
api = false
```

Its values fill in the variables not already set — the environment wins. A
script, a worker or a container without the variables would wait at that
prompt: set the variables there.

## Other settings

| Variable | Read by | Meaning | Default |
|:--|:--|:--|:--|
| `VOLUME_MOUNT` | Gateway, Daemon, OsmotiC | writable folder for output reachable from the host: the plugin zip (Gateway), job folders and logs (daemon) | the package's own folder |
| `HYDRORISK_MAX_UPLOAD_MB` | Gateway | largest upload | `2048` |
| `HYDRORISK_MAX_ZIP_ENTRIES` | Gateway | most entries in an uploaded archive | `10000` |
| `HYDRORISK_ENV` | the containers' entrypoints | folder holding a `db-config.toml`, when the variables are not set | `/config` |

## The deployment's `.env`

`docker/deploy/.env` (gitignored; `deploy.sh` creates it from `.env.example`
and asks for the password):

| Key | Meaning | Default |
|:--|:--|:--|
| `POSTGRES_PASSWORD` | password of the database's `postgres` user — the one Gateway and the daemon log in with, passed to them as `HYDRORISK_DB_PASSWORD` | asked by `deploy.sh` |
| `DB_USER`, `DB_NAME` | database user and name | `postgres`, `hydrorisk` |
| `DB_HOST_PORT` | the database's port on the host (local connections only) | `5433` |
| `API_HOST_PORT` | Gateway's port on the host, open to the local network | `8001` |

Postgres takes `POSTGRES_PASSWORD` only when the database is first created;
to change it later, edit it here and deploy again — `deploy.sh` offers to
apply it to the database.

## Users and tokens

Users are not configuration: an administrator creates them, and issues their
tokens, with Datastore's console — see
[Datastore: administration](hydrorisk://datastore/admin/).
