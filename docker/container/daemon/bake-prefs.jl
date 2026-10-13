# bake-prefs.jl
#
# Writes the image's preferences into the active project's
# LocalPreferences.toml. Run at build time, BEFORE Pkg.precompile(), so the
# precompile cache is built against exactly the configuration the container
# runs with. Two uses (see the Dockerfile's runtime stage):
#
#   julia --project=$CORIUM  bake-prefs.jl              MPI + HDF5 + CUDA
#   julia --project=$OSMOTIC bake-prefs.jl --cuda-only  CUDA only
#
# Why OsmotiC gets CUDA only: the daemon runs --project=$OSMOTIC and uses the
# GPU through cORIUm in-process, so it needs the CUDA preference too - without
# it CUDA_Runtime_jll stays precompiled for `cuda = "none"` (no GPU at build
# time) and CUDA.functional() is false: CPU fallback. But it must keep the
# default MPI/HDF5: OsmotiC pulls in GDAL_jll, whose single Linux build links
# MPICH's libmpi.so.12 and only loads alongside the default (MPICH) MPI jlls -
# the system-OpenMPI preferences break its precompile. OsmotiC never calls
# MPI.Init (only cORIUm's own cORE.jl does, under --project=$CORIUM).
#
# Nothing here needs a GPU: every value is a fixed path/version of this image
# (see the ENV block of the runtime stage in the Dockerfile).
#
# This writes the same preferences as cORIUm.jl/src/boot/needs/setup_mpi.jl,
# but directly: that script runs `using CUDA` *before* setting the CUDA
# preference, which here would compile CUDA once for the wrong configuration.
#
# Why this can't be left to container start: these are compile-time
# preferences. Changing any of them invalidates the cache of MPI, HDF5,
# CUDA_Runtime_jll, CUDA and everything downstream. Rewriting them at start
# forced a full recompile on every `docker run`, and recompiling CUDA in the
# same process that had just loaded it failed with
#   "Module CUDA with build ID ffffffff-... is missing from the cache"
#   "Declaring __precompile__(false) is not allowed in files that are being precompiled"
# (AtomixCUDAExt). With no CUDA preference at build time, CUDA_Runtime_jll was
# also precompiled for `cuda = "none"` and downloaded a CUDA_Runtime artifact at
# first GPU start instead of using the toolkit copied into the image.

using UUIDs: UUID

# Preferences.jl is in both projects' Manifests but a direct dependency of
# neither, so it's loaded by its identity rather than `using Preferences`.
const Preferences = Base.require(Base.PkgId(UUID("21216c6a-2e73-6563-6e65-726566657250"), "Preferences"))

const CUDA_ONLY = "--cuda-only" in ARGS

if !CUDA_ONLY
    # MPI.jl -> system OpenMPI (CUDA-aware). MPIPreferences is a direct
    # dependency of cORIUm.jl.
    MPIPreferences = Base.require(Base.PkgId(UUID("3da0fdf6-3ccc-4f1b-acd9-58baa6c99267"), "MPIPreferences"))
    MPIPreferences.use_system_binary(mpiexec=ENV["CORIUM_MPIEXEC_PATH"])

    # HDF5.jl + HDF5_jll -> system parallel HDF5. Same keys/values as
    # cORIUm.jl/src/boot/needs/setup_mpi.jl, so an opt-in re-run of that script
    # (CORIUM_RECONFIGURE=1) rewrites identical values and doesn't invalidate the
    # cache. HDF5_jll is listed in cORIUm.jl's [extras] for this preference.
    Preferences.set_preferences!(UUID("f67ccb44-e63f-5c2f-98bd-6dc0ccc4ba2f"),
        "libhdf5"    => ENV["CORIUM_HDF5_LIB"],
        "libhdf5_hl" => ENV["CORIUM_HDF5_HL_LIB"];
        force=true)
    Preferences.set_preferences!((UUID("0234f1f7-429e-5d53-9886-15a909be8d59"), "HDF5_jll"),
        "libhdf5_path"    => ENV["CORIUM_HDF5_LIB"],
        "libhdf5_hl_path" => ENV["CORIUM_HDF5_HL_LIB"];
        force=true)
end

# CUDA.jl -> local toolkit at $CUDA_ROOT. Same string format as
# CUDA.set_runtime_version!(v; local_toolkit=true). A preference only counts
# in a project that lists the package: cORIUm.jl has CUDA_Runtime_jll in its
# [extras]; for OsmotiC.jl this (uuid, name) form adds it there (in the
# image's copy of its Project.toml).
Preferences.set_preferences!((UUID("76a88914-d11a-5bdc-97e0-2f5a05c973a2"), "CUDA_Runtime_jll"),
    "version" => ENV["CORIUM_CUDA_VERSION"],
    "local"   => "true";
    force=true)

println("✅ Baked ", CUDA_ONLY ? "CUDA" : "MPI/HDF5/CUDA", " preferences into ", Base.active_project())
