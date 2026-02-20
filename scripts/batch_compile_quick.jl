#!/usr/bin/env julia
# batch_compile_quick.jl — PURE-6019 quick sample (30 funcs, 15s timeout)
#
# Runs the first 30 functions from eval_julia_manifest.txt to get
# initial error categories fast (~5-10 min max).
#
# testCommand: julia +1.12 --project=. scripts/batch_compile_quick.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6019: Quick sample batch compile (30 funcs) ===")
println("Started: $(Dates.now())")
println()

@isdefined(Compiler)          || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile)        || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange)        || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult)   || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode)            || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(CFG)               || (@eval const CFG = Core.Compiler.CFG)
@isdefined(InstructionStream) || (@eval const InstructionStream = Core.Compiler.InstructionStream)
@isdefined(CodeInfo)          || (@eval const CodeInfo = Core.CodeInfo)
@isdefined(MethodInstance)    || (@eval const MethodInstance = Core.MethodInstance)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

println("Manifest: $(length(data_lines)) total functions, testing first 30")
println()

function classify_error(e)
    if e isa BoundsError; return "BoundsError"
    elseif e isa MethodError; return "MethodError"
    elseif e isa TypeError; return "TypeError"
    elseif e isa UndefVarError; return "UndefVarError"
    elseif e isa AssertionError; return "AssertionError"
    elseif e isa ArgumentError; return "ArgumentError"
    elseif e isa ErrorException; return "ErrorException"
    else return string(typeof(e))
    end
end

function resolve_func_entry(line)
    parts = split(line, " | ")
    length(parts) < 4 && return nothing
    idx = Base.parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    mod = try eval(Meta.parse(mod_name)) catch e; return nothing end
    mod isa Module || return nothing
    func = try getfield(mod, Symbol(func_name)) catch e; return nothing end
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch e; return nothing end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

MAX_FUNCS = 30
TIMEOUT_SECS = 15.0

n_compiles = 0; n_err = 0; n_resolve = 0; n_timeout = 0
err_cats = Dict{String, Vector{String}}()

for (loop_idx, line) in enumerate(data_lines[1:MAX_FUNCS])
    entry = resolve_func_entry(line)
    if isnothing(entry)
        global n_resolve += 1
        println("[$loop_idx] RESOLVE_FAIL: $line")
        continue
    end

    arg_str = "(" * join([string(t) for t in entry.arg_types], ", ") * ")"
    print("[$loop_idx] $(entry.mod).$(entry.name)$arg_str ... ")
    flush(stdout)

    t_start = time()
    compile_task = Threads.@spawn compile(entry.func, entry.arg_types)
    wait_result = timedwait(() -> istaskdone(compile_task), TIMEOUT_SECS)

    if wait_result == :timed_out
        global n_timeout += 1
        println("TIMEOUT (>$(TIMEOUT_SECS)s)")
        push!(get!(err_cats, "TIMEOUT", String[]), "$(entry.mod).$(entry.name)")
    else
        try
            bytes = fetch(compile_task)
            elapsed = round(time() - t_start, digits=2)
            global n_compiles += 1
            println("COMPILES ($(length(bytes)) bytes, $(elapsed)s)")
        catch e
            global n_err += 1
            elapsed = round(time() - t_start, digits=2)
            cat = classify_error(e)
            msg = sprint(showerror, e)
            short = length(msg) > 120 ? msg[1:120] * "..." : msg
            println("COMPILE_ERROR/$cat ($(elapsed)s)")
            println("    $short")
            push!(get!(err_cats, cat, String[]), "$(entry.mod).$(entry.name)")
        end
    end
    flush(stdout)
end

println()
println("=== QUICK SAMPLE RESULTS (first $MAX_FUNCS funcs) ===")
println("  COMPILES:      $n_compiles / $MAX_FUNCS")
println("  COMPILE_ERROR: $n_err / $MAX_FUNCS")
println("  RESOLVE_FAIL:  $n_resolve / $MAX_FUNCS")
println("  TIMEOUT:       $n_timeout / $MAX_FUNCS")
println()
println("Error categories:")
for (cat, funcs) in sort(collect(err_cats), by=x->-length(x[2]))
    println("  $cat: $(length(funcs)) — $(join(funcs[1:min(3,end)], ", "))")
end
println()
println("Done: $(Dates.now())")
