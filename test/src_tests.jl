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
          "`taskpolicy -b`, run one file of test/src/, or commit and let dev/autoship.sh check it")
end
using Test, WasmTarget
const SRC_TEST_DIR = joinpath(@__DIR__, "src")
const SRC_TESTS = sort!([relpath(joinpath(d, f), SRC_TEST_DIR)
                         for (d, _, fs) in walkdir(SRC_TEST_DIR) for f in fs if endswith(f, ".jl")])
isempty(SRC_TESTS) && error("test/src/ holds no test file: the walk found nothing")
# WT_SRC_SHARD="k/n" (dev/check.sh runs n shards side by side, one per performance core) takes shard k of a
# longest-first split by file size, so the shards finish together; without it, every file runs
const SRC_SHARD = let sh = get(ENV, "WT_SRC_SHARD", "")
    if isempty(sh)
        SRC_TESTS
    else
        local k, n = parse.(Int, split(sh, '/'))
        local load = zeros(Int, n)
        local mine = String[]
        for f in sort(SRC_TESTS; by = f -> (-filesize(joinpath(SRC_TEST_DIR, f)), f))
            local j = argmin(load)
            load[j] += filesize(joinpath(SRC_TEST_DIR, f))
            j == k && push!(mine, f)
        end
        sort!(mine)
    end
end
# the file and case running now, for dev/check.sh's hard limit to name (WT_PROGRESS)
const _WT_PROGRESS = get(ENV, "WT_PROGRESS", "")
wt_progress(s::AbstractString) = isempty(_WT_PROGRESS) || write(_WT_PROGRESS, s)
@testset verbose = true "src" begin
    for f in SRC_SHARD
        wt_progress(f)
        @testset "$f" begin include(joinpath(SRC_TEST_DIR, f)) end
    end
end
