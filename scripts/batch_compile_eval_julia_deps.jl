#!/usr/bin/env julia
# batch_compile_eval_julia_deps.jl — PURE-6019
#
# For each function in the eval_julia_to_bytes dependency tree,
# compile it individually and record the result.
#
# Results: VALIDATES / COMPILE_ERROR / VALIDATE_ERROR
# Grouped by error category: BoundsError, MethodError, TypeError,
#                             UndefVarError, AssertionError, Other
#
# testCommand: julia +1.12 --project=. scripts/batch_compile_eval_julia_deps.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

# Load typeinf (required for eval_julia_to_bytes)
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
# Load eval_julia_to_bytes
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== PURE-6019: Batch compile eval_julia_to_bytes deps ===")
println("Started: $(Dates.now())")
println()

# ── Step 1: Discover all transitive dependencies ──────────────────────────────
println("Step 1: Running discover_dependencies...")
seed = [(eval_julia_to_bytes, (String,))]
all_funcs = WasmTarget.discover_dependencies(seed)
println("  Found $(length(all_funcs)) functions")
println()

# Sort by module then name for deterministic ordering
function func_sort_key(entry)
    f, arg_types, name = entry
    mod_name = try string(parentmodule(f)) catch; "?" end
    return (mod_name, name)
end
sorted_funcs = sort(all_funcs; by=func_sort_key)

# ── Classify error helpers ────────────────────────────────────────────────────

function classify_compile_error(e)
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

# ── Step 2: Compile each function individually ────────────────────────────────

mutable struct CompileResult
    idx::Int
    mod_name::String
    func_name::String
    arg_types_str::String
    status::Symbol  # :VALIDATES, :VALIDATE_ERROR, :COMPILE_ERROR
    error_type::String  # BoundsError, MethodError, TypeError, UndefVarError, AssertionError, Other
    error_msg::String
    bytes::Int
end

results = CompileResult[]

# Temp dir for .wasm files
tmpdir = mktempdir()

println("Step 2: Compiling $(length(sorted_funcs)) functions individually...")
println("  (each function compiled as a standalone module)")
println()

n_validates = Ref(0)
n_validate_err = Ref(0)
n_compile_err = Ref(0)

function run_batch!(results, sorted_funcs, tmpdir, n_validates, n_validate_err, n_compile_err)
    for (idx, (f, arg_types, name)) in enumerate(sorted_funcs)
        mod_name = try string(parentmodule(f)) catch; "Unknown" end
        arg_str = "(" * join([string(t) for t in arg_types], ", ") * ")"

        if idx % 50 == 1
            println("  Progress: $idx/$(length(sorted_funcs)) — validates=$(n_validates[]), compile_err=$(n_compile_err[]), validate_err=$(n_validate_err[])")
        end

        # Try to compile
        status = :COMPILE_ERROR
        err_type = "Other"
        err_msg = ""
        nbytes = 0

        try
            bytes = compile(f, arg_types)
            nbytes = length(bytes)

            # Write to temp file and validate
            tmpf = joinpath(tmpdir, "func_$(idx).wasm")
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

        catch ce
            status = :COMPILE_ERROR
            err_msg = sprint(showerror, ce)
            err_type = classify_compile_error(ce)
            n_compile_err[] += 1
        end

        push!(results, CompileResult(idx, mod_name, name, arg_str, status, err_type, err_msg, nbytes))
    end
end

run_batch!(results, sorted_funcs, tmpdir, n_validates, n_validate_err, n_compile_err)

# ── Step 3: Build failure catalog ─────────────────────────────────────────────
println()
println("=== RESULTS SUMMARY ===")
println("  VALIDATES:      $(n_validates[]) / $(length(sorted_funcs))")
println("  COMPILE_ERROR:  $(n_compile_err[]) / $(length(sorted_funcs))")
println("  VALIDATE_ERROR: $(n_validate_err[]) / $(length(sorted_funcs))")
println()

# Group failures by error type
failures = filter(r -> r.status != :VALIDATES, results)

by_err_type = Dict{String, Vector{CompileResult}}()
for r in failures
    key = "$(r.status)/$(r.error_type)"
    push!(get!(by_err_type, key, CompileResult[]), r)
end

println("=== FAILURE CATALOG (grouped by error category) ===")
println()

# Sort by count descending
sorted_cats = sort(collect(by_err_type); by=x->-length(x[2]))

for (cat, items) in sorted_cats
    println("── $cat ($(length(items)) functions) ──")
    # Show first 5 examples
    for r in items[1:min(5, end)]
        short_err = length(r.error_msg) > 120 ? r.error_msg[1:120] * "..." : r.error_msg
        println("  [$(r.idx)] $(r.mod_name).$(r.func_name)$(r.arg_types_str)")
        println("    Error: $short_err")
    end
    if length(items) > 5
        println("  ... and $(length(items) - 5) more")
    end
    println()
end

# ── Step 4: Write full results to output file ──────────────────────────────────
outfile = joinpath(@__DIR__, "batch_compile_results.txt")
open(outfile, "w") do io
    println(io, "# PURE-6019: Batch compile results for eval_julia_to_bytes deps")
    println(io, "# Generated: $(Dates.now())")
    println(io, "# Total: $(length(sorted_funcs)) functions")
    println(io, "# VALIDATES: $n_validates, COMPILE_ERROR: $n_compile_err, VALIDATE_ERROR: $n_validate_err")
    println(io, "#")
    println(io, "# Format: STATUS | ERROR_TYPE | MODULE | FUNCTION | ARG_TYPES | ERROR_MSG")
    println(io, "")

    for r in results
        short_err = replace(r.error_msg, "\n" => " ")
        short_err = length(short_err) > 200 ? short_err[1:200] : short_err
        println(io, "$(r.status) | $(r.error_type) | $(r.mod_name) | $(r.func_name) | $(r.arg_types_str) | $short_err")
    end

    println(io, "")
    println(io, "# === BY CATEGORY ===")
    for (cat, items) in sorted_cats
        println(io, "# $cat: $(length(items))")
        for r in items
            short_err = replace(r.error_msg, "\n" => " ")
            short_err = length(short_err) > 200 ? short_err[1:200] : short_err
            println(io, "#   [$(r.idx)] $(r.mod_name).$(r.func_name)$(r.arg_types_str)")
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
println("### $(Dates.today()): PURE-6019 [DONE] — Batch compile $(length(sorted_funcs)) eval_julia deps")
println()
println("| Category | Count |")
println("|----------|-------|")
println("| VALIDATES | $(n_validates[]) |")
println("| COMPILE_ERROR (total) | $(n_compile_err[]) |")
println("| VALIDATE_ERROR (total) | $(n_validate_err[]) |")
println()
for (cat, items) in sorted_cats
    println("| $cat | $(length(items)) |")
end
println()
println("Top failures by module:")
# Count failures by module
mod_failures = Dict{String, Int}()
for r in failures
    mod_failures[r.mod_name] = get(mod_failures, r.mod_name, 0) + 1
end
for (mod, cnt) in sort(collect(mod_failures); by=x->-x[2])[1:min(10, end)]
    println("  $mod: $cnt failures")
end
