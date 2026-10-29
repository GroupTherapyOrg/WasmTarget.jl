# The byte-identity probes' corpus (test/probe_bytes.jl's): each a (f, argtypes) pair compiled with
# an explicit export name, its module's bytes hashed against test/probe_baseline.txt. The rebuild's
# probes arrive with the modules it builds (dev/MARCH.md 1.B); until then the corpus is empty.

const CASES = Vector{Pair{String,Tuple}}()   # name => (f, argtypes::Tuple)
_c(name::String, f, argtypes...) = push!(CASES, name => (f, argtypes))

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
