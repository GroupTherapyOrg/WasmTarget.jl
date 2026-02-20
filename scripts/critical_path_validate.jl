#!/usr/bin/env julia
# critical_path_validate.jl — PURE-6021d
#
# Compile ONLY the 112 critical path functions individually and check VALIDATES.
# Uses manifest file (with string arg types) to avoid slow discover_dependencies.
#
# testCommand: julia +1.12 --project=. scripts/critical_path_validate.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

# Set up type aliases needed for eval()
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# These aliases are needed to eval the arg_types_str from the manifest
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(SourceFile) || (@eval const SourceFile = JuliaSyntax.SourceFile)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(CFG) || (@eval const CFG = Core.Compiler.CFG)
@isdefined(InstructionStream) || (@eval const InstructionStream = Core.Compiler.InstructionStream)
@isdefined(InferenceState) || (@eval const InferenceState = Core.Compiler.InferenceState)

println("=== PURE-6021d: Critical path VALIDATES test ===")
println("Started: $(Dates.now())")
println()

# Step 1: Load critical path indices
cp_file = joinpath(@__DIR__, "eval_julia_critical_path.txt")
critical_entries = NamedTuple[]  # (idx, mod, func, arg_types_str, stmt_count, profile_count)
for line in eachline(cp_file)
    startswith(line, "#") && continue
    isempty(strip(line)) && continue
    parts = split(line, " | ")
    length(parts) >= 7 || continue
    idx = tryparse(Int, strip(parts[1]))
    idx === nothing && continue
    push!(critical_entries, (
        idx=idx,
        mod=strip(parts[2]),
        func=strip(parts[3]),
        arg_types_str=strip(parts[4]),
        stmt_count=tryparse(Int, strip(parts[5])) |> x -> something(x, 0),
        profile_count=tryparse(Int, strip(parts[7])) |> x -> something(x, 0)
    ))
end
println("Critical path: $(length(critical_entries)) functions")

# Sort by stmt count ascending (simplest first)
sort!(critical_entries, by=e->e.stmt_count)
println("Sorted by stmt_count — first: $(critical_entries[1].func) ($(critical_entries[1].stmt_count) stmts)")
println("                         last: $(critical_entries[end].func) ($(critical_entries[end].stmt_count) stmts)")
println()

# Step 2: Resolve and compile each
function resolve_entry(e)
    # Resolve module
    mod = try
        m = Meta.parse(e.mod)
        eval(m)
    catch ex
        return nothing, "ModuleResolve: $(sprint(showerror, ex)[1:100])"
    end
    mod isa Module || return nothing, "Not a module: $(e.mod)"

    # Resolve function
    f = try
        getfield(mod, Symbol(e.func))
    catch ex
        # Try alternate locations
        result = nothing
        for m2 in [Base, Core, Core.Compiler, JuliaSyntax, Main]
            try
                result = getfield(m2, Symbol(e.func))
                break
            catch; end
        end
        if result === nothing
            return nothing, "FuncResolve: $(sprint(showerror, ex)[1:100])"
        end
        result
    end

    # Resolve arg types
    arg_types = try
        t = eval(Meta.parse(e.arg_types_str))
        t isa Tuple ? t : (t,)
    catch ex
        return nothing, "ArgTypes: $(sprint(showerror, ex)[1:100])"
    end

    return (func=f, arg_types=arg_types), nothing
end

tmpdir = mktempdir()

n_validates = 0
n_validate_err = 0
n_compile_err = 0
n_resolve_fail = 0

all_results = NamedTuple[]

for (i, e) in enumerate(critical_entries)
    entry_obj, resolve_err = resolve_entry(e)

    if entry_obj === nothing
        n_resolve_fail += 1
        push!(all_results, (idx=e.idx, func=e.func, stmt_count=e.stmt_count,
                            status=:RESOLVE_FAIL, error=resolve_err))
        print("R")
        i % 20 == 0 && println()
        continue
    end

    # Compile
    bytes = try
        compile(entry_obj.func, entry_obj.arg_types)
    catch ex
        n_compile_err += 1
        msg = sprint(showerror, ex)[1:min(200,end)]
        push!(all_results, (idx=e.idx, func=e.func, stmt_count=e.stmt_count,
                            status=:COMPILE_ERROR, error=msg))
        print("C")
        i % 20 == 0 && println()
        continue
    end

    # Validate
    tmpf = joinpath(tmpdir, "func_$(e.idx).wasm")
    write(tmpf, bytes)

    errbuf = IOBuffer()
    validate_ok = false
    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        validate_ok = true
    catch; end

    if validate_ok
        n_validates += 1
        push!(all_results, (idx=e.idx, func=e.func, stmt_count=e.stmt_count,
                            status=:VALIDATES, error=""))
        print(".")
    else
        err_msg = String(take!(errbuf))
        n_validate_err += 1
        push!(all_results, (idx=e.idx, func=e.func, stmt_count=e.stmt_count,
                            status=:VALIDATE_ERROR, error=err_msg[1:min(300,end)]))
        print("V")
    end
    i % 20 == 0 && println()
end
println()
println()

# Results summary
total = n_validates + n_validate_err + n_compile_err + n_resolve_fail
println("=== CRITICAL PATH RESULTS ($(Dates.now())) ===")
println("  VALIDATES:      $n_validates / $(length(critical_entries))")
println("  VALIDATE_ERROR: $n_validate_err")
println("  COMPILE_ERROR:  $n_compile_err")
println("  RESOLVE_FAIL:   $n_resolve_fail")
println()

# Show failures
failures = filter(r -> r.status != :VALIDATES, all_results)

if !isempty(failures)
    println("=== FAILURES ===")
    for r in failures
        println("  [$(r.idx)] $(r.func) ($(r.stmt_count) stmts) — $(r.status)")
        if !isempty(r.error)
            # Just show first line of error
            first_line = split(r.error, '\n')[1]
            println("    $(first_line[1:min(150,end)])")
        end
    end
    println()

    # Group by status and first error word
    by_cat = Dict{String,Int}()
    for r in failures
        cat = string(r.status) * "/" * split(r.error, [' ', '\n', ':'])[1]
        by_cat[cat] = get(by_cat, cat, 0) + 1
    end
    println("Error categories:")
    for (cat, cnt) in sort(collect(by_cat), by=x->-x[2])
        println("  $(cnt)x $(cat)")
    end
end

rm(tmpdir; recursive=true, force=true)
println()
println("Done: $(Dates.now())")
