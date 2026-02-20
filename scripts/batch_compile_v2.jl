#!/usr/bin/env julia
# batch_compile_v2.jl — PURE-6019 (faster version)
#
# Reads eval_julia_manifest.txt directly — no discover_dependencies call.
# Resolves function references via getfield/eval, compiles each individually.
# Uses per-function timeout to avoid hangs.
#
# testCommand: julia +1.12 --project=. scripts/batch_compile_v2.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

# Load typeinf (defines WasmInterpreter, InferenceResult, etc.)
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6019 v2: Batch compile from manifest (no rediscovery) ===")
println("Started: $(Dates.now())")
println()

# Create module aliases so type strings like "Compiler.IRCode" resolve
# In Julia 1.12, Core.Compiler is the compiler module
const Compiler = Core.Compiler
const SourceFile = JuliaSyntax.SourceFile
const InternalCodeCache = Core.Compiler.InternalCodeCache
const WorldRange = Core.Compiler.WorldRange
const InferenceResult = Core.Compiler.InferenceResult
const IRCode = Core.Compiler.IRCode
const CFG = Core.Compiler.CFG
const InstructionStream = Core.Compiler.InstructionStream
const CodeInfo = Core.CodeInfo
const MethodInstance = Core.MethodInstance

# ── Read manifest ─────────────────────────────────────────────────────────────

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

println("Manifest: $(length(data_lines)) functions")
println()

# ── Error classification ──────────────────────────────────────────────────────

function classify_error(e)
    if e isa BoundsError
        return "BoundsError"
    elseif e isa MethodError
        return "MethodError"
    elseif e isa TypeError
        return "TypeError"
    elseif e isa UndefVarError
        return "UndefVarError"
    elseif e isa AssertionError
        return "AssertionError"
    elseif e isa ArgumentError
        return "ArgumentError"
    elseif e isa ErrorException
        return "ErrorException"
    else
        return string(typeof(e))
    end
end

function classify_validate_error(msg)
    msg_lower = lowercase(msg)
    if contains(msg_lower, "expected i32") || contains(msg_lower, "expected i64") ||
       contains(msg_lower, "expected f64") || contains(msg_lower, "type mismatch") ||
       contains(msg_lower, "values remaining on stack") || contains(msg_lower, "expected [")
        return "StackTypeError"
    elseif contains(msg_lower, "unknown type") || contains(msg_lower, "unknown struct")
        return "UnknownType"
    elseif contains(msg_lower, "invalid")
        return "InvalidInstruction"
    else
        return "ValidationOther"
    end
end

# ── Resolve function from manifest line ───────────────────────────────────────

function resolve_func_entry(line)
    parts = split(line, " | ")
    length(parts) < 4 && return nothing

    idx = parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])

    # Resolve the module
    mod = try
        eval(Meta.parse(mod_name))
    catch e
        return nothing
    end

    mod isa Module || return nothing

    # Resolve the function
    func = try
        getfield(mod, Symbol(func_name))
    catch e
        return nothing
    end

    # Parse arg types — all types must be in scope
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch e
        return nothing
    end

    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

# ── Compile each function ─────────────────────────────────────────────────────

mutable struct Result
    idx::Int
    mod::String
    name::String
    arg_types_str::String
    status::Symbol   # :COMPILES, :COMPILE_ERROR, :VALIDATES, :VALIDATE_ERROR, :RESOLVE_FAIL, :TIMEOUT
    error_type::String
    error_msg::String
    bytes::Int
end

results = Result[]
n_compiles = Ref(0)
n_compile_err = Ref(0)
n_validates = Ref(0)
n_validate_err = Ref(0)
n_resolve_fail = Ref(0)
n_timeout = Ref(0)

tmpdir = mktempdir()

# Process ALL functions from manifest (or set MAX_FUNCS to limit)
MAX_FUNCS = length(data_lines)  # Test all 542
VALIDATE = false  # Skip wasm-tools validate for speed (just test compile())

println("Compiling $MAX_FUNCS functions (VALIDATE=$VALIDATE)...")
println()

