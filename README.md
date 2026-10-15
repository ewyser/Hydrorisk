# Hydrorisk

Hydrorisk is a platform for simulating surface runoff and flooding from QGIS:
users upload their data, set up simulations over an area and a period, and get
back maps of water heights, discharges and velocities. The simulations solve
the shallow-water equations on CPU or GPU.

The platform is made of Julia packages, each in its own repository, checked
out side by side:

| Package | Role |
|:--|:--|
| [Gateway.jl](https://github.com/ewyser/Gateway.jl) | REST API, and the QGIS plugin |
| [Daemon.jl](https://github.com/ewyser/Daemon.jl) | job service |
| [OsmotiC.jl](https://github.com/ewyser/OsmotiC.jl) | model: inputs, simulation, results |
| [cORIUm.jl](https://github.com/ewyser/cORIUm.jl) | shallow-water solver |
| [Datastore.jl](https://github.com/ewyser/Datastore.jl) | database |

This repository holds what belongs to the platform as a whole:

- `docker/` — the deployment: images, `docker-compose.yml`, `deploy.sh`;
- `docs/` — the platform documentation, assembled with every package's own
  into one site.

## Documentation

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'   # once
julia --project=docs docs/make.jl                        # builds every package's docs, then the site
python3 -m http.server --directory docs/build            # http://localhost:8000
```

It covers the platform (how a job runs end to end, configuration,
deployment, development) and each package.

## Deploy

```sh
docker/container/build-all.sh    # build the images
docker/deploy/deploy.sh          # start the stack
```

See the documentation's *Deployment* page for the first deployment (the
database seed) and day-to-day operations.
