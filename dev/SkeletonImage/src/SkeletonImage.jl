# dev/SkeletonImage — dev/skeleton.jl, the generator and the one dart reader, loaded as a package so that
# Julia's own image cache keeps its compiled code across processes (julia/base/loading.jl:4049
# stale_cachefile: the image is rebuilt when an include's content, the julia build or a dependency
# changes): the ratchet's L210 and dev/src_progress.sh each paid ~30 CPU-s compiling the reader in every
# fresh process. The workload runs the reader and the generator's checks on the tree at precompile time
# where the pinned dart checkout exists, so their compiled code is in the image. precedent(julia:
# PrecompileTools' @compile_workload, Base's own precompile statements): a workload run while the image is
# built keeps its compiled code; the reader's runs are that workload.
module SkeletonImage
include(joinpath(@__DIR__, "..", "..", "skeleton.jl"))
# what the generator reads beside its own file, includes of the image as Base records them (A79E1): an edit to
# one rebuilds it, as stale_cachefile rebuilds an image whose include changed
include_dependency(joinpath(@__DIR__, "..", "..", "..", "src", "julia", "parity.jl"))
include_dependency(joinpath(@__DIR__, "..", "..", "..", "src", "julia", "kernel.jl"))
include_dependency(joinpath(@__DIR__, "..", "..", "skeleton_scope.toml"))
# the tables the workload filled are the build's, never a load's: emptied, and `snake` read again (A79E1)
__init__() = Skeleton.reset!()
if isdir(joinpath(homedir(), ".cache", "wasmtarget", "dart-sdk", "pkg"))
    let S = Skeleton.read_scope()
        Skeleton.check_faults()
        Skeleton.diff_faults(S; fields = false)
        Skeleton.anchored_decls(S)
        Skeleton.packages_text(p -> read(p, String))
        Skeleton.unused_kernel_rows(S)
    end
end
end
