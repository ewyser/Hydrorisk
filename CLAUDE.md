# Hydrorisk

Builds Docker images for three services:

1. **compute-engine** — cORIUm.jl + OsmotiC.jl
2. **db** — Datastore.jl
3. **api** — Hydrorisk.jl

All source packages live side-by-side in the parent directory (`git/cORIUm.jl`,
`git/OsmotiC.jl`, `git/Datastore.jl`, ...). Docker builds consume **local copies**
of these, not git clones.

---

## Plan: compute-engine Docker image from local package copies

### Context

Today only `docker/Dockerfile` exists and it builds **cORIUm.jl only**, fetching
it with a `git clone --branch dev` inside a cache-busted `source` stage that
needs a GitHub token build secret.

Cloning is redundant and forces private-repo auth. This change reworks the
Dockerfile to build the full **compute-engine** image (cORIUm + OsmotiC, with
OsmotiC's path-dependency Datastore) from local copies instead, removing the
clone, the `CACHEBUST` machinery and the GitHub token secret.

Key facts:
- `OsmotiC.jl/Manifest.toml` pins its deps by **relative path**:
  `path = "../cORIUm.jl"` and `path = "../Datastore.jl"`. The sibling layout
  must be preserved in the build context for `Pkg.instantiate()` to resolve
  offline.
- Source trees are huge and mostly irrelevant to a build (`cORIUm.jl/.git` ~6G,
  `OsmotiC.jl/.git` ~1G, plus `dump/ job/ docs/ logs/ test/`). A naive `COPY` of
  the whole trees is not viable — a prep script stages only the needed subset.
- cORIUm still needs `Pkg.add("CUDA")` on top of its committed Manifest, bounded
  by its `[compat]` (`CUDA = "~5.5"`). That logic stays.
- No Manifest references a private `https://github.com/...` git dependency (only
  registered packages + the two local path-deps), so the token can be dropped.

### Approach

#### 1. New file: `docker/prep-context.sh`

Stages a minimal, layout-preserving copy of the three packages into
`docker/context/packages/` so `docker build` (context = `docker/`) can `COPY`
them.

- Resolve `GIT_ROOT` = parent of the Hydrorisk repo (`$SH_DIR/../..`).
- For each of `cORIUm.jl`, `OsmotiC.jl`, `Datastore.jl`: `rsync -a --delete`
  with an explicit include/exclude set into `docker/context/packages/<pkg>/`:
  - include: `Project.toml`, `Manifest.toml`, `src/`, `ext/` (cORIUm only),
    `LICENSE`, `README.md`
  - exclude: `.git/`, `dump/`, `job/`, `logs/`, `docs/`, `test/`,
    `reproduction/`, `LocalPreferences.toml`, `*.code-workspace`
- Fail loudly if any source dir is missing.
- Keep `docker/context/` out of git via `docker/.gitignore`.

#### 2. `docker/Dockerfile` rework

Remove:
- STAGE 1a `source` (the `git clone`, `git config url.insteadOf`,
  `--mount=type=secret,id=github_token`, `ARG CACHEBUST`).
- The `builder` stage's re-`COPY --from=source` / manifest re-overlay dance.

`toolchain` stage: keep OpenMPI/HDF5/Julia install as-is. Replace the
cORIUm-specific env block with:
```
ENV PKGROOT=/home/packages
ENV CORIUM=${PKGROOT}/cORIUm.jl
ENV OSMOTIC=${PKGROOT}/OsmotiC.jl
ENV JULIA_PKG_PRECOMPILE_AUTO=no
```

`deps` stage (`FROM toolchain AS deps`):
```
COPY context/packages/ ${PKGROOT}/
RUN julia --project=${CORIUM} -e 'using Pkg; Pkg.instantiate(); Pkg.add("CUDA")'
RUN julia --project=${OSMOTIC} -e 'using Pkg; Pkg.instantiate()'
```
Both share the default root depot (`/root/.julia`); OsmotiC's path-deps resolve
against the copied siblings. Stage is cache-keyed on `COPY` content, so it only
re-runs when staged package files change (content hashing replaces `CACHEBUST`).

`builder` stage: reduce to `FROM deps AS builder` + `CMD ["bash"]`.

`runtime` stage:
- Keep OpenMPI/HDF5/Julia/CUDA `COPY --from=builder` lines.
- `ENV PKGROOT=/home/mpiuser/packages`, `CORIUM=${PKGROOT}/cORIUm.jl`,
  `OSMOTIC=${PKGROOT}/OsmotiC.jl`.
- `COPY --from=builder /home/packages /home/mpiuser/packages`.
- `COPY --from=builder /root/.julia /home/mpiuser/.julia` unchanged.
- `chown -R mpiuser:mpiuser` list: swap `/home/mpiuser/cORIUm.jl` →
  `/home/mpiuser/packages`.
- Precompile both projects as mpiuser:
  ```
  RUN runuser -u mpiuser -- julia --project=${CORIUM}  -e 'using Pkg; Pkg.precompile()'
  RUN runuser -u mpiuser -- julia --project=${OSMOTIC} -e 'using Pkg; Pkg.precompile()'
  ```
- `WORKDIR ${CORIUM}`; entrypoint unchanged.

#### 3. `docker/unix/entrypoint.sh`

Add `OSMOTIC` to the environment note; no logic change — `setup_mpi.jl`
reconfigures HDF5.jl/MPIPreferences in the shared depot, which OsmotiC picks up.
A dedicated OsmotiC boot step, if needed, is a follow-up.

#### 4. `docker/docker-build-tar.sh`

- Call `"$SH_DIR/prep-context.sh"` before `docker build` (abort on failure).
- Drop `--secret id=github_token,...`, `--build-arg CACHEBUST=...`, `SECRET_TOKEN`.
- `VALID_STAGES` → `("builder" "runtime" "deps")` (drop `source`).
- Context stays `"$SH_DIR"` (= `docker/`).

#### 5. `docker/.dockerignore` (new)

```
shipping/
context/packages/**/.git/
**/.DS_Store
```

### Critical files

- `docker/Dockerfile` — main rework
- `docker/prep-context.sh` — new staging script
- `docker/docker-build-tar.sh` — drop secret/cachebust, run prep
- `docker/.dockerignore`, `docker/.gitignore` — new
- `docker/unix/entrypoint.sh` — env note only

### Verification

1. `bash docker/prep-context.sh` → confirm
   `docker/context/packages/{cORIUm.jl,OsmotiC.jl,Datastore.jl}` each contain
   `Project.toml`, `Manifest.toml`, `src/`, and no `.git/`.
2. `cd docker && DOCKER_BUILDKIT=1 docker build -f Dockerfile --target deps -t ce:deps .`
   → dependency resolution for both projects succeeds with no network/token.
3. `docker build -f Dockerfile --target runtime -t ce:runtime .` completes; both
   precompile steps pass.
4. `docker run --rm ce:runtime julia --project=$CORIUM  -e 'using cORIUm; println("cORIUm ok")'`
5. `docker run --rm ce:runtime julia --project=$OSMOTIC -e 'using OsmotiC; println("OsmotiC ok")'`
6. `docker run --rm ce:runtime bash -lc 'mpiexec --version && julia -e "using MPI; MPI.Init(); println(MPI.Comm_size(MPI.COMM_WORLD))"'`
   (regression check on MPI/HDF5 wiring).
7. `bash docker/docker-build-tar.sh` (select `runtime`) produces
   `docker/shipping/image/ubuntu-corium-runtime.tar` with no token prompt.
