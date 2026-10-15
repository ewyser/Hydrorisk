# Deployment

The platform runs as three Docker containers on one machine, from images
built on a development machine and shipped as tarballs. Everything lives in
`docker/`.

```
docker/
├── container/        one folder per image: Dockerfile, build.sh, entrypoint.sh
│   ├── db/           PostgreSQL + PostGIS, with Datastore to create the schema
│   ├── api/          Gateway (and the plugin)
│   ├── daemon/       Daemon + OsmotiC + cORIUm (CPU, or GPU with CUDA)
│   └── build-all.sh  builds several images in one go
├── deploy/           docker-compose.yml, deploy.sh, .env, images/ (the tarballs)
├── seed/             make-seed.sh, and hydrorisk.sql: the initial database
└── volume/           what the containers write for the host
    ├── api-data/     hydrorisk_plugin.zip
    └── daemon-data/  job folders and logs
```

## The services

| Service | Image | Port on the host | Writes to |
|:--|:--|:--|:--|
| `db` | `hydrorisk-db` | `DB_HOST_PORT` (5433), this machine only | the `db-data` Docker volume |
| `api` | `hydrorisk-api` | `API_HOST_PORT` (8001), the local network | `volume/api-data` |
| `daemon` / `daemon-gpu` | `hydrorisk-daemon` | — | `volume/daemon-data` |

The api and the daemon wait until the database is healthy. The daemon is
started with a Compose profile: `daemon` (CPU) or `daemon-gpu` (NVIDIA GPU,
when `nvidia-smi` works).

## 1. Build the images

On a machine with the sibling packages checked out next to `Hydrorisk/`
(see [Development](@ref)):

```sh
docker/container/build-all.sh              # db, api, daemon
docker/container/build-all.sh api          # one or several
```

Each image is built from **local copies** of the packages — staged by its
`prep-context.sh`, keeping their side-by-side layout so the relative paths in
the Manifests resolve — never from git clones. The tarballs land in
`docker/deploy/images/`. The daemon image is the long one (CUDA, MPI, HDF5,
the whole simulation stack).

## 2. Create the seed (first deployment only)

A fresh database starts from a dump — users, tokens, datasets — restored on
its very first start:

```sh
docker/seed/make-seed.sh --from-local   # from a local Postgres
docker/seed/make-seed.sh --from-stack   # from a running deployment (to move it)
```

`deploy.sh` refuses to create a new database without it: an empty one would
have no users, and every client would get `401`.

## 3. Deploy

```sh
docker/deploy/deploy.sh            # loads new image tarballs, starts the stack
docker/deploy/deploy.sh --reload   # reloads every tarball
```

`deploy.sh` creates `.env` on the first run (asking for the database
password, see [Configuration](@ref)), loads the images whose tarball changed,
starts `db` and `api` — and the daemon, on CPU or GPU — and waits until the
API answers. It ends by printing the API's address on the local network: the
URL users enter in the QGIS plugin. On Windows, `deploy.bat` runs the same
script through WSL.

After a code change: rebuild the affected images, then `deploy.sh`. Images
are rebuilt together when a change spans them — renaming a database variable,
for instance, touches all three.

## Day to day

| Task | How |
|:--|:--|
| Install the plugin | `docker/volume/api-data/hydrorisk_plugin.zip` → QGIS, *Install from ZIP* ([details](hydrorisk://gateway/qgis_plugin/)) |
| Add a user, issue a token | Datastore's console in the db container ([details](hydrorisk://datastore/admin/)) |
| Watch the jobs | the daemon's status display: `docker logs -f hydrorisk-daemon` ([details](hydrorisk://daemon/operations/)) |
| Logs | `docker logs hydrorisk-api`, `docker logs hydrorisk-daemon`; a job's log in `volume/daemon-data` |
| A shell in a container | `docker/deploy/shell.sh` |
| Move the deployment | `make-seed.sh --from-stack`, copy `docker/`, deploy on the new machine |
| Stop | `docker compose stop` in `docker/deploy/` |
