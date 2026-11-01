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
# each file's cost, its instructions retired (G) in the last landing check whose tests passed (WT_SRC_COSTS, the
# common dir's wt-src-instr.tsv dev/check.sh keeps): the shards split by measured cost, never by file size alone (a
# size split put 91 s in one of four shards and 72 s in another, 2026-10-29), and by the instructions D14's band
# judges, never wall seconds (a split by seconds, which the machine's load moves, left 150 G between the lightest and
# heaviest shard and turned wt3-memory's #undef field commit red at 129 and 131 s, its tests green, 2026-11-01); a
# file not yet measured costs its size at the measured files' instructions per byte, and with nothing measured every
# file costs its size. A row keeps a file's last two measures and costs their larger: files that compile the same
# runtime code (js_string.jl and string_ops.jl both compile the string runtime) share its first-compile cost, which
# lands on whichever runs first in its process, so one check measured string_ops.jl at 132 G and js_string.jl low,
# the next the reverse, and the split by the last measure alone put 706 G in one shard (3a5b6ee7, twice); a file's
# larger measure is its cost in a shard without its sibling, which a longest-first split makes the usual case
const SRC_COST = let p = get(ENV, "WT_SRC_COSTS", ""), c = Dict{String,Float64}()
    if !isempty(p) && isfile(p)
        for l in eachline(p)
            local a = split(l, '\t')
            local v = [tryparse(Float64, x) for x in a[2:end]]
            2 <= length(a) <= 3 && !any(isnothing, v) && (c[String(a[1])] = maximum(v))
        end
    end
    local measured = [f for f in SRC_TESTS if haskey(c, f)]
    local rate = isempty(measured) ? 1.0 : sum(c[f] for f in measured) / max(1, sum(filesize(joinpath(SRC_TEST_DIR, f)) for f in measured))
    Dict(f => get(c, f, filesize(joinpath(SRC_TEST_DIR, f)) * rate) for f in SRC_TESTS)
end
# WT_SRC_SHARD="k/n" (dev/check.sh runs n shards side by side) runs the files as Julia's own test runner hands its
# tests to workers: a shared queue, longest first, each shard taking the next file when it finishes one
# (precedent(julia: test/runtests.jl:267, v1.12.7: `test = popfirst!(tests)` in each worker's loop); WT's queue is
# a directory, WT_SRC_CLAIMS, a file claimed by the shard whose mkdir of its name succeeds, since the shards are
# separate processes, not one process's workers). A static split cannot balance these files: about 110 G of first
# compile lands on whichever file first reaches it in its process (records.jl measured 136 G, then 24; globals.jl
# 67, then 3), so a shard drawing two read 669-706 G against 420-550 for the rest, red on D14 with its tests green
# (25f5d125 and the four checks after it, 2026-11-01); a shard that pays such a cost takes fewer files instead.
# Without WT_SRC_SHARD every file runs.
const _WT_CLAIMS = get(ENV, "WT_SRC_CLAIMS", "")
# A file that loads test/DartCorpus goes last: the corpus ports dart's operator overrides as methods of Base's
# generics on its own types (>=, >, ==, getindex, iterate), and loading them invalidates the compiled code of every
# caller that reached those generics at an abstract type, Base's and Julia's compiler's above all (3145 method
# instances, the next WasmTarget.compile then 174 G instead of 0.2, wt3-latency 13:38). Claimed last, it is claimed
# once every other file is, so its invalidations reach no other file's compiles. Julia's own test runner keeps one
# file's definitions from another's by a fresh module each (precedent(julia: test/testdefs.jl:16, v1.12.7: `m =
# @eval(Main, module $mod_name end)`)) and its worker processes; a module does not stop methods added to Base's
# generics, and WT's shards are a fixed set of processes, so here the order isolates them
# (it loads the corpus through test/DartCorpus or, on Julia 1.13, test/smoke_corpus.jl itself: subset.jl, A69S4)
_wt_loads_corpus(f::String)::Bool = occursin(r"DartCorpus|smoke_corpus\.jl", read(joinpath(SRC_TEST_DIR, f), String))
const SRC_SHARD = isempty(get(ENV, "WT_SRC_SHARD", "")) ? SRC_TESTS :
    sort(SRC_TESTS; by = f -> (_wt_loads_corpus(f), -SRC_COST[f], f))
isempty(get(ENV, "WT_SRC_SHARD", "")) || !isempty(_WT_CLAIMS) ||
    error("WT_SRC_SHARD runs the queue in WT_SRC_CLAIMS, which is unset: no shard could claim a file")
# a file is this shard's when its claim is made here: mkdir is atomic, so exactly one shard runs each file
_wt_claim(f::String)::Bool = isempty(get(ENV, "WT_SRC_SHARD", "")) ||
    try mkdir(joinpath(_WT_CLAIMS, replace(f, '/' => "__"))); true
    catch e   # only "it exists" is another shard's claim; any other failure is red
        e isa Base.IOError && e.code == Base.UV_EEXIST || rethrow(); false
    end
# the file and case running now, for dev/check.sh's hard limit to name (WT_PROGRESS)
const _WT_PROGRESS = get(ENV, "WT_PROGRESS", "")
wt_progress(s::AbstractString) = isempty(_WT_PROGRESS) || write(_WT_PROGRESS, s)
# each file's instructions retired go to WT_SRC_COSTS_OUT, for dev/check.sh to keep once the tests pass, read from
# the process's own counter (macOS's proc_pid_rusage, the rusage_info_v4 counter /usr/bin/time -l reports as
# "instructions retired", sys/resource.h: ri_instructions, the 30th 64-bit field after the 16-byte ri_uuid; check.sh
# runs on macOS alone). A process's first
# WasmTarget.compile pays about 49 CPU-s compiling WasmTarget's own pipeline (wt3-cgstubs, 12:59), which would land on
# whichever file ran first and leave that file unmeasured or mismeasured; so a measured run compiles one small
# function first, every shard paying that start alike, and every file's seconds are then its own
const _WT_COSTS_OUT = get(ENV, "WT_SRC_COSTS_OUT", "")
function _wt_instructions()
    local info = zeros(UInt64, 40)   # rusage_info_v4 is 16 + 37 * 8 bytes; 40 words hold it
    ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt64}), getpid(), 4, info) == 0 ||
        error("proc_pid_rusage(RUSAGE_INFO_V4) failed: no instruction count to measure this file by")
    info[2 + 29 + 1]
end
isempty(_WT_COSTS_OUT) || Sys.isapple() || error("WT_SRC_COSTS_OUT measures instructions by macOS's proc_pid_rusage; dev/check.sh runs on macOS alone")
isempty(_WT_COSTS_OUT) || WasmTarget.compile(x::Int64 -> x + Int64(1), (Int64,))   # a failure here is a broken pipeline, red
@testset verbose = true "src" begin
    for (i, f) in enumerate(SRC_SHARD)
        _wt_claim(f) || continue
        wt_progress(f)
        local i0 = isempty(_WT_COSTS_OUT) ? UInt64(0) : _wt_instructions()
        @testset "$f" begin include(joinpath(SRC_TEST_DIR, f)) end
        !isempty(_WT_COSTS_OUT) && open(io -> println(io, f, '\t', round((_wt_instructions() - i0) / 1e9; digits = 1)), _WT_COSTS_OUT, "a")
    end
end
