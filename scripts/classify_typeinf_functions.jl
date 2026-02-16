#!/usr/bin/env julia
#
# PURE-3001: Classify each typeinf function
#
# For each of the 99 "pure Julia" functions from PURE-3000's audit:
#   - Attempt WasmTarget.compile(f, argtypes)
#   - If compiles + validates → COMPILES_NOW
#   - If fails with stubs/pattern errors but no ccall → NEEDS_PATTERN
#   - Otherwise → note the error
#
# For the 70 "has_ccall" functions:
#   - Already classified as C_DEPENDENT
#   - Document what each ccall does and replacement strategy
#
# For the 2 optimizer functions:
#   - Already classified as OPTIMIZER_SKIP
#
# Output: scripts/typeinf_classification.md (updated with compilation results)
#
# Usage: julia +1.12 --project=WasmTarget.jl WasmTarget.jl/scripts/classify_typeinf_functions.jl

using JSON
using WasmTarget
using Core.Compiler

# Read dependency graph
graph_path = joinpath(@__DIR__, "typeinf_dependency_graph.json")
graph = JSON.parsefile(graph_path)

# Results tracking
results = Dict{String, Vector{Dict{String, Any}}}(
    "COMPILES_NOW" => [],
    "NEEDS_PATTERN" => [],
    "C_DEPENDENT" => [],
    "OPTIMIZER_SKIP" => [],
    "COMPILE_ERROR" => [],  # temporary — will be reclassified
)

# ============================================================================
# Helper: resolve function from name + module
# ============================================================================

function resolve_function(name::String, mod_name::String)
    mod = if mod_name == "Compiler"
        Core.Compiler
    elseif mod_name == "Base"
        Base
    elseif mod_name == "Core"
        Core
    elseif mod_name == "Base.MPFR"
        Base.MPFR
    else
        nothing
    end
    mod === nothing && return nothing

    # Try to find the function by name
    sym = Symbol(name)
    try
        if isdefined(mod, sym)
            return getfield(mod, sym)
        end
    catch
    end

    # Try generated function names like #argtypes_to_type##0
    if startswith(name, "#")
        # These are generated closures/kwfuncs — harder to resolve
        return nothing
    end

    return nothing
end

# ============================================================================
# Helper: parse signature string to actual types
# ============================================================================

function parse_signature(sig_str::String)
    # sig_str looks like "Tuple{Int64, Any, Core.SimpleVector}"
    # We need to eval it in the right context
    try
        types = Core.eval(Main, Meta.parse(sig_str))
        if types isa Type && types <: Tuple
            return fieldtypes(types)
        end
    catch e
        # Try with Compiler module context
        try
            # Replace "Compiler." with "Core.Compiler."
            fixed = replace(sig_str, r"\bCompiler\." => "Core.Compiler.")
            types = Core.eval(Main, Meta.parse(fixed))
            if types isa Type && types <: Tuple
                return fieldtypes(types)
            end
        catch
        end
    end
    return nothing
end

# ============================================================================
# Attempt compilation of a single function
# ============================================================================

