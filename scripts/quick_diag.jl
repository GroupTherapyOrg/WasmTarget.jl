#!/usr/bin/env julia
# quick_diag.jl — PURE-6021d
# Quick diagnosis of known-failing critical path functions

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile) || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(CFG) || (@eval const CFG = Core.Compiler.CFG)
@isdefined(InstructionStream) || (@eval const InstructionStream = Core.Compiler.InstructionStream)
@isdefined(InferenceState) || (@eval const InferenceState = Core.Compiler.InferenceState)

println("=== PURE-6021d: Quick diagnosis of critical path functions ===")
println("Started: $(Dates.now())")
println()

function test_func(label, f, arg_types; show_first_err_line=true)
    print("[$label] ")
    bytes = try
        compile(f, arg_types)
    catch e
        println("COMPILE_ERROR: $(sprint(showerror, e)[1:200])")
        return :compile_error
    end
    println("compiled $(length(bytes)) bytes — ", begin
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        errbuf = IOBuffer()
        ok = false
        try
            run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            ok = true
        catch; end
        if ok
            "VALIDATES ✓"
        else
            err = String(take!(errbuf))
            first_line = split(err, '\n')[1]
            "VALIDATE_ERROR: $(first_line[1:min(150,end)])"
        end
    end)
end

# The critical path functions from eval_julia_critical_path.txt sorted by stmt count
# Only testing the small/medium ones to get quick feedback

println("=== Tier 0: Very small (2-10 stmts) ===")
# 440: parse_comma(ParseState) — 2 stmts
# 434: parse_call_chain(ParseState, ParseStreamPosition) — 2 stmts
# 489: parse_unary_prefix(ParseState) — 2 stmts
# 106: argextype(Any, IRCode, Vector{VarState}) — 5 stmts
# 134: construct_domtree(Vector{BasicBlock}) — 5 stmts
# 475: parse_pair(ParseState) — 6 stmts
# 421: parse_assignment(ParseState, ...) — 7 stmts

test_func("440 parse_comma(ParseState)", JuliaSyntax.parse_comma, (JuliaSyntax.ParseState,))
test_func("434 parse_call_chain", JuliaSyntax.parse_call_chain, (JuliaSyntax.ParseState, JuliaSyntax.ParseStreamPosition))
test_func("489 parse_unary_prefix", JuliaSyntax.parse_unary_prefix, (JuliaSyntax.ParseState,))
test_func("106 argextype", Core.Compiler.argextype, (Any, Core.Compiler.IRCode, Vector{Core.Compiler.VarState}))
test_func("134 construct_domtree", Core.Compiler.construct_domtree, (Vector{Core.Compiler.BasicBlock},))
test_func("475 parse_pair", JuliaSyntax.parse_pair, (JuliaSyntax.ParseState,))
test_func("421 parse_assignment", JuliaSyntax.parse_assignment, (JuliaSyntax.ParseState, typeof(JuliaSyntax.parse_comma)))

println()
println("=== Tier 1: Small (10-25 stmts) ===")
# 12: getindex(Any, Int64) — 15 stmts
# 13: getindex(Any, Any) — 15 stmts
# 24: setindex!(IncrementalCompact, Any, Int64) — 15 stmts
# 9: copy(InstructionStream) — 18 stmts
# 121: compact!(IRCode, Bool) — 21 stmts  (Category D)
# 75: InferenceState(InferenceResult, UInt8, WasmInterpreter) — 23 stmts

test_func("12 getindex(Any,Int64)", Base.getindex, (Any, Int64))
test_func("13 getindex(Any,Any)", Base.getindex, (Any, Any))
test_func("24 setindex!(IC,Any,Int64)", Core.Compiler.setindex!, (Core.Compiler.IncrementalCompact, Any, Int64))
test_func("9 copy(InstructionStream)", Base.copy, (Core.Compiler.InstructionStream,))
test_func("121 compact!(IRCode,Bool)", Core.Compiler.compact!, (Core.Compiler.IRCode, Bool))
test_func("75 InferenceState(IR,UInt8,WI)", Core.Compiler.InferenceState, (Core.Compiler.InferenceResult, UInt8, WasmInterpreter))

println()
println("=== Tier 2: Medium (25-60 stmts) ===")
# 270: non_dce_finish!(IncrementalCompact) — 28 stmts
# 477: parse_public(ParseState) — 30 stmts
# 414-416: parse_RtoL (3 variants) — 34 stmts each
# 481: parse_stmts(ParseState) — 40 stmts

test_func("270 non_dce_finish!(IC)", Core.Compiler.non_dce_finish!, (Core.Compiler.IncrementalCompact,))
test_func("477 parse_public", JuliaSyntax.parse_public, (JuliaSyntax.ParseState,))

println()
println("=== Known Category B (builtin_effects) ===")
# 111: builtin_effects(InferenceLattice, Builtin, Vector{Any}, Any) — Category B
# 112: builtin_effects(PartialsLattice, Builtin, Vector{Any}, Any) — Category B

bl = Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}
pl = Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}

test_func("111 builtin_effects(IL,Builtin,...)", Core.Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
test_func("112 builtin_effects(PL,Builtin,...)", Core.Compiler.builtin_effects, (pl, Core.Builtin, Vector{Any}, Any))

println()
println("Done: $(Dates.now())")
