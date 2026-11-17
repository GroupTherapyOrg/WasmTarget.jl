# The tests of ported code: each file under test/src/, found by walking the directory. A landing's check runs the set
# of them the climb's lander hands it (dev/check.sh, WT_SRC_SET: the move's own files, the files the last score did not
# run green, and its window of the rest, the landing-check ruling); the score runs every one (dev/climb/measure.py
# src_score), and so does test/runtests.jl at clause closure. A lane adds a test by adding its file there; no list is
# shared between lanes to conflict on.
# the whole suite runs on the performance cores only as a landing's check (dev/check.sh, under the landing
# lock, CHECK_LANDING=1); run by hand it refuses unless at background QoS (taskpolicy -b: efficiency cores), so a
# lane's run cannot take the cores the landing check needs (wt3-constants, 08:07 and 08:12: two hand runs at
# normal priority beside a check; told to stop once, it started again)
# (the guard reads this Mac's scheduler priority: 4 at background QoS, 31 normal; it holds for the file run as a
# program, never for test/runtests.jl's include, the full matrix at clause closure on CI's runners)
# (the climb's score runs it at default QoS too, as its src part, WT_SRC_RECORDS set: one process under the score's
# measurement lock, which a landing's lander takes before its check, so it never runs beside one; at default QoS so that
# each file's instructions are counted on the cores a landing's check runs on, an efficiency core's counter reading some
# instruction mixes at half (dev/check.sh), dev/climb/measure.py src_run)
if Sys.isapple() && abspath(PROGRAM_FILE) == (@__FILE__) && get(ENV, "CHECK_LANDING", "") != "1" &&
   isempty(get(ENV, "WT_SRC_RECORDS", "")) && parse(Int, strip(read(`ps -o pri= -p $(getpid())`, String))) > 10
    error("test/src_tests.jl runs on the performance cores only as a landing's check: run it under " *
          "`taskpolicy -b`, run one file of test/src/ with `bash dev/lanetest.sh test/src/<file>.jl`, or commit and let dev/autoship.sh check it")
end
using Test, Base64
# the judge's instruction counter and canary load before any src does, unguarded (spec v20 F3, architect round 17 5): no
# load-time code in src (an `__init__` defining `Main._wt_canary` first) can stand in for either
Base.include(Main, joinpath(@__DIR__, "instructions.jl"))
Base.include(Main, joinpath(@__DIR__, "src_canary.jl"))
# the canary's own methods, bound before any src loads (spec v20 G1, red round 18 1): each canary call first requires
# that `_wt_canary` still dispatches to these, defined in test/src_canary.jl; a method load-time src (or a test file)
# put in their place reads the canary wrong, which voids the process, located
const _WT_CANARY_FILE = joinpath(@__DIR__, "src_canary.jl")
const _WT_CANARY_M = (which(_wt_canary, Tuple{}), which(_wt_canary, Tuple{String}))
function _wt_canary_bound(f::Union{Nothing,String} = nothing)::Tuple{Bool,String}
    local now = (which(_wt_canary, Tuple{}), which(_wt_canary, Tuple{String}))
    if now !== _WT_CANARY_M || any(m -> String(m.file) != _WT_CANARY_FILE, now)
        return false, "the canary is no longer test/src_canary.jl's: _wt_canary dispatches to " *
                      join(("$(m.file):$(m.line)" for m in now), " and ") * ", not the methods bound before src loaded"
    end
    return f === nothing ? _wt_canary() : _wt_canary(f)
end
using WasmTarget
const SRC_TEST_DIR = joinpath(@__DIR__, "src")
const SRC_TESTS = sort!([relpath(joinpath(d, f), SRC_TEST_DIR)
                         for (d, _, fs) in walkdir(SRC_TEST_DIR) for f in fs if endswith(f, ".jl")])
isempty(SRC_TESTS) && error("test/src/ holds no test file: the walk found nothing")
# WT_SRC_SET names a file listing the test files to run, one path under test/src a line, a line starting `#` its
# header (a landing's set names the commit it was made for: dev/check.sh reads it): the climb's driver's (a landing's
# check, a score's src part, a red file run again alone, a bisect's step, dev/climb/measure.py src_run). Exactly those
# run, in the walk's order; a path the walk does not hold, a set that names none and a set file that is missing are
# refused (D9), never read as every file. Without it every file the walk finds runs
const SRC_SET = let p = get(ENV, "WT_SRC_SET", "")
    if isempty(p)
        SRC_TESTS
    else
        isfile(p) || error("WT_SRC_SET names $p, which is no file: no set of test files to run")
        local want = [String(strip(l)) for l in eachline(p) if !isempty(strip(l)) && !startswith(strip(l), "#")]
        isempty(want) && error("WT_SRC_SET's file $p names no test file")
        local unknown = setdiff(want, SRC_TESTS)
        isempty(unknown) || error("WT_SRC_SET names $(length(unknown)) path(s) test/src's walk does not hold: $(join(first(unknown, 5), ", "))")
        [f for f in SRC_TESTS if f in want]
    end