function try_compile(f, argtypes::Tuple)
    local bytes
    local stubs = String[]
    local errors = String[]

    try
        # Capture warnings (stubs) by redirecting stderr
        old_stderr = stderr
        err_buf = IOBuffer()

        # Just try compilation directly
        bytes = WasmTarget.compile(f, argtypes)

        if bytes === nothing || isempty(bytes)
            return (status=:error, bytes=nothing, msg="compile returned nothing/empty")
        end

        # Write to temp file and validate
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)

        # Validate with wasm-tools
        validate_result = try
            result = read(`wasm-tools validate $tmpf`, String)
            true
        catch e
            if e isa ProcessFailedException
                err_msg = try
                    read(pipeline(`wasm-tools validate $tmpf`, stderr=stdout), String)
                catch
                    "validation failed"
                end
                false
            else
                false
            end
        end

        # Count functions
        func_count = try
            output = read(`wasm-tools print $tmpf`, String)
            count("(func ", output)
        catch
            -1
        end

        rm(tmpf, force=true)

        if validate_result
            return (status=:compiles_now, bytes=length(bytes), func_count=func_count, msg="VALIDATES")
        else
            return (status=:needs_pattern, bytes=length(bytes), func_count=func_count, msg="compiles but validation fails")
        end

    catch e
        msg = sprint(showerror, e)
        # Truncate long error messages
        if length(msg) > 200
            msg = msg[1:200] * "..."
        end

        # Classify error type
        if contains(msg, "Stubbing") || contains(msg, "stub")
            return (status=:needs_pattern, bytes=nothing, msg="has stubs: $msg")
        elseif contains(msg, "foreigncall") || contains(msg, "ccall")
            return (status=:c_dependent, bytes=nothing, msg="has ccall: $msg")
        else
            return (status=:error, bytes=nothing, msg=msg)
        end
    end
end

# ============================================================================
# Process pure Julia functions
# ============================================================================

println("="^60)
println("PURE-3001: Classifying typeinf functions")
println("="^60)

pure_funcs = graph["functions"]["pure_julia"]
println("\nProcessing $(length(pure_funcs)) pure Julia functions...")

