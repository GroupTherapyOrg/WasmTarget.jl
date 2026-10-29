# Every test of ported code: each file under test/src/, found by walking the directory (dev/check.sh).
# A lane adds a test by adding its file there; no list is shared between lanes to conflict on.
# the whole suite runs on the performance cores only as a landing's check (dev/check.sh, under the landing
# lock, CHECK_LANDING=1); run by hand it refuses unless at background QoS (taskpolicy -b: efficiency cores), so a
# lane's run cannot take the cores the landing check needs (wt3-constants, 08:07 and 08:12: two hand runs at
# normal priority beside a check; told to stop once, it started again)
# (the guard reads this Mac's scheduler priority: 4 at background QoS, 31 normal; it holds for the file run as a
# program, never for test/runtests.jl's include, the full matrix at clause closure on CI's runners)
if Sys.isapple() && abspath(PROGRAM_FILE) == (@__FILE__) && get(ENV, "CHECK_LANDING", "") != "1" &&
   parse(Int, strip(read(`ps -o pri= -p $(getpid())`, String))) > 10
    error("test/src_tests.jl runs on the performance cores only as a landing's check: run it under " *
          "`taskpolicy -b`, run one file of test/src/ with `bash dev/lanetest.sh test/src/<file>.jl`, or commit and let dev/autoship.sh check it")
end
using Test, WasmTarget
const SRC_TEST_DIR = joinpath(@__DIR__, "src")
const SRC_TESTS = sort!([relpath(joinpath(d, f), SRC_TEST_DIR)
                         for (d, _, fs) in walkdir(SRC_TEST_DIR) for f in fs if endswith(f, ".jl")])
isempty(SRC_TESTS) && error("test/src/ holds no test file: the walk found nothing")
# each file's cost, its seconds in the last green landing check (WT_SRC_COSTS, the common dir's wt-src-costs.tsv
# dev/check.sh keeps): the shards split by measured cost, never by file size alone (a size split put 91 s in one
# of four shards and 72 s in another, 2026-10-29); a file not yet measured costs its size at the measured files'
# seconds per byte, and with nothing measured every file costs its size
const SRC_COST = let p = get(ENV, "WT_SRC_COSTS", ""), c = Dict{String,Float64}()
    if !isempty(p) && isfile(p)
        for l in eachline(p)
            local a = split(l, '\t')
            length(a) == 2 && (local v = tryparse(Float64, a[2]); v === nothing || (c[String(a[1])] = v))
        end
    end
    local measured = [f for f in SRC_TESTS if haskey(c, f)]
    local rate = isempty(measured) ? 1.0 : sum(c[f] for f in measured) / max(1, sum(filesize(joinpath(SRC_TEST_DIR, f)) for f in measured))
    Dict(f => get(c, f, filesize(joinpath(SRC_TEST_DIR, f)) * rate) for f in SRC_TESTS)
end
# WT_SRC_SHARD="k/n" (dev/check.sh runs n shards side by side on the performance cores) takes shard k of a
# longest-first split by cost, so the shards finish together; without it, every file runs
const SRC_SHARD = let sh = get(ENV, "WT_SRC_SHARD", "")
    if isempty(sh)
        SRC_TESTS
    else
        local k, n = parse.(Int, split(sh, '/'))
        local load = zeros(n)
        local mine = String[]
        for f in sort(SRC_TESTS; by = f -> (-SRC_COST[f], f))
            local j = argmin(load)
            load[j] += SRC_COST[f]
            j == k && push!(mine, f)
        end
        sort!(mine)
    end
end
# the file and case running now, for dev/check.sh's hard limit to name (WT_PROGRESS)
const _WT_PROGRESS = get(ENV, "WT_PROGRESS", "")
wt_progress(s::AbstractString) = isempty(_WT_PROGRESS) || write(_WT_PROGRESS, s)
# each file's seconds go to WT_SRC_COSTS_OUT, for dev/check.sh to keep once the check is green. A process's first
# WasmTarget.compile pays about 49 CPU-s compiling WasmTarget's own pipeline (wt3-cgstubs, 12:59), which would land on
# whichever file ran first and leave that file unmeasured or mismeasured; so a measured run compiles one small
# function first, every shard paying that start alike, and every file's seconds are then its own
const _WT_COSTS_OUT = get(ENV, "WT_SRC_COSTS_OUT", "")
isempty(_WT_COSTS_OUT) || WasmTarget.compile(x::Int64 -> x + Int64(1), (Int64,))   # a failure here is a broken pipeline, red
@testset verbose = true "src" begin
    for (i, f) in enumerate(SRC_SHARD)
        wt_progress(f)
        local t0 = time()
        @testset "$f" begin include(joinpath(SRC_TEST_DIR, f)) end
        !isempty(_WT_COSTS_OUT) && open(io -> println(io, f, '\t', round(time() - t0; digits = 1)), _WT_COSTS_OUT, "a")
    end
end