for (loop_idx, line) in enumerate(data_lines[1:MAX_FUNCS])
    if loop_idx % 50 == 1
        println("Progress: $loop_idx/$MAX_FUNCS — compiles=$(n_compiles[]), compile_err=$(n_compile_err[]), " *
                "validates=$(n_validates[]), validate_err=$(n_validate_err[]), " *
                "resolve_fail=$(n_resolve_fail[]), timeout=$(n_timeout[])")
        flush(stdout)
    end

    entry = resolve_func_entry(line)

    if isnothing(entry)
        n_resolve_fail[] += 1
        parts = split(line, " | ")
        push!(results, Result(
            loop_idx,
            length(parts) >= 2 ? strip(parts[2]) : "?",
            length(parts) >= 3 ? strip(parts[3]) : "?",
            length(parts) >= 4 ? strip(parts[4]) : "?",
            :RESOLVE_FAIL, "ParseError", "Could not resolve module/function/types", 0
        ))
        continue
    end

    status = :COMPILE_ERROR
    err_type = "Other"
    err_msg = ""
    nbytes = 0

    # Try compile directly (no timeout — if a function hangs, kill it externally)
    try
        bytes = compile(entry.func, entry.arg_types)
        nbytes = length(bytes)

        if VALIDATE
            tmpf = joinpath(tmpdir, "func_$(loop_idx).wasm")
            write(tmpf, bytes)

            errbuf = IOBuffer()
            validate_ok = false
            try
                run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
                validate_ok = true
            catch; end

            if validate_ok
                status = :VALIDATES
                n_validates[] += 1
            else
                status = :VALIDATE_ERROR
                err_msg = String(take!(errbuf))
                err_type = classify_validate_error(err_msg)
                n_validate_err[] += 1
            end
        else
            status = :COMPILES
            n_compiles[] += 1
        end
    catch e
        status = :COMPILE_ERROR
        err_msg = sprint(showerror, e)
        err_type = classify_error(e)
        n_compile_err[] += 1
    end

    arg_str = "(" * join([string(t) for t in entry.arg_types], ", ") * ")"
    push!(results, Result(entry.idx, entry.mod, entry.name, arg_str, status, err_type, err_msg, nbytes))
end

# ── Summary ───────────────────────────────────────────────────────────────────

println()
println("=== RESULTS SUMMARY ===")
println("  Total tested:   $(length(results))")
println("  VALIDATES:      $(n_validates[]) / $(length(results))")
println("  VALIDATE_ERROR: $(n_validate_err[]) / $(length(results))")
println("  COMPILES (no validate): $(n_compiles[])")
println("  COMPILE_ERROR:  $(n_compile_err[]) / $(length(results))")
println("  RESOLVE_FAIL:   $(n_resolve_fail[]) / $(length(results))")
println("  TIMEOUT:        $(n_timeout[]) / $(length(results))")
println()

failures = filter(r -> r.status in (:COMPILE_ERROR, :VALIDATE_ERROR, :RESOLVE_FAIL, :TIMEOUT), results)

by_err_type = Dict{String, Vector{Result}}()
for r in failures
    key = "$(r.status)/$(r.error_type)"
    push!(get!(by_err_type, key, Result[]), r)
end

println("=== FAILURE CATALOG (grouped by category) ===")
println()

sorted_cats = sort(collect(by_err_type); by=x->-length(x[2]))

for (cat, items) in sorted_cats
    println("── $cat ($(length(items)) functions) ──")
    for r in items[1:min(5, end)]
        short_err = length(r.error_msg) > 150 ? r.error_msg[1:150] * "..." : r.error_msg
        println("  [$(r.idx)] $(r.mod).$(r.name)$(r.arg_types_str)")
        println("    $(short_err)")
    end
    if length(items) > 5
        println("  ... and $(length(items) - 5) more")
    end
    println()
end

# ── Write full results ─────────────────────────────────────────────────────────

outfile = joinpath(@__DIR__, "batch_compile_results.txt")
open(outfile, "w") do io
    println(io, "# PURE-6019: Batch compile results for eval_julia_to_bytes deps")
    println(io, "# Generated: $(Dates.now())")
    println(io, "# Total tested: $(length(results))")
    println(io, "# VALIDATES: $(n_validates[]), VALIDATE_ERROR: $(n_validate_err[])")
    println(io, "# COMPILE_ERROR: $(n_compile_err[]), RESOLVE_FAIL: $(n_resolve_fail[]), TIMEOUT: $(n_timeout[])")
    println(io, "#")
    println(io, "# Format: STATUS | ERROR_TYPE | MODULE | FUNCTION | ARG_TYPES | ERROR_MSG")
    println(io, "")

    for r in results
        short_err = replace(r.error_msg, "\n" => " ")
        short_err = length(short_err) > 200 ? short_err[1:200] : short_err
        println(io, "$(r.status) | $(r.error_type) | $(r.mod) | $(r.name) | $(r.arg_types_str) | $short_err")
    end

    println(io, "")
    println(io, "# === BY CATEGORY ===")
    for (cat, items) in sorted_cats
        println(io, "# $cat: $(length(items))")
        for r in items
            short_err = replace(r.error_msg, "\n" => " ")
            short_err = length(short_err) > 200 ? short_err[1:200] : short_err
            println(io, "#   [$(r.idx)] $(r.mod).$(r.name)")
            println(io, "#     $short_err")
        end
    end
end

println("Full results written to: $outfile")
println()
println("Done: $(Dates.now())")
println()
println("=== PASTE THIS INTO progress.md ===")
println()
println("| Category | Count |")
println("|----------|-------|")
println("| VALIDATES | $(n_validates[]) |")
println("| VALIDATE_ERROR | $(n_validate_err[]) |")
println("| COMPILES (no validate) | $(n_compiles[]) |")
println("| COMPILE_ERROR | $(n_compile_err[]) |")
println("| RESOLVE_FAIL | $(n_resolve_fail[]) |")
println("| TIMEOUT | $(n_timeout[]) |")
println()
for (cat, items) in sorted_cats
    println("| $cat | $(length(items)) |")
end
