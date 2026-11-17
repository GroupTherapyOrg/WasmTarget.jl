# The byte-identity probes' corpus (test/probe_bytes.jl's): each a (f, argtypes) pair, its module's bytes hashed
# against test/probe_baseline.txt. The probes are test/probe_set.jl's: the first compiling case of each DartCorpus
# group, read from the corpus's precompiled image (test/DartCorpus/load.jl), its argument types its arguments'. An
# empty corpus passed every restructuring vacuously ("0 probes, 0 changed", 2026-11-01, wt3-latency), so a set that
# is empty, or names a case the corpus lacks, fails here.
include(joinpath(@__DIR__, "probe_set.jl"))
include(joinpath(@__DIR__, "DartCorpus", "load.jl"))

const CASES = let bykey = Dict("$g/$(c[1])" => c for (g, cs) in DartCorpus.GROUPS for c in cs)
    isempty(PROBE_NAMES) && error("test/probe_set.jl names no probe: the byte-identity check would pass vacuously")
    local missing = filter(n -> !haskey(bykey, n), PROBE_NAMES)
    isempty(missing) || error("test/probe_set.jl names cases the corpus lacks: $(join(missing, ", "))")
    Pair{String,Tuple}[n => (bykey[n][2], Tuple(map(typeof, bykey[n][3:end]))) for n in PROBE_NAMES]   # name => (f, argtypes)
end

function _load_baseline(path::String)::Dict{String,String}
    baseline = Dict{String,String}()
    isfile(path) || return baseline
    for line in eachline(path)
        isempty(line) && continue
        parts = split(line, '\t')
        length(parts) == 2 || continue
        baseline[parts[1]] = parts[2]
    end
    return baseline
end

function _write_baseline(path::String, hashes::Dict{String,String})
    open(path, "w") do io
        for name in sort(collect(keys(hashes)))
            println(io, name, '\t', hashes[name])
        end
    end
end
