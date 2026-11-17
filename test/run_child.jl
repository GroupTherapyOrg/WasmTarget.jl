# ============================================================================
# THE test suite's run of modules (spec v17 Y5), a judge file (dev/climb/core.py JUDGE_READ): a test file under test/src
# that runs modules loads this, never test/runner.jl, so no keeper code runs in a process that writes a src-test record
# (test/src_tests.jl runs many files in one process and records each). A run is the climb's: the calls (test/verdict.jl's
# plan) written in the compile records' grammar, run by test/runner.jl, the keeper's, in a child process of its own
# (`julia test/runner.jl <out> <calls>`, as standalone test/smoke.jl runs it), and its raw lines judged here by the
# judge's verdicts (test/verdict.jl). The binding of an answer to its readers (answer_cases, compiled_case) is the
# judge's and the oracle's, so it lives here too, never in the runner.
#
#   WTChild.run_cases(cases; run_budget, node_start, part_chars) -> Vector{RunResult}
#   WTChild.answer_cases(label, compile, f, args) -> (cases, native), WTChild.compiled_case(label, compile, f, args)
#   WTChild.node_binary() -> the node the runner runs (asked of test/runner.jl in a child: `--node`), or nothing
# ============================================================================
isdefined(Main, :WTVerdict) || Base.include(Main, joinpath(@__DIR__, "verdict.jl"))
module WTChild

import Base64
using ..WTOracle: WTOracle, Throws, Bound, native_answer, answer_of, Answer, _bound, _on_string, _step
using ..WTOracleRead: WTOracleRead, Shape
using ..WTVerdict: WTVerdict, RunCase, RunResult, ReturnsRef, ReturnsAny, Leaves, _pick, RUN_BUDGET

const RUNNER = joinpath(@__DIR__, "runner.jl")
# test/runner.jl's own defaults for a child's start and a part's size (its NODE_START, RUN_PART_CHARS): passed only
# when a test sets them
_opts(run_budget, node_start, part_chars) = String[
    "--run-budget=$run_budget", (node_start === nothing ? String[] : ["--node-start=$node_start"])...,
    (part_chars === nothing ? String[] : ["--part-chars=$part_chars"])...]

"""
    run_cases(cases; run_budget, node_start, part_chars) -> Vector{RunResult}

Every case's modules (both, the wasm-opt'd one beside codegen's) run by test/runner.jl in a child process, and each
judged against its native answer here: the judge's plan, the child's raw lines, the judge's verdicts."""
function run_cases(cases::AbstractVector{RunCase}; run_budget::Float64 = RUN_BUDGET, node_start = nothing,
                   part_chars = nothing)::Vector{RunResult}
    isempty(cases) && return RunResult[]
    local calls, decided = WTVerdict.plan(cases)
    local dir = mktempdir()
    local inp, out = joinpath(dir, "calls.tsv"), joinpath(dir, "raw.tsv")
    open(inp, "w") do io   # each module once, under a label of its own; each call its module's 0th
        local ids = IdDict{Any,Int}()
        for c in calls
            haskey(ids, c.bytes) && continue
            ids[c.bytes] = length(ids)
            println(io, join(("module", "m$(ids[c.bytes])", "-", Base64.base64encode(c.bytes)), '\t'))
        end
        for c in calls
            println(io, join(("call", "m$(ids[c.bytes])", 0, isempty(c.entry) ? "-" : c.entry, c.args...), '\t'))
        end
    end
    local raw = if isempty(calls)
        String[]
    else
        run(pipeline(setenv(`$(Base.julia_cmd()) --startup-file=no $RUNNER $(_opts(run_budget, node_start, part_chars)) $out $inp`,
                            child_env()); stdout = devnull))
        readlines(out)
    end
    rm(dir; recursive = true, force = true)
    return WTVerdict.verdicts(cases, calls, decided, map(WTVerdict.read_raw, raw); run_budget)
end

"""    child_env() -> Dict

The runner child's environment, explicit (spec v18 P2, red round 15 4): this process's without the src-test record's
variables (`WT_SRC_*`) and the progress log (`WT_PROGRESS`), so the child can append to no record of a test file."""
child_env() = Dict(k => v for (k, v) in ENV if !startswith(k, "WT_SRC_") && k != "WT_PROGRESS")

"""    node_binary() -> String or nothing

The node test/runner.jl runs, asked of it in a child (`--node`): its one definition, never loaded here."""
function node_binary()::Union{String,Nothing}
    local p = readchomp(setenv(`$(Base.julia_cmd()) --startup-file=no $RUNNER --node`, child_env()))
    return isempty(p) ? nothing : p
end

"""
    compiled_case(label, compile, f, args; optimized = true) -> RunCase

The case of a program `compile` compiles: codegen's module as the case's own, and the wasm-opt'd one beside it (one
module when the two are the same bytes, or when `optimized` is false), its native answer native_answer's, computed
after both compiles.
"""
function compiled_case(label::String, compile, f, args::Tuple; optimized::Bool = true)::RunCase
    local label′, f′, args′ = _bound(label, f, args)
    local plain, opt = WTVerdict._modules(compile, f′, args′; optimized)
    return RunCase(label′, plain, args′, native_answer(f′, args′); optimized = opt)
end

"""
    answer_cases(label, compile, f, args; optimized = true, own = UInt8[], world) -> (cases, native)

The cases that read `f(args...)`'s answer from wasm, and the native answer they are read against: `f`'s own modules
compiled first (`own` the wasm-opt'd compile the caller already holds), then the answer once (test/oracle.jl's
answer_of; A61S4: a compile reads the session's heap as it stands), then the readers its shape needs (test/verdict.jl's
bind). A known limit: a reader's shape comes from the native value (a vector's length, a String's code units), so for a
program that changes global state the reader starts a step on and the case fails, a false failure, never a false pass.
"""
function answer_cases(label::String, compile, f, args::Tuple; optimized::Bool = true,
                      own::Vector{UInt8} = UInt8[], world::UInt = Base.get_world_counter())::Tuple{Vector{RunCase},Any}
    # a String argument bound as a constant of the program (Bound); the caller's own compile took it as an argument,
    # so it is not the bound program's
    local _, f′, args′ = _bound(label, f, args)
    local modules = WTVerdict._modules(compile, f′, args′; optimized, own = args′ === args ? own : UInt8[])
    local a = answer_of(label, f, args; world)   # the case called at its own world, its answer read at the caller's
    return (WTVerdict.bind(Shape(a), args, compile; a, f, optimized, own = modules, world), a.native)
end

end
