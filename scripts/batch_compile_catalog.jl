#!/usr/bin/env julia
# batch_compile_catalog.jl — PURE-6019 targeted catalog
#
# Compiles first 420 functions (fast range) individually with VALIDATE=false.
# Prints per-function result so we know WHICH functions fail.
# This gets us the full compile error catalog without wasm-tools validation.
#
# testCommand: julia +1.12 --project=. scripts/batch_compile_catalog.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6019 catalog: per-function compile-only (first 420) ===")
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
    mod = try eval(Meta.parse(mod_name)) catch; return nothing end
    mod isa Module || return nothing
    func = try getfield(mod, Symbol(func_name)) catch; return nothing end
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch; return nothing end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

MAX_FUNCS = min(420, length(data_lines))
TIMEOUT_SECS = 20.0

compile_errs = Tuple{Int,String,String,String}[]  # (idx, mod, name, error)
validates = Int[]
timeouts = Int[]
resolve_fails = Int[]

println("Testing $MAX_FUNCS functions (compile-only, $(TIMEOUT_SECS)s timeout)...")
println()

n_ok = 0; n_err = 0; n_to = 0; n_rf = 0

for (loop_idx, line) in enumerate(data_lines[1:MAX_FUNCS])
    entry = resolve_func_entry(line)
    if isnothing(entry)
        global n_rf += 1
        println("[$loop_idx] RESOLVE_FAIL: $(split(line, " | ")[2:3])")
        push!(resolve_fails, loop_idx)
        continue
    end

    arg_str = "(" * join([string(t) for t in entry.arg_types], ", ") * ")"

    compile_task = Threads.@spawn compile(entry.func, entry.arg_types)
    wait_result = timedwait(() -> istaskdone(compile_task), TIMEOUT_SECS)

    if wait_result == :timed_out
        global n_to += 1
        push!(timeouts, loop_idx)
        println("[$loop_idx] TIMEOUT — $(entry.mod).$(entry.name)")
    else
        try
            bytes = fetch(compile_task)
            global n_ok += 1
            push!(validates, loop_idx)
            # Suppress individual COMPILES — they're OK
        catch e
            global n_err += 1
            cat = classify_error(e)
            msg = sprint(showerror, e)
            short = length(msg) > 200 ? msg[1:200] * "..." : msg
            push!(compile_errs, (loop_idx, entry.mod, entry.name, "$cat: $short"))
            println("[$loop_idx] COMPILE_ERROR/$cat — $(entry.mod).$(entry.name)$arg_str")
            println("    $(length(msg) > 200 ? msg[1:200] * "..." : msg)")
        end
    end
    flush(stdout)
end

println()
println("=== COMPILE ERROR CATALOG (first $MAX_FUNCS funcs) ===")
println("  COMPILES:     $n_ok / $MAX_FUNCS")
println("  COMPILE_ERR:  $n_err / $MAX_FUNCS")
println("  TIMEOUT:      $n_to / $MAX_FUNCS")
println("  RESOLVE_FAIL: $n_rf / $MAX_FUNCS")
println()

if !isempty(compile_errs)
    # Group by error category
    by_cat = Dict{String,Vector{Tuple{Int,String,String}}}()
    for (idx, mod, name, err) in compile_errs
        cat = split(err, ":")[1]
        push!(get!(by_cat, cat, []), (idx, mod, name))
    end
    println("Grouped compile errors:")
    for (cat, items) in sort(collect(by_cat), by=x->-length(x[2]))
        println("  $cat: $(length(items)) functions")
        for (i, mod, name) in items
            println("    [$i] $mod.$name")
        end
    end
    println()
    println("Full error messages:")
    for (idx, mod, name, err) in compile_errs
        println("[$idx] $mod.$name")
        println("  $err")
        println()
    end
end

# Save to file
outfile = joinpath(@__DIR__, "batch_catalog_results.txt")
open(outfile, "w") do io
    println(io, "# PURE-6019: Compile-only catalog — first $MAX_FUNCS functions")
    println(io, "# Generated: $(Dates.now())")
    println(io, "# COMPILES: $n_ok, COMPILE_ERR: $n_err, TIMEOUT: $n_to, RESOLVE_FAIL: $n_rf")
    println(io, "#")
    for (idx, mod, name, err) in compile_errs
        println(io, "COMPILE_ERROR | $idx | $mod | $name | $err")
    end
    for idx in timeouts
        println(io, "TIMEOUT | $idx")
    end
end
println("Results saved to: $outfile")
println("Done: $(Dates.now())")
