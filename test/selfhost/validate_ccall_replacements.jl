# PHASE-2-PREP-003: Validate Category A ccall replacements compile to WasmGC individually
#
# Run: julia +1.12 --project=. test/selfhost/validate_ccall_replacements.jl
#
# For each key override function in ccall_replacements.jl:
#   1. Get code_typed with concrete arg types
#   2. Attempt compile_from_codeinfo
#   3. Record success/failure
#
# This is the critical feasibility gate — if these can't compile, Phase 2a is blocked.

using WasmTarget
using JSON, Dates

# Load stubs + replacements
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "ccall_replacements.jl"))

println("=" ^ 70)
println("PHASE-2-PREP-003: Validate ccall replacements compile to WasmGC")
println("=" ^ 70)

# ─── Test infrastructure ────────────────────────────────────────────────────

struct CompileResult
    name::String
    phase::String
    arg_types::String
    code_typed_ok::Bool
    code_typed_error::String
    compile_ok::Bool
    compile_error::String
    wasm_size::Int  # bytes, 0 if failed
end

results = CompileResult[]

function try_compile_function(name::String, phase::String, @nospecialize(f), @nospecialize(argtypes::Tuple))
    arg_str = string(argtypes)
    println("\n--- Testing: $name ($phase) ---")
    println("  Args: $arg_str")

    # Step 1: Get code_typed
    ci = nothing
    ct_ok = false
    ct_err = ""
    try
        ct = Base.code_typed(f, argtypes; optimize=true)
        if isempty(ct)
            ct_err = "code_typed returned empty"
        else
            ci = ct[1][1]
            ct_ok = true
            println("  code_typed: OK ($(length(ci.code)) statements)")
        end
    catch e
        ct_err = sprint(showerror, e)
        println("  code_typed: FAIL — $(first(ct_err, 100))")
    end

    # Step 2: Try compile_from_codeinfo
    comp_ok = false
    comp_err = ""
    wasm_size = 0
    if ct_ok && ci !== nothing
        try
            ret_type = Base.code_typed(f, argtypes; optimize=true)[1][2]
            bytes = WasmTarget.compile_from_codeinfo(ci, ret_type, name, argtypes)
            wasm_size = length(bytes)
            comp_ok = true
            println("  compile: OK ($wasm_size bytes)")
        catch e
            comp_err = sprint(showerror, e)
            println("  compile: FAIL — $(first(comp_err, 150))")
        end
    elseif !ct_ok
        comp_err = "skipped (code_typed failed)"
        println("  compile: SKIPPED")
    end

    result = CompileResult(name, phase, arg_str, ct_ok, ct_err, comp_ok, comp_err, wasm_size)
    push!(results, result)
    return result
end

# ─── Phase B1: IdDict operations ────────────────────────────────────────────
println("\n" * "=" ^ 70)
println("Phase B1: IdDict / eqtable operations")
println("=" ^ 70)

# _pure_eqtable_get — core function, uses Memory{Any}
# Can't easily test directly (Memory{Any} is internal), test via IdDict wrappers

# Base.haskey(::IdDict, key) — most commonly used
try_compile_function("haskey_iddict", "B1",
    Base.haskey, (IdDict{Any,Any}, Int64))

# ─── Phase B2: Type operations ──────────────────────────────────────────────
println("\n" * "=" ^ 70)
println("Phase B2: Type operations")
println("=" ^ 70)

# _fieldindex_nothrow — scan fieldnames
try_compile_function("fieldindex_nothrow", "B2",
    Base._fieldindex_nothrow, (DataType, Symbol))

# _fieldindex_maythrow — scan fieldnames (throws on failure)
try_compile_function("fieldindex_maythrow", "B2",
    Base._fieldindex_maythrow, (DataType, Symbol))

# datatype_fieldtypes — access T.types
try_compile_function("datatype_fieldtypes", "B2",
    Base.datatype_fieldtypes, (DataType,))

# allocatedinline — isbitstype check
try_compile_function("allocatedinline", "B2",
    Base.allocatedinline, (Type,))

# argument_datatype — recursive UnionAll unwrap
try_compile_function("argument_datatype", "B2",
    Base.argument_datatype, (Type,))

# ─── Phase C1: Type variable helpers ────────────────────────────────────────
println("\n" * "=" ^ 70)
println("Phase C1: Type variable helpers")
println("=" ^ 70)

