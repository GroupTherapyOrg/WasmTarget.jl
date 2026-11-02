# dev/progress_kinds.jl — the rejection kinds dev/src_progress.sh counts, read once for its line and for its
# `kinds` listing (A76E2: one read and write of the cache): WasmTarget.rejection_only_kinds over every
# @parity entry, then dev/skeleton.jl's dart_kinds, kept in the common dir under dev/cache_key.sh's key
# (`cache`, the file's path), recomputed when the key is new. Returns the kinds, their dart lines, and
# "hit" or "miss".
function progress_kinds(S, cache::String)
    if isfile(cache)
        local R = Dict{String,Symbol}()
        local L = Dict{String,String}()
        for l in eachline(cache)
            local f = split(l, '\t')
            R[f[1]] = Symbol(f[2]); length(f) > 2 && (L[f[1]] = f[3])
        end
        return R, L, "hit"
    end
    local es = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget)]
    local R, L = Skeleton.dart_kinds(WasmTarget.rejection_only_kinds(es), Skeleton.anchored_decls(S))
    local tmp = cache * ".$(getpid())"
    open(tmp, "w") do io
        for (a, k) in R
            println(io, a, '\t', k, haskey(L, a) ? "\t" * L[a] : "")
        end
    end
    mv(tmp, cache; force = true)
    # the newest sixteen kept
    local old = sort!(filter(f -> endswith(f, ".tsv"), readdir(dirname(cache); join = true)); by = mtime, rev = true)
    foreach(rm, old[17:end])
    return R, L, "miss"
end

# the src progress line's counts, read once (dev/src_progress.sh's julia, and the ratchet's L208 in its own
# process, which has WasmTarget and the generator loaded): the anchored total (each definition the generator
# counts in scope), the ported (a counted anchor src fills, no @unported entry left at it), and of the ported
# those whose kind (progress_kinds) is Internal, a gap (Unported, Unquarantined), DartAbstract and DartThrow,
# and whether the kinds were the cache's
function progress_counts(S, cache::String)
    local counted = Set(Skeleton.anchor(f, d) for f in Skeleton.scope() for d in S.decls[f] if Skeleton.counted(d))
    local e = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget) && x.anchor in counted]
    local stubbed = Set(x.anchor for x in e if !x.ported)
    local ported = setdiff(Set(x.anchor for x in e), stubbed)
    local R, _, hit = progress_kinds(S, cache)
    local k(a) = get(R, a, :body)
    return (length(counted), length(ported), count(a -> k(a) === :Internal, ported),
            count(a -> k(a) in (:Unported, :Unquarantined), ported), count(a -> k(a) === :DartAbstract, ported),
            count(a -> k(a) === :DartThrow, ported), hit)
end