for (i, entry) in enumerate(pure_funcs)
    name = entry["name"]
    mod_name = entry["module"]
    sig_str = entry["signature"]
    n_stmts = entry["n_statements"]

    print("[$i/$(length(pure_funcs))] $mod_name.$name ... ")

    # Resolve function
    f = resolve_function(name, mod_name)
    if f === nothing
        println("SKIP (cannot resolve)")
        push!(results["COMPILE_ERROR"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "status" => "cannot_resolve",
            "error" => "Function not found in module",
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
        continue
    end

    # Parse signature to get argument types
    argtypes = parse_signature(sig_str)
    if argtypes === nothing
        println("SKIP (cannot parse signature: $sig_str)")
        push!(results["COMPILE_ERROR"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "status" => "cannot_parse_sig",
            "error" => "Cannot parse signature: $sig_str",
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
        continue
    end

    # Attempt compilation
    result = try_compile(f, argtypes)

    if result.status == :compiles_now
        println("COMPILES_NOW ($(result.func_count) funcs, $(result.bytes) bytes)")
        push!(results["COMPILES_NOW"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "func_count" => result.func_count,
            "bytes" => result.bytes,
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
    elseif result.status == :needs_pattern
        println("NEEDS_PATTERN — $(result.msg)")
        push!(results["NEEDS_PATTERN"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "error" => result.msg,
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
    elseif result.status == :c_dependent
        println("C_DEPENDENT — $(result.msg)")
        push!(results["C_DEPENDENT"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "error" => result.msg,
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
    else
        println("ERROR — $(result.msg)")
        push!(results["COMPILE_ERROR"], Dict(
            "name" => name, "module" => mod_name, "signature" => sig_str,
            "n_statements" => n_stmts, "status" => "compile_error",
            "error" => result.msg,
            "file" => get(entry, "file", "?"),
            "line" => get(entry, "line", 0)
        ))
    end
end

# ============================================================================
# Add C_DEPENDENT functions from the audit (the 70 has_ccall functions)
# ============================================================================

println("\nAdding $(length(graph["functions"]["has_ccall"])) C-dependent functions from audit...")

for entry in graph["functions"]["has_ccall"]
    push!(results["C_DEPENDENT"], Dict(
        "name" => entry["name"],
        "module" => entry["module"],
        "signature" => entry["signature"],
        "n_statements" => entry["n_statements"],
        "ccalls" => entry["ccalls"],
        "file" => get(entry, "file", "?"),
        "line" => get(entry, "line", 0),
        "from_audit" => true  # pre-classified by PURE-3000
    ))
end

# ============================================================================
# Add optimizer skip functions
# ============================================================================

for entry in graph["functions"]["optimizer_skip"]
    push!(results["OPTIMIZER_SKIP"], Dict(
        "name" => entry["name"],
        "module" => entry["module"],
        "signature" => entry["signature"],
        "n_statements" => entry["n_statements"],
        "file" => get(entry, "file", "?"),
        "line" => get(entry, "line", 0)
    ))
end

# ============================================================================
# Summary
# ============================================================================

println("\n" * "="^60)
println("CLASSIFICATION RESULTS")
println("="^60)
println("COMPILES_NOW:   $(length(results["COMPILES_NOW"]))")
println("NEEDS_PATTERN:  $(length(results["NEEDS_PATTERN"]))")
println("C_DEPENDENT:    $(length(results["C_DEPENDENT"]))")
println("OPTIMIZER_SKIP: $(length(results["OPTIMIZER_SKIP"]))")
println("COMPILE_ERROR:  $(length(results["COMPILE_ERROR"]))")
total = sum(length(v) for v in values(results))
println("TOTAL:          $total")

# ============================================================================
# Write JSON results
# ============================================================================

json_path = joinpath(@__DIR__, "typeinf_classification_results.json")
open(json_path, "w") do io
    JSON.print(io, results, 2)
end
println("\nJSON results written to: $json_path")

# ============================================================================
# Write Markdown classification document
# ============================================================================

md_path = joinpath(@__DIR__, "typeinf_classification.md")
open(md_path, "w") do io
    println(io, "# Core.Compiler.typeinf Function Classification (PURE-3001)")
    println(io)
    println(io, "**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`")
    println(io, "**Date:** 2026-02-15")
    println(io, "**Method:** For each function from PURE-3000's dependency graph:")
    println(io, "- Pure Julia functions: attempt `WasmTarget.compile(f, argtypes)` + `wasm-tools validate`")
    println(io, "- C-dependent: pre-classified by ccall analysis")
    println(io, "- Optimizer: pre-classified by name (Binaryen handles optimization)")
    println(io)

    # Summary table
    println(io, "## Summary")
    println(io)
    println(io, "| Category | Count | Description |")
    println(io, "|----------|-------|-------------|")
    println(io, "| **COMPILES_NOW** | **$(length(results["COMPILES_NOW"]))** | Pure Julia, compiles + validates |")
    println(io, "| **NEEDS_PATTERN** | **$(length(results["NEEDS_PATTERN"]))** | Has stubs/validation errors, needs codegen fixes |")
    println(io, "| **C_DEPENDENT** | **$(length(results["C_DEPENDENT"]))** | Has ccalls that need pure Julia replacement |")
    println(io, "| **OPTIMIZER_SKIP** | **$(length(results["OPTIMIZER_SKIP"]))** | Only for optimization — Binaryen handles this |")
    println(io, "| **COMPILE_ERROR** | **$(length(results["COMPILE_ERROR"]))** | Cannot resolve function/signature |")
    println(io, "| **Total** | **$total** | |")
    println(io)

    # COMPILES_NOW section
    println(io, "## COMPILES_NOW ($(length(results["COMPILES_NOW"])))")
    println(io)
    println(io, "These compile to Wasm and validate. Ready for compilation into typeinf module.")
    println(io)
    if !isempty(results["COMPILES_NOW"])
        println(io, "| # | Function | Module | Stmts | Funcs | Bytes | File |")
        println(io, "|---|----------|--------|-------|-------|-------|------|")
        for (i, entry) in enumerate(sort(results["COMPILES_NOW"], by=x->x["name"]))
            func_count = get(entry, "func_count", "?")
            bytes = get(entry, "bytes", "?")
            println(io, "| $i | `$(entry["name"])` | $(entry["module"]) | $(entry["n_statements"]) | $func_count | $bytes | $(get(entry, "file", "?")):$(get(entry, "line", "?")) |")
        end
    end
    println(io)

    # NEEDS_PATTERN section
    println(io, "## NEEDS_PATTERN ($(length(results["NEEDS_PATTERN"])))")
    println(io)
    println(io, "These have stubs or validation errors but no C calls. Need codegen fixes.")
    println(io)
    if !isempty(results["NEEDS_PATTERN"])
        println(io, "| # | Function | Module | Stmts | Error | File |")
        println(io, "|---|----------|--------|-------|-------|------|")
        for (i, entry) in enumerate(sort(results["NEEDS_PATTERN"], by=x->x["name"]))
            err_msg = get(entry, "error", "?")
            # Truncate for table
            if length(err_msg) > 80
                err_msg = err_msg[1:80] * "..."
            end
            println(io, "| $i | `$(entry["name"])` | $(entry["module"]) | $(entry["n_statements"]) | $(err_msg) | $(get(entry, "file", "?")):$(get(entry, "line", "?")) |")
        end
    end
    println(io)

    # C_DEPENDENT section
    println(io, "## C_DEPENDENT ($(length(results["C_DEPENDENT"])))")
    println(io)
    println(io, "These contain foreigncalls and need pure Julia replacements.")
    println(io)

    # Group by ccall type for strategy documentation
    ccall_groups = Dict{String, Vector{String}}()
    for entry in results["C_DEPENDENT"]
        ccalls = get(entry, "ccalls", String[])
        for c in ccalls
            if !haskey(ccall_groups, c)
                ccall_groups[c] = String[]
            end
            push!(ccall_groups[c], entry["name"])
        end
    end

    println(io, "### C Calls by Category")
    println(io)

    # Strategy documentation for each ccall
    ccall_strategies = Dict(
        # Method table (THE key C wall)
        "jl_matching_methods" => ("Method dispatch lookup", "DictMethodTable — Dict{Type, MethodLookupResult} pre-populated at build time", "HIGH"),
        "jl_gf_invoke_lookup_worlds" => ("Method invoke lookup", "DictMethodTable — same Dict, different lookup path", "HIGH"),

        # Type system core (BIGGEST challenge)
        "jl_type_intersection" => ("Compute T1 ∩ T2 (type intersection)", "Pre-compute at build time for known types, or implement subset of typeintersect in pure Julia", "HIGH — ~1000 lines of C in subtype.c"),
        "jl_type_intersection_with_env" => ("Type intersection + capture environment", "Same strategy as jl_type_intersection", "HIGH"),
        "jl_type_unionall" => ("Construct UnionAll type", "Pure Julia: UnionAll(tvar, body) — this is just struct construction", "LOW — simple constructor"),
        "jl_has_free_typevars" => ("Check if type has free type variables", "Pure Julia: recursive walk of type structure, check for unbound TypeVar", "MEDIUM — tree walk"),
        "jl_find_free_typevars" => ("Find all free type variables in a type", "Pure Julia: recursive walk collecting unbound TypeVars", "MEDIUM — tree walk"),
        "jl_instantiate_type_in_env" => ("Substitute type variables with values", "Pure Julia: recursive type substitution", "MEDIUM"),
        "jl_types_equal" => ("Check T1 === T2 (type equality)", "Pure Julia: T1 === T2 (Julia's === already works for types)", "LOW — trivial"),
        "jl_field_index" => ("Get field index by name in a DataType", "Pure Julia: findfirst(==(name), fieldnames(T))", "LOW — simple lookup"),
        "jl_get_fieldtypes" => ("Get field types of a DataType", "Pure Julia: fieldtypes(T)", "LOW — already a Julia function"),
        "jl_stored_inline" => ("Check if field is stored inline", "Pure Julia: isprimitivetype or check DataType.layout", "LOW"),
        "jl_argument_datatype" => ("Get DataType from argument type", "Pure Julia: unwrap type wrappers to get DataType", "LOW"),

        # String operations
        "jl_alloc_string" => ("Allocate a new String of given length", "Wasm string handling — use WasmTarget string intrinsics", "MEDIUM"),
        "jl_string_to_genericmemory" => ("Convert String to Memory{UInt8}", "Wasm: extract string bytes into memory buffer", "MEDIUM"),
        "jl_genericmemory_to_string" => ("Convert Memory{UInt8} to String", "Wasm: construct string from memory buffer bytes", "MEDIUM"),
        "jl_pchar_to_string" => ("Convert C char* to Julia String", "Wasm: string construction from pointer — may need stub", "MEDIUM"),
        "jl_string_ptr" => ("Get pointer to string data", "SKIP — only used for debug/timing output", "SKIP"),

        # Memory operations
        "jl_genericmemory_copyto" => ("Copy memory block", "Wasm: memory.copy instruction", "LOW — existing Wasm instruction"),
        "memcmp" => ("Compare memory blocks", "Wasm: byte-by-byte comparison loop", "LOW"),
        "memmove" => ("Move memory block (overlapping)", "Wasm: memory.copy instruction", "LOW"),
        "memset" => ("Fill memory with byte value", "Wasm: memory.fill instruction", "LOW"),

        # Timing/debug (SKIP)
        "jl_hrtime" => ("High-resolution timer", "SKIP — only used for timing/profiling", "SKIP"),
        "jl_uv_puts" => ("Write string to UV stream", "SKIP — only used for debug output", "SKIP"),
        "jl_uv_putb" => ("Write byte to UV stream", "SKIP — only used for debug output", "SKIP"),

        # Cache management (SKIP for single-shot typeinf)
        "jl_fill_codeinst" => ("Fill CodeInstance cache entry", "SKIP — cache management, not needed for single-shot typeinf", "SKIP"),
        "jl_promote_ci_to_current" => ("Promote CodeInstance to current world", "SKIP — cache management", "SKIP"),
        "jl_promote_cis_to_current" => ("Promote CodeInstances to current world", "SKIP — cache management", "SKIP"),
        "jl_rettype_inferred" => ("Get inferred return type from cache", "DictMethodTable — pre-compute at build time", "MEDIUM"),
        "jl_push_newly_inferred" => ("Push to newly-inferred worklist", "SKIP — JIT compilation management", "SKIP"),
        "jl_mi_cache_insert" => ("Insert into MethodInstance cache", "SKIP — cache management", "SKIP"),

        # Method resolution
        "jl_normalize_to_compilable_sig" => ("Normalize method signature for compilation", "DictMethodTable — pre-normalized at build time", "MEDIUM"),
        "jl_specializations_get_linfo" => ("Get MethodInstance for specialization", "DictMethodTable — pre-resolved at build time", "MEDIUM"),

        # World age
        "jl_get_world_counter" => ("Get current world age counter", "Return build-time constant", "LOW — trivial"),
        "jl_get_module_infer" => ("Get module's inference flag", "Return constant (true)", "LOW — trivial"),

        # Engine management
        "jl_engine_reserve" => ("Reserve inference engine slot", "SKIP — JIT engine management", "SKIP"),
        "jl_engine_fulfill" => ("Fulfill inference engine reservation", "SKIP — JIT engine management", "SKIP"),

        # Staged/generated functions
        "jl_code_for_staged" => ("Get code for @generated function", "Pre-expand at build time", "HIGH"),
        "jl_value_ptr" => ("Get raw pointer to Julia value", "SKIP/stub — only for identity comparison", "LOW"),

        # IdSet operations
        "jl_idset_peek_bp" => ("Peek at IdSet backpointer", "Pure Julia: Dict/Set equivalent lookup", "MEDIUM"),
        "jl_idset_pop" => ("Pop from IdSet", "Pure Julia: Dict/Set equivalent pop", "MEDIUM"),
        "jl_idset_put_key" => ("Insert key into IdSet", "Pure Julia: Dict/Set equivalent insert", "MEDIUM"),
        "jl_idset_put_idx" => ("Insert at index into IdSet", "Pure Julia: Dict/Set equivalent insert", "MEDIUM"),

        # Assertions
        "jl_is_assertsbuild" => ("Check if assertions enabled in build", "Return constant (false)", "LOW — trivial"),

        # Other
        "jl_module_globalref" => ("Get GlobalRef from module", "Pre-resolve at build time", "MEDIUM"),
        "jl_new_structv" => ("Construct struct from values", "Wasm: struct_new instruction", "LOW — codegen already handles this"),
        "jl_new_structt" => ("Construct struct from tuple", "Wasm: struct_new instruction", "LOW"),
        "jl_eqtable_get" => ("Get from equality-based table", "Pure Julia: Dict lookup", "LOW"),
        "jl_rethrow" => ("Rethrow current exception", "Wasm: rethrow instruction", "LOW"),

        # MPFR (arbitrary precision)
        "Core.tuple(:mpfr_greater_p, Base.MPFR.libmpfr)" => ("BigFloat comparison", "SKIP — only for timer comparison, can stub", "SKIP"),

        # IR introspection
        "jl_ir_nslots" => ("Get number of slots in IR", "Pre-compute at build time", "LOW"),
        "jl_ir_slotflag" => ("Get slot flags in IR", "Pre-compute at build time", "LOW"),
    )

    println(io, "| C Call | Purpose | Pure Julia Replacement | Complexity | Used By |")
    println(io, "|--------|---------|----------------------|------------|---------|")
    for (ccall_name, funcs) in sort(collect(ccall_groups), by=first)
        strategy = get(ccall_strategies, ccall_name, ("?", "Investigate", "?"))
        func_list = join(sort(unique(funcs)), ", ")
        if length(func_list) > 60
            func_list = func_list[1:60] * "..."
        end
        println(io, "| `$ccall_name` | $(strategy[1]) | $(strategy[2]) | $(strategy[3]) | $func_list |")
    end
    println(io)

    # Complexity grouping
    println(io, "### Replacement Complexity Summary")
    println(io)
    skip_count = count(v -> v[3] == "SKIP", values(ccall_strategies))
    low_count = count(v -> startswith(v[3], "LOW"), values(ccall_strategies))
    med_count = count(v -> startswith(v[3], "MEDIUM"), values(ccall_strategies))
    high_count = count(v -> startswith(v[3], "HIGH"), values(ccall_strategies))
    println(io, "| Complexity | Count | Strategy |")
    println(io, "|------------|-------|----------|")
    println(io, "| **SKIP** | $skip_count | Strip/stub — not needed for single-shot typeinf |")
    println(io, "| **LOW** | $low_count | Trivial replacement — constants, simple lookups |")
    println(io, "| **MEDIUM** | $med_count | Moderate — tree walks, Dict operations, string ops |")
    println(io, "| **HIGH** | $high_count | Significant — type intersection, method tables, generated functions |")
    println(io)

    # Full C_DEPENDENT function table
    println(io, "### All C_DEPENDENT Functions")
    println(io)
    println(io, "| # | Function | Module | Stmts | C Calls | File |")
    println(io, "|---|----------|--------|-------|---------|------|")
    for (i, entry) in enumerate(sort(results["C_DEPENDENT"], by=x->x["name"]))
        ccalls = get(entry, "ccalls", String[])
        ccall_str = join(ccalls, ", ")
        if length(ccall_str) > 60
            ccall_str = ccall_str[1:60] * "..."
        end
        println(io, "| $i | `$(entry["name"])` | $(entry["module"]) | $(entry["n_statements"]) | $ccall_str | $(get(entry, "file", "?")):$(get(entry, "line", "?")) |")
    end
    println(io)

    # OPTIMIZER_SKIP section
    println(io, "## OPTIMIZER_SKIP ($(length(results["OPTIMIZER_SKIP"])))")
    println(io)
    println(io, "Binaryen handles optimization. These are not compiled to Wasm.")
    println(io)
    println(io, "| # | Function | Module | Stmts | File |")
    println(io, "|---|----------|--------|-------|------|")
    for (i, entry) in enumerate(results["OPTIMIZER_SKIP"])
        println(io, "| $i | `$(entry["name"])` | $(entry["module"]) | $(entry["n_statements"]) | $(get(entry, "file", "?")):$(get(entry, "line", "?")) |")
    end
    println(io)

    # COMPILE_ERROR section
    if !isempty(results["COMPILE_ERROR"])
        println(io, "## COMPILE_ERROR ($(length(results["COMPILE_ERROR"])))")
        println(io)
        println(io, "Cannot resolve function or parse signature. Needs manual investigation.")
        println(io)
        println(io, "| # | Function | Module | Signature | Error | File |")
        println(io, "|---|----------|--------|-----------|-------|------|")
        for (i, entry) in enumerate(sort(results["COMPILE_ERROR"], by=x->x["name"]))
            err = get(entry, "error", "?")
            if length(err) > 60
                err = err[1:60] * "..."
            end
            println(io, "| $i | `$(entry["name"])` | $(entry["module"]) | `$(entry["signature"])` | $err | $(get(entry, "file", "?")):$(get(entry, "line", "?")) |")
        end
    end
    println(io)

    # Recommendations section
    println(io, "## Recommendations for PURE-3002 (DictMethodTable Build)")
    println(io)
    println(io, "### Priority Order for C Call Replacement")
    println(io)
    println(io, "1. **SKIP calls (strip/stub):** jl_hrtime, jl_uv_puts, jl_string_ptr, jl_fill_codeinst,")
    println(io, "   jl_promote_ci_to_current, jl_engine_reserve/fulfill, jl_mi_cache_insert,")
    println(io, "   jl_push_newly_inferred — these are timer/debug/cache management, not needed for typeinf")
    println(io)
    println(io, "2. **LOW complexity:** jl_get_world_counter (constant), jl_types_equal (===),")
    println(io, "   jl_type_unionall (constructor), jl_field_index (findfirst), memcmp/memmove/memset (Wasm ops)")
    println(io)
    println(io, "3. **MEDIUM complexity:** jl_has_free_typevars (tree walk), jl_instantiate_type_in_env (substitution),")
    println(io, "   IdSet operations (Dict equivalent), string operations (Wasm string intrinsics)")
    println(io)
    println(io, "4. **HIGH complexity (THE blockers):**")
    println(io, "   - `jl_matching_methods` — DictMethodTable (THE architectural change)")
    println(io, "   - `jl_type_intersection` — ~1000 lines of C in subtype.c, need subset or pre-compute")
    println(io, "   - `jl_code_for_staged` — @generated function expansion, pre-expand at build time")
    println(io)
    println(io, "### Key Architecture Decision")
    println(io)
    println(io, "For the \"1+1\" playground use case, the type system operations are limited:")
    println(io, "- `+(Int64, Int64)` — intersection with `Tuple{Int64, Int64}` is just itself")
    println(io, "- `sin(Float64)` — intersection with `Tuple{Float64}` is just itself")
    println(io)
    println(io, "**Strategy: Pre-compute ALL type intersections at build time.**")
    println(io, "For each method in DictMethodTable, pre-compute and store the intersection result.")
    println(io, "The Dict key IS the answer — no runtime intersection needed for known types.")
    println(io)
    println(io, "This means `jl_type_intersection` can return a pre-computed result from the Dict,")
    println(io, "rather than implementing the full intersection algorithm.")
    println(io)
end

println("\nMarkdown classification written to: $md_path")
println("\nDone!")