# has_free_typevars_pure — recursive type walk
try_compile_function("has_free_typevars_pure", "C1",
    has_free_typevars_pure, (Type,))

# Also try with the two-arg form (with bound set)
try_compile_function("has_free_typevars_pure_2arg", "C1",
    has_free_typevars_pure, (Type, Set{TypeVar}))

# Base.has_free_typevars — wrapper
try_compile_function("has_free_typevars", "C1",
    Base.has_free_typevars, (Type,))

# instantiate_type_in_env_pure — type substitution
try_compile_function("instantiate_type_in_env_pure", "C1",
    instantiate_type_in_env_pure, (Type, Type, Vector{Any}))

# ─── Phase C2: IdSet operations ─────────────────────────────────────────────
println("\n" * "=" ^ 70)
println("Phase C2: IdSet operations")
println("=" ^ 70)

# _idset_peek_bp — linear scan
try_compile_function("idset_peek_bp", "C2",
    _idset_peek_bp, (Memory{Any}, Any, Int))

# haskey(::IdSet, key)
try_compile_function("haskey_idset", "C2",
    Base.haskey, (IdSet, Any))

# push!(::IdSet, key)
try_compile_function("push_idset", "C2",
    Base.push!, (IdSet, Any))

# _pop!(::IdSet, key)
try_compile_function("pop_idset", "C2",
    Base._pop!, (IdSet, Any))

# ─── Phase B3: IR inspection ────────────────────────────────────────────────
println("\n" * "=" ^ 70)
println("Phase B3: IR inspection")
println("=" ^ 70)

# ast_slotflag — CodeInfo field access
try_compile_function("ast_slotflag", "B3",
    Base.ast_slotflag, (Core.CodeInfo, Int))

# ─── Summary ────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 70)
println("SUMMARY")
println("=" ^ 70)

n_total = length(results)
n_ct_ok = count(r -> r.code_typed_ok, results)
n_comp_ok = count(r -> r.compile_ok, results)

println("  Total functions tested: $n_total")
println("  code_typed OK: $n_ct_ok / $n_total")
println("  compile OK:    $n_comp_ok / $n_total")
println()

println("─── Results Table ───")
println(rpad("Name", 35) * rpad("Phase", 8) * rpad("code_typed", 12) * rpad("compile", 12) * "size")
println("─" ^ 75)
for r in results
    ct_status = r.code_typed_ok ? "OK" : "FAIL"
    comp_status = r.compile_ok ? "OK" : "FAIL"
    size_str = r.wasm_size > 0 ? "$(r.wasm_size)B" : "-"
    println(rpad(r.name, 35) * rpad(r.phase, 8) * rpad(ct_status, 12) * rpad(comp_status, 12) * size_str)
end

# Print failures with error details
failures = filter(r -> !r.compile_ok, results)
if !isempty(failures)
    println("\n─── Failure Details ───")
    for r in failures
        println("\n  $(r.name) ($(r.phase)):")
        if !r.code_typed_ok
            println("    code_typed error: $(first(r.code_typed_error, 200))")
        else
            println("    compile error: $(first(r.compile_error, 200))")
        end
    end
end

# ─── Save results ───────────────────────────────────────────────────────────
output = Dict(
    "story" => "PHASE-2-PREP-003",
    "timestamp" => string(Dates.now()),
    "total_functions" => n_total,
    "code_typed_ok" => n_ct_ok,
    "compile_ok" => n_comp_ok,
    "results" => [Dict(
        "name" => r.name,
        "phase" => r.phase,
        "arg_types" => r.arg_types,
        "code_typed_ok" => r.code_typed_ok,
        "code_typed_error" => r.code_typed_error,
        "compile_ok" => r.compile_ok,
        "compile_error" => first(r.compile_error, 300),
        "wasm_size" => r.wasm_size
    ) for r in results]
)

output_path = joinpath(@__DIR__, "ccall_replacement_results.json")
open(output_path, "w") do io
    JSON.print(io, output, 2)
end
println("\nResults saved to $output_path")

# Acceptance criteria: report N of total that compile successfully
println("\n=== ACCEPTANCE: $n_comp_ok of $n_total functions compile successfully ===")
if !isempty(failures)
    println("=== BLOCKERS: $(length(failures)) functions failed ===")
end
