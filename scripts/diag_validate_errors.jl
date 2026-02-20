#!/usr/bin/env julia
# diag_validate_errors.jl — PURE-6021
#
# Quick diagnostic: compile first 150 functions from manifest,
# show VALIDATE_ERROR messages in full so we can identify patterns.
# Timeout=20s per function, skip TIMEOUTs silently.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6021: Diagnose validate errors (first 150 funcs) ===")
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

println("Manifest: $(length(data_lines)) functions — testing first 150")
println()

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

function run_diag(data_lines, MAX_FUNCS)
    tmpdir = mktempdir()
    TIMEOUT_SECS = 20.0

    n_validates = Ref(0)
    n_validate_err = Ref(0)
    n_compile_err = Ref(0)
    n_timeout = Ref(0)
    n_resolve_fail = Ref(0)

    validate_errors = Tuple{Int,String,String,String}[]
    compile_errors = Tuple{Int,String,String,String}[]

    for (loop_idx, line) in enumerate(data_lines[1:MAX_FUNCS])
        if loop_idx % 25 == 1
            println("  Progress $loop_idx/$MAX_FUNCS: V=$(n_validates[]) VE=$(n_validate_err[]) CE=$(n_compile_err[]) TO=$(n_timeout[])")
            flush(stdout)
        end

        entry = resolve_func_entry(line)
        if isnothing(entry)
            n_resolve_fail[] += 1
            continue
        end

        compile_task = Threads.@spawn compile(entry.func, entry.arg_types)
        wait_result = timedwait(() -> istaskdone(compile_task), TIMEOUT_SECS)

        if wait_result == :timed_out
            n_timeout[] += 1
            continue
        end

        bytes = nothing
        try
            bytes = fetch(compile_task)
        catch e
            n_compile_err[] += 1
            push!(compile_errors, (entry.idx, entry.mod, entry.name, sprint(showerror, e)))
            continue
        end

        tmpf = joinpath(tmpdir, "func_$(loop_idx).wasm")
        write(tmpf, bytes)

        errbuf = IOBuffer()
        validate_ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            validate_ok = true
        catch; end

        if validate_ok
            n_validates[] += 1
        else
            n_validate_err[] += 1
            push!(validate_errors, (entry.idx, entry.mod, entry.name, String(take!(errbuf))))
        end
    end

    return (
        n_validates=n_validates[],
        n_validate_err=n_validate_err[],
        n_compile_err=n_compile_err[],
        n_timeout=n_timeout[],
        n_resolve_fail=n_resolve_fail[],
        validate_errors=validate_errors,
        compile_errors=compile_errors
    )
end

MAX_FUNCS = min(150, length(data_lines))
r = run_diag(data_lines, MAX_FUNCS)

println()
println("=== RESULTS (first $MAX_FUNCS functions) ===")
println("  VALIDATES:      $(r.n_validates)")
println("  VALIDATE_ERROR: $(r.n_validate_err)")
println("  COMPILE_ERROR:  $(r.n_compile_err)")
println("  TIMEOUT:        $(r.n_timeout)")
println("  RESOLVE_FAIL:   $(r.n_resolve_fail)")
println()

println("=== COMPILE ERRORS ===")
for (idx, mod, name, msg) in r.compile_errors
    println("[$idx] $mod.$name")
    short = length(msg) > 400 ? msg[1:400] * "..." : msg
    println("  $short")
    println()
end

println("=== VALIDATE ERRORS (full messages) ===")
for (idx, mod, name, msg) in r.validate_errors
    println("[$idx] $mod.$name")
    println(msg)
    println("────")
end

println()
println("Done: $(Dates.now())")
