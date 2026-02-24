#!/usr/bin/env julia
# cp_validate_v2.jl — PURE-6021c Step 2
# Test ALL 112 critical path functions for VALIDATES
# Streamlined: uses WasmTarget module directly, no re-includes

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

# Flush stdout immediately
flush(stdout)

println("=== Critical Path VALIDATES Test v2 ===")
println("Started: $(Dates.now())")
flush(stdout)

# Type aliases for eval'ing arg type strings from manifest
const Compiler = Core.Compiler
const SourceFile = JuliaSyntax.SourceFile

# Load WasmInterpreter (needs dict_method_table.jl)
include(joinpath(@__DIR__, "..", "src", "typeinf", "dict_method_table.jl"))

# These come from dict_method_table.jl's using statement
@isdefined(InferenceState) || (@eval using Core.Compiler: InferenceState)
@isdefined(InferenceResult) || (@eval using Core.Compiler: InferenceResult)

# Read critical path file
cp_file = joinpath(@__DIR__, "eval_julia_critical_path.txt")
entries = []
for line in eachline(cp_file)
    startswith(line, "#") && continue
    isempty(strip(line)) && continue
    parts = split(line, " | ")
    length(parts) >= 7 || continue
    idx = tryparse(Int, strip(parts[1]))
    idx === nothing && continue
    push!(entries, (
        idx=idx,
        mod_str=strip(parts[2]),
        func_str=strip(parts[3]),
        arg_types_str=strip(parts[4]),
        stmt_count=something(tryparse(Int, strip(parts[5])), 0),
    ))
end
sort!(entries, by=e->e.stmt_count)
println("Loaded $(length(entries)) critical path functions")
flush(stdout)

# Module resolution
function resolve_mod(s::AbstractString)
    s == "Main" && return Main
    s == "Base" && return Base
    s == "Core" && return Core
    s == "Compiler" && return Core.Compiler
    s == "JuliaSyntax" && return JuliaSyntax
    startswith(s, "JuliaSyntax") && return JuliaSyntax
    startswith(s, "Base.Compiler") && return Core.Compiler
    # Fallback
    try; return eval(Meta.parse(String(s))); catch; return nothing; end
end

# Resolve function — handle special names
function resolve_func(mod::Module, name::AbstractString)
    sym = Symbol(name)
    # Try direct access
    try; return getfield(mod, sym); catch; end
    # Try alternate modules
    for m in [Base, Core, Core.Compiler, JuliaSyntax, Main]
        try; return getfield(m, sym); catch; end
    end
    return nothing
end

# Resolve arg types from string
function resolve_argtypes(s::AbstractString)
    # Need WasmInterpreter in scope
    try
        # Add needed imports for eval
        t = Main.eval(Meta.parse(s))
        return t isa Tuple ? t : (t,)
    catch ex
        return nothing
    end
end

# Run validation
function run_validates(entries)
    tmpdir = mktempdir()
    n_ok = 0
    n_verr = 0
    n_cerr = 0
    n_rerr = 0
    failures = []

    for (i, e) in enumerate(entries)
        mod = resolve_mod(e.mod_str)
        if mod === nothing
            n_rerr += 1
            push!(failures, (e=e, status=:RESOLVE_FAIL, err="Module: $(e.mod_str)"))
            print("R")
            flush(stdout)
            continue
        end

        f = resolve_func(mod, e.func_str)
        if f === nothing
            n_rerr += 1
            push!(failures, (e=e, status=:RESOLVE_FAIL, err="Func: $(e.func_str)"))
            print("R")
            flush(stdout)
            continue
        end

        argtypes = resolve_argtypes(e.arg_types_str)
        if argtypes === nothing
            n_rerr += 1
            push!(failures, (e=e, status=:RESOLVE_FAIL, err="ArgTypes: $(e.arg_types_str)"))
            print("R")
            flush(stdout)
            continue
        end

        # Compile
        bytes = try
            compile(f, argtypes)
        catch ex
            n_cerr += 1
            msg = sprint(showerror, ex)[1:min(200,end)]
            push!(failures, (e=e, status=:COMPILE_ERROR, err=msg))
            print("C")
            flush(stdout)
            continue
        end

        # Validate
        tmpf = joinpath(tmpdir, "func_$(e.idx).wasm")
        write(tmpf, bytes)

        errbuf = IOBuffer()
        ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            ok = true
        catch; end

        if ok
            n_ok += 1
            print(".")
        else
            n_verr += 1
            err_msg = String(take!(errbuf))
            first_line = split(err_msg, '\n')[1]
            push!(failures, (e=e, status=:VALIDATE_ERROR, err=first_line))
            print("V")
        end
        flush(stdout)
        i % 20 == 0 && println(" ($i/$(length(entries)))")
    end
    println()
    println()

    # Summary
    total = length(entries)
    println("=== RESULTS ($(Dates.now())) ===")
    println("  VALIDATES:      $n_ok / $total ($(round(100*n_ok/total, digits=1))%)")
    println("  VALIDATE_ERROR: $n_verr")
    println("  COMPILE_ERROR:  $n_cerr")
    println("  RESOLVE_FAIL:   $n_rerr")
    println()

    if !isempty(failures)
        println("=== FAILURES (sorted by stmt count) ===")
        for f in failures
            println("  [$(f.e.idx)] $(f.e.func_str) ($(f.e.stmt_count) stmts) — $(f.status)")
            println("    $(f.err[1:min(120,end)])")
        end
    end

    rm(tmpdir; recursive=true, force=true)
    flush(stdout)
    return (n_ok=n_ok, n_verr=n_verr, n_cerr=n_cerr, n_rerr=n_rerr, failures=failures)
end

results = run_validates(entries)
println("\nDone: $(Dates.now())")