end
# each file's cost, its instructions retired (G) in the last score's src part (WT_SRC_COSTS: the costs the lander hands
# a landing's check from the score's record, written by origin's harness; the landing-check ruling's R6 deleted the
# table every landing's own processes rewrote): the shards split by measured cost, never by file size alone (a
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
    Dict(f => get(c, f, filesize(joinpath(SRC_TEST_DIR, f)) * rate) for f in SRC_SET)
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
# A file loads the corpus when one of its calls includes test/DartCorpus's loader or test/smoke_corpus.jl, read from the
# file as Julia's parser reads it (Meta.parseall), never from its text: a comment naming the corpus
# (code_generator_intrinsics.jl) or a file that reads the corpus's text without loading it (float_guard.jl, probe_set.jl)
# loads nothing, and a text match sent them to the queue's tail, where float_guard.jl's node runs ended one shard ~20 s
# after the rest
_wt_names_corpus(x)::Bool = x isa String ? occursin(r"DartCorpus|smoke_corpus\.jl", x) : x isa Expr && any(_wt_names_corpus, x.args)
_wt_includes_corpus(x)::Bool = x isa Expr &&
    ((x.head === :call && (x.args[1] === :include || x.args[1] == :(Base.include)) && any(_wt_names_corpus, x.args[2:end])) ||
     any(_wt_includes_corpus, x.args))
_wt_loads_corpus(f::String)::Bool = _wt_includes_corpus(Meta.parseall(read(joinpath(SRC_TEST_DIR, f), String)))
const SRC_SHARD = isempty(get(ENV, "WT_SRC_SHARD", "")) ? SRC_SET :
    sort(SRC_SET; by = f -> (_wt_loads_corpus(f), -SRC_COST[f], f))
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
# A process's first WasmTarget.compile pays about 49 CPU-s compiling WasmTarget's own pipeline (wt3-cgstubs, 12:59),
# which would land on whichever file ran first and leave that file unmeasured or mismeasured; so a measured run compiles
# one small function first, every shard paying that start alike, and every file's cost is then its own
# WT_SRC_RECORDS names the records the climb's driver reads of this run (its src part of a score, a red file's run
# alone, a bisect's step: dev/climb/measure.py src_run, which watches them as it watches a measurement's cases): before
# each file `started\t<file>`, flushed, and after it `row\t<file>\t<passed|failed>\t<its cost, G>\t<why, base64>\t<its canary
# as the file: passed, or failed:<why, base64>>` (spec v17 Z4), its
# why every test that did not pass (a line each, its file:line and kind first: spec v18 Q1) or empty, and nothing else (the driver reads its end
# from the process's exit, a line outside a file's block refused as a lie). A landing's check writes them too, a file a
# shard, which the lander reads when the check is red on its tests (R3: a red file outside the move's own is run at
# origin's head). A file's cost is its instructions retired, read from the process's own counter (test/instructions.jl),
# and its children's seconds (below); the start the run pays before its first file (its first compile of WasmTarget's
# pipeline) goes to WT_SRC_WARM, so the driver predicts a check's shards from the score's measures
const _WT_RECORDS = get(ENV, "WT_SRC_RECORDS", "")
const _WT_MEASURED = !isempty(_WT_RECORDS)
_WT_MEASURED && !Sys.isapple() && error("WT_SRC_RECORDS measures instructions by macOS's proc_pid_rusage; dev/check.sh and the climb run on macOS alone")
# a file's cost counts what D14's band reads of its shard's tree: its own instructions, and the CPU seconds of the
# children it ran (wasm-opt, node, a perl watchdog), which the band judges one for one, at the shards' performance-core
# rate (dev/check.sh's RATE_P_SRC, passed as WT_SRC_CHILD_RATE: the one rate, never a copy). Its own instructions alone
# put float_guard.jl, whose wasm-opt and node runs take about 21 CPU-s, at 72 G among the light files, and the shard
# drawing it was the slowest of every check by about its children's seconds (d14-report, timing-report 2026-11-10)
const _WT_CHILD_RATE = let r = !_WT_MEASURED ? 0.0 : tryparse(Float64, get(ENV, "WT_SRC_CHILD_RATE", ""))
    r === nothing && error("WT_SRC_RECORDS measures each file's children at WT_SRC_CHILD_RATE, dev/check.sh's RATE_P_SRC, which is unset or no number")
    r
