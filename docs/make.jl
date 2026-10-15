# The Hydrorisk documentation: the platform pages (docs/src/) and every
# package's own documentation, assembled into one site with a shared top bar
# and one search (MultiDocumenter).
#
# Each package's docs stay in its repository and build in its own environment:
# they are built here as separate processes, from the sibling checkouts
# (git/<Package>.jl, the branch each one has checked out), then copied in.
#
#   julia --project=docs -e 'using Pkg; Pkg.instantiate()'   # once
#   julia --project=docs docs/make.jl                        # everything → docs/build/
#   julia --project=docs docs/make.jl --skip-packages        # reuse the packages' last builds
#   python3 -m http.server --directory docs/build            # view at http://localhost:8000
#
# Serve the site over HTTP: opened as file://, the diagrams, the search and
# the API reference do not load. No deploydocs: publishing is a separate step.

using Documenter, DocumenterMermaid, MultiDocumenter

const DOCS = @__DIR__
const GIT  = normpath(joinpath(DOCS, "..", ".."))   # the folder holding the sibling packages

# Shown in the top bar in this order; `path` is the site's URL path
const PACKAGES = [
    (repo = "Gateway.jl",   path = "gateway",   name = "Gateway"),
    (repo = "Daemon.jl",    path = "daemon",    name = "Daemon"),
    (repo = "OsmotiC.jl",   path = "osmotic",   name = "OsmotiC"),
    (repo = "cORIUm.jl",    path = "corium",    name = "cORIUm"),
    (repo = "Datastore.jl", path = "datastore", name = "Datastore"),
]

# 1. The packages' sites, each in its own environment
if "--skip-packages" ∉ ARGS
    for pkg in PACKAGES
        dir = joinpath(GIT, pkg.repo)
        isdir(joinpath(dir, "docs")) || error("$(pkg.repo): no docs/ in $dir")
        @info "Building the $(pkg.name) documentation..."
        run(`$(Base.julia_cmd()) --project=$(joinpath(dir, "docs")) -e "using Pkg; Pkg.instantiate()"`)
        run(`$(Base.julia_cmd()) --project=$(joinpath(dir, "docs")) $(joinpath(dir, "docs", "make.jl"))`)
    end
end
for pkg in PACKAGES
    isfile(joinpath(GIT, pkg.repo, "docs", "build", "index.html")) ||
        error("$(pkg.repo) has no built documentation: run without --skip-packages")
end

# 2. The platform pages
@info "Building the platform documentation..."
makedocs(
    sitename = "Hydrorisk",
    authors  = "madMax",
    format   = Documenter.HTML(edit_link = "main", inventory_version = "main"),
    build    = "build-platform",
    pages    = [
        "Home"           => "index.md",
        "A job, end to end" => "job_end_to_end.md",
        "Configuration"  => "configuration.md",
        "Deployment"     => "deployment.md",
        "Development"    => "development.md",
    ],
    pagesonly= true,
    repo     = Remotes.GitHub("ewyser", "Hydrorisk"),
)

# Links to the other sites are written `hydrorisk://<site>/<page>/` in the
# platform pages - Documenter checks every relative link against its own
# build, and leaves only URLs with a scheme alone. Rewrite them into relative
# links, right for each page's depth (a page at build-platform/a/index.html
# ends up at <site root>/platform/a/index.html).
for (dir, _, files) in walkdir(joinpath(DOCS, "build-platform")), f in files
    endswith(f, ".html") || continue
    file  = joinpath(dir, f)
    depth = length(splitpath(relpath(dir, joinpath(DOCS, "build-platform")))) - (dir == joinpath(DOCS, "build-platform"))
    html  = read(file, String)
    occursin("hydrorisk://", html) || continue
    write(file, replace(html, "hydrorisk://" => "../"^(depth + 1)))
end

# 3. One site
@info "Assembling the site..."
# The sites are local, unversioned builds: no canonical URLs to fix (that is
# for versioned gh-pages deployments). MultiDocumenter expects git clones and
# warns "Unable to update existing clone ... .git/ directory missing" for each
# site: expected, the builds are used as they are.
docs = [
    MultiDocumenter.MultiDocRef(upstream = joinpath(DOCS, "build-platform"), path = "platform", name = "Platform", fix_canonical_url = false),
    [MultiDocumenter.MultiDocRef(upstream = joinpath(GIT, pkg.repo, "docs", "build"), path = pkg.path, name = pkg.name, fix_canonical_url = false)
     for pkg in PACKAGES]...,
]
MultiDocumenter.make(
    joinpath(DOCS, "build"),
    docs;
    # Local builds are not versioned (no stable/ or dev/): index them whole.
    # FlexSearch builds its index with a bundled Node.js - nothing to install.
    search_engine = MultiDocumenter.SearchConfig(index_versions = [""], engine = MultiDocumenter.FlexSearch),
)
@info "Done: python3 -m http.server --directory $(joinpath(DOCS, "build"))"
