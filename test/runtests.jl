# The suite (`using Pkg; Pkg.test()`): the QA families, each dealt to one shard. The differential
# corpus is test/smoke.jl's lane, the byte identity test/probe_bytes.jl's (dev/lanes.sh).
#
# WT_SHARD="i,N": this process runs the QA families dealt to shard i of N (dev/lanes.sh's suite
# lane runs two). WT_QA_ONLY="<name>\n<name>...": exactly these QA families, by their file name,
# and nothing else (dev/block.jl's tests stage, L194); a name that is no QA family fails the run.
using Test

const _WT_QA_ONLY = Set{String}(filter(!isempty, strip.(split(get(ENV, "WT_QA_ONLY", ""), '\n'))))
const _WT_QA_SEEN = Set{String}()
const (_WT_SHARD, _WT_NSHARDS) = let s = get(ENV, "WT_SHARD", "")
    isempty(s) ? (0, 1) : (parse(Int, split(s, ",")[1]), parse(Int, split(s, ",")[2]))
end
# The durations the shards are dealt by: test/phase_times.tsv, "<secs>\tQA: <file>" per QA family,
# measured on CI's runners. A missing entry takes the median.
const _PHASE_TIMES_TSV = joinpath(@__DIR__, "phase_times.tsv")
const _WT_TIMES = let d = Dict{String,Float64}()
    for ln in eachline(_PHASE_TIMES_TSV)
        local parts = split(ln, '\t'; limit = 2)
        length(parts) == 2 || continue
        local t = tryparse(Float64, parts[1])
        t === nothing || (d[String(parts[2])] = t)
    end
    d
end
const _WT_QA_MEDIAN = let c = sort!(collect(Float64, (t for (k, t) in _WT_TIMES if startswith(k, "QA: "))))
    isempty(c) ? 1.0 : c[(length(c) + 1) ÷ 2]
end
# The QA families are dealt in file order, each to the shard whose recorded load is least so far,
# so the N shards together run each exactly once and every process deals them alike. Each one run
# prints a WT_QA_TIME line.
const _WT_QA_LOAD = zeros(_WT_NSHARDS)
function _wt_qa(name::AbstractString)::Bool
    local s = argmin(_WT_QA_LOAD)
    _WT_QA_LOAD[s] += get(_WT_TIMES, "QA: " * name, _WT_QA_MEDIAN)
    push!(_WT_QA_SEEN, name)
    if !isempty(_WT_QA_ONLY)
        name in _WT_QA_ONLY || return false
    else
        s - 1 == _WT_SHARD || return false
    end
    println("WT_QA\t", name)
    return true
end
function _wt_qa_include(path::AbstractString)
    local name = isabspath(path) ? relpath(path, @__DIR__) : path
    _wt_qa(name) || return nothing
    local t = @elapsed include(path)
    println("WT_QA_TIME\t", round(t; digits = 3), "\t", name)
    return nothing
end

# each ported lock fires on its planted mutation, in a scratch checkout of this commit
_wt_qa_include("lock_negatives.jl")
# two worktrees loading alternately each keep their compiled image, in their private depots (dev/depot.sh)
_wt_qa_include("depot_isolation.jl")
# the closed world's classes in program order, each supertype chain Julia's (src/julia/classes.jl, 1.C)
_wt_qa_include("classes.jl")
# the charter's checks (dev/CHARTER.md): every lock at 0, every ratchet at most its baseline
if _wt_qa("parity_ratchet.jl")
    _wt_ratchet_t0 = time()
    ENV["WT_RATCHET_INCLUDED"] = "1"
    include("parity_ratchet.jl")
    @testset "parity ratchet (dev/CHARTER.md)" begin
        @test ParityRatchet.run()
    end
    println("WT_QA_TIME\t", round(time() - _wt_ratchet_t0; digits = 3), "\tparity_ratchet.jl")
end

# WT_QA_ONLY: a name that is no QA family fails the run
if !isempty(_WT_QA_ONLY)
    let unknown = sort([n for n in _WT_QA_ONLY if !(n in _WT_QA_SEEN)])
        isempty(unknown) || (println("runtests: WT_QA_ONLY names no QA family ", join(unknown, ", ")); exit(1))
    end
end
