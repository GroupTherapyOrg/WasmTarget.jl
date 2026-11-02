# dev/progress_kinds.jl — the rejection kinds dev/src_progress.sh counts, read once for its line and for its
# `kinds` listing (A76E2: one read and write of the cache): WasmTarget.rejection_only_kinds over every
# @parity entry, then dev/skeleton.jl's dart_kinds, kept in the common dir at `cache` (dev/src_progress.sh's
# `key`: a file whose recorded inputs are unchanged, else a new one), recomputed when the file is new. The file
# records the inputs the kinds read (kinds_inputs), as Base records an image's includes in its header, and its
# rows. Returns the kinds, their dart lines, and "hit" or "miss".
function progress_kinds(S, cache::String)
    if isfile(cache)
        local R = Dict{String,Symbol}()
        local L = Dict{String,String}()
        for l in eachline(cache)
            startswith(l, "#input\t") && continue
            local f = split(l, '\t')
            R[f[1]] = Symbol(f[2]); length(f) > 2 && (L[f[1]] = f[3])
        end
        return R, L, "hit"
    end
    local es = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget)]
    local R, L = Skeleton.dart_kinds(WasmTarget.rejection_only_kinds(es), Skeleton.anchored_decls(S))
    local inputs = kinds_inputs()
    local tmp = cache * ".$(getpid())"
    open(tmp, "w") do io
        for (p, id) in inputs
            println(io, "#input\t", p, '\t', id)
        end
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

# the files of the tree the kinds read, each by its path and its id (dev/cache_key.sh --ids, the one definition:
# a file's blob id, a directory's listing's, as Base reads a directory include): every include and
# include_dependency of each image loaded here whose package lies in the tree (WasmTarget, its interpreter),
# read from the image's header as Base records them (julia/base/loading.jl:3657 parse_cache_header), and every
# file the reader read (Skeleton.INPUTS, read_input). dev/cache_key.sh's `--fresh` compares them again, as
# Base's any_includes_stale (loading.jl:3994) compares an image's includes. An image of the tree loaded from
# no cache file, an include outside the tree, or no input at all is refused, located: a record missing a file
# would serve kinds that file changed (D9).
function kinds_inputs()::Vector{Tuple{String,String}}
    local root = Skeleton.ROOT
    local under(f) = startswith(normpath(f), root)
    local files = Set{String}()
    for (id, o) in Base.pkgorigins
        local m = get(Base.loaded_modules, id, nothing)
        (m === nothing || pkgdir(m) === nothing || !under(pkgdir(m) * "/")) && continue
        o.cachepath === nothing && error("progress_kinds: $(id.name) was loaded from no image, so the files it read are not recorded")
        local incs = Base.parse_cache_header(o.cachepath)[2][1]
        for chi in incs
            local f = normpath(chi.filename)
            under(f) || error("progress_kinds: $(id.name)'s image records $(chi.filename), outside the tree $root")
            push!(files, relpath(f, root))
        end
    end
    for f in Skeleton.INPUTS
        under(f) || continue          # a pinned checkout's file: keyed by the checkout's head
        push!(files, relpath(normpath(f), root))
    end
    isempty(files) && error("progress_kinds: the kinds read no recorded input")
    local paths = sort!(collect(files))
    local rows = readlines(pipeline(Cmd(`bash dev/cache_key.sh --ids`; dir = root); stdin = IOBuffer(join(paths, '\n') * '\n')))
    length(rows) == length(paths) || error("progress_kinds: $(length(paths)) inputs gave $(length(rows)) ids")
    return [(String(a), String(b)) for (a, b) in (split(r, '\t') for r in rows)]
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