end
# a file's cost since (i0, c0): its own instructions and its children's seconds at the shards' rate, in G
_wt_cost(i0, c0) = round((_wt_instructions() - i0) / 1e9 + (_wt_children_cpu() - c0) * _WT_CHILD_RATE; digits = 1)
_wt_record(line::AbstractString) = isempty(_WT_RECORDS) || open(io -> (write(io, line, '\n'); flush(io)), _WT_RECORDS, "a")
# EVERY result of a file's testset that did not pass, depth first, one line each, `<file>:<line> <kind>: <its first
# line>` (the records' why), or "" when every test passed. A red's identity is the set of their `<file>:<line> <kind>`
# (spec v18 Q1, the round-15 architect's finding 2: a row that carried its first failure alone let a known red mask a
# new failure of its file); past _WT_NONPASS_MAX lines the rest are counted in one last line, which no known red holds
const _WT_NONPASS_MAX = 200
function _wt_nonpasses(ts, out = String[])
    for r in ts.results
        if r isa Test.AbstractTestSet
            _wt_nonpasses(r, out)
        elseif r isa Test.Fail || r isa Test.Error
            local at = r.source === nothing ? "?" : "$(relpath(String(something(r.source.file, :?)), dirname(@__DIR__))):$(r.source.line)"
            local what = r isa Test.Error ? first(split(r.value, '\n')) : replace(string(r.orig_expr), '\n' => ' ')
            push!(out, "$at $(r.test_type): $what")
        end
    end
    return out
end
function _wt_why(ts)
    local all = _wt_nonpasses(ts)
    length(all) <= _WT_NONPASS_MAX && return join(all, '\n')
    return join(vcat(all[1:_WT_NONPASS_MAX], ["more:$(length(all) - _WT_NONPASS_MAX) nonpass: not listed"]), '\n')
end
# a file's verdict: red when any of its tests, its nested testsets' included, did not pass (Test.get_test_counts: a nested
# testset's `anynonpass` is set only when the outermost finishes); the canary reads its testsets through this too
function _wt_red(ts)::Bool
    local n = Test.get_test_counts(ts)
    return n.fails + n.errors + n.cumulative_fails + n.cumulative_errors > 0
end
# WT_SRC_STOP names a file the climb's driver makes when a landing waits for the score's lock: the run stops before its
# next file, runs the canary and exits, so every process that wrote records ends with its canary (never killed between
# files), and the driver starts the rest after the landing (dev/climb/measure.py src_run)
const _WT_STOP = get(ENV, "WT_SRC_STOP", "")
# WT_SRC_START names a file the run writes once, when it claims its first file: the G its process has spent until then
# (its start, the load of WasmTarget and the warm-up, at the same measure as a file's cost): a shard's start c0,
# measured, never fitted (the round-13 architect's A13-7; dev/check.sh carries it in the split)
const _WT_START = get(ENV, "WT_SRC_START", "")
const _WT_STARTED = Ref(false)
_WT_MEASURED && let w0 = _wt_instructions(), c0 = _wt_children_cpu()
    WasmTarget.compile(x::Int64 -> x + Int64(1), (Int64,))   # a failure here is a broken pipeline, red
    isempty(get(ENV, "WT_SRC_WARM", "")) || open(io -> println(io, _wt_cost(w0, c0)), ENV["WT_SRC_WARM"], "a")
end
@testset verbose = true "src" begin
    for (i, f) in enumerate(SRC_SHARD)
        !isempty(_WT_STOP) && isfile(_WT_STOP) && break
        # a file another shard claimed is recorded as such (spec v19 Q2, red's round-16 finding 3): dev/src_verdict.sh
        # requires another shard's `started` for it, so a claim no shard ran is red, naming the file
        _wt_claim(f) || (_wt_record("claimed\t$f"); continue)
        if !_WT_STARTED[] && _WT_MEASURED && !isempty(_WT_START)
            _WT_STARTED[] = true
            write(_WT_START, string(_wt_cost(UInt64(0), 0.0), "\n"))
        end
        wt_progress(f)
        _wt_record("started\t$f")
        local i0 = _WT_MEASURED ? _wt_instructions() : UInt64(0)
        local c0 = _wt_children_cpu()
        local ts = @testset "$f" begin include(joinpath(SRC_TEST_DIR, f)) end
        local g = _WT_MEASURED ? _wt_cost(i0, c0) : 0.0
        if !isempty(_WT_RECORDS)   # F's row carries its canary run AS F, after it (spec v17 Z4): passed, or failed
            local why = _wt_why(ts)
            local cok, cwhy = _wt_canary_bound(f)
            _wt_record("row\t$f\t$(_wt_red(ts) ? "failed" : "passed")\t$g\t$(Base64.base64encode(why))\t$(cok ? "passed" : "failed:" * Base64.base64encode(cwhy))")
        end
    end
    if !isempty(_WT_RECORDS)   # the judge's canary, last, through the same record path (test/src_canary.jl)
        local ok, why = _wt_canary_bound()
        _wt_record("started\t~canary")
        _wt_record("row\t~canary\t$(ok ? "passed" : "failed")\t0.0\t$(Base64.base64encode(why))")
    end
end
