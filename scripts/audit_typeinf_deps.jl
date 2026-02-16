#!/usr/bin/env julia
#
# PURE-3000: Audit Core.Compiler.typeinf Dependency Graph
#
# Walk typeinf's FULL call graph via code_typed, but SKIP optimizer functions.
# For every function typeinf calls:
# 1. Record: function name, module, number of statements
# 2. Classify: pure Julia / has ccall / optimizer function (SKIP)
# 3. Flag C walls: jl_matching_methods, jl_gf_invoke_lookup_worlds, jl_uncompress_ir
# 4. Record AbstractInterpreter interface methods
# 5. Record any other ccalls/foreigncalls
#
# Output:
#   scripts/typeinf_dependency_graph.json
#   scripts/typeinf_classification.md
#
# Usage: julia +1.12 --project=WasmTarget.jl WasmTarget.jl/scripts/audit_typeinf_deps.jl

using JSON
using Core.Compiler

# ============================================================================
# Optimizer function patterns — these are SKIPPED (Binaryen handles optimization)
# ============================================================================

const OPTIMIZER_PREFIXES = [
    "ssa_inlining_pass",
    "inline_cost",
    "can_inline",
    "assm_inline",
    "resolve_todo",
    "analyze_method!",
    "inlining_policy",
    "process_simple!",
    "ir_inline",
    "batch_inline!",
    "linear_inline_eligible",
    "early_inline_special_case",
    "late_inline_special_case",
    "handle_single_case!",
    "is_valid_type_for_apply_rewrite",
    # Constant propagation
    "const_prop",
    "semi_concrete_eval",
    "concrete_eval",
    # Dead code elimination
    "adce_pass!",
    "type_lift_pass!",
    # SROA
    "sroa_pass!",
    "sroa_mutables!",
    "getfield_elim_pass!",
    "form_ssa!",
    # Escape analysis
    "escape_analysis",
    "try_resolve_finalizer",
    # Slot optimization
    "slot2reg",
    "type_lift!",
    # Compact
    "compact!",
    "cfg_simplify!",
    "renumber_ir!",
    "finish_current_bb!",
    # IRCode-level optimization
    "convert_to_ircode",
    "run_passes",
    "optimize",
    "finish",
    # Dominator tree (optimizer infrastructure)
    "construct_domtree",
    "construct_postdomtree",
    "DomTree",
    "domtree_children",
    "update_domtree!",
]

const OPTIMIZER_MODULES = [
    # Module-level patterns to skip
]

function is_optimizer_function(func_name::String, mod_name::String)
    # Check prefix patterns
    for prefix in OPTIMIZER_PREFIXES
        if startswith(func_name, prefix)
            return true
        end
    end
    # Specific known optimizer functions
    func_name in ("run_passes", "optimize", "finish!", "finish",
                   "slot2reg", "type_lift!", "type_lift_pass!",
                   "adce_pass!", "getfield_elim_pass!", "sroa_pass!",
                   "compact!", "cfg_simplify!", "renumber_ir!",
                   "iterate_blocks", "complete", "scan_non_dataflow_flags!",
                   "find_throw_blocks!", "mark_throw_blocks!") && return true
    return false
end

# ============================================================================
# AbstractInterpreter interface methods
# ============================================================================

const ABSTRACT_INTERP_METHODS = Set([
    "method_table",
    "InferenceParams",
    "OptimizationParams",
    "get_inference_cache",
    "cache_lookup",
    "push!",  # cache push
    "lock_mi_inference",
    "unlock_mi_inference",
    "add_remark!",
    "may_optimize",
    "may_compress",
    "may_discard_trees",
    "verbose_stmt_info",
    "bail_out_call",
    "bail_out_apply",
    "bail_out_toplevel_call",
    "infer_effects",
])

# MethodTableView interface
const METHOD_TABLE_METHODS = Set([
    "findall",
    "isoverlayed",
])

# ============================================================================
# Known C walls
# ============================================================================

const C_WALLS = Dict{String, String}(
    "jl_matching_methods" => "method dispatch lookup — DictMethodTable replacement needed",
    "jl_gf_invoke_lookup_worlds" => "method lookup path — DictMethodTable replacement needed",
    "jl_uncompress_ir" => "decompressing method source — pre-decompress at build time",
)

# ============================================================================
# Data structures for the audit
# ============================================================================

mutable struct FunctionInfo
    name::String
    module_name::String
    n_statements::Int
    classification::String  # "pure_julia", "has_ccall", "optimizer_skip", "abstract_interp_interface"
    ccalls::Vector{String}
    is_abstract_interp::Bool
    is_method_table::Bool
    spec_types::String  # for identification
    method_file::String
    method_line::Int
end

const FUNCTIONS = Dict{UInt64, FunctionInfo}()
const VISIT_QUEUE = Vector{Tuple{Any, Any, UInt64}}()
const VISITED = Set{UInt64}()

# ============================================================================
# Walk the dependency graph
# ============================================================================

function get_func_key(f, argtypes)
    hash((f, argtypes))
end

function safe_string(@nospecialize(x))
    try
        string(x)
    catch
        "???"
    end
end

function extract_func_info(mi::Core.MethodInstance)
    try
        m = mi.def
        if m isa Method
            return (string(m.name), string(m.module), string(m.file), Int(m.line))
        end
    catch; end
    return ("unknown", "unknown", "unknown", 0)
end

function walk_typeinf_deps!()
    # Entry point: Core.Compiler.typeinf(interp::AbstractInterpreter, frame::InferenceState)
    entry_f = Core.Compiler.typeinf
    entry_types = Tuple{Core.Compiler.NativeInterpreter, Core.Compiler.InferenceState}

    push!(VISIT_QUEUE, (entry_f, entry_types, get_func_key(entry_f, entry_types)))

    while !isempty(VISIT_QUEUE)
        f, argtypes, key = popfirst!(VISIT_QUEUE)
        key in VISITED && continue
        push!(VISITED, key)

        # Get the typed IR
        results = try
            Base.code_typed(f, argtypes; optimize=false)
        catch e
            # Try with optimize=true as fallback
            try
                Base.code_typed(f, argtypes; optimize=true)
            catch
                continue
            end
        end
        isempty(results) && continue

        ci, ret_type = results[1]

        # Get function name and module
        func_name = safe_string(f)
        mod_name = try
            string(parentmodule(f))
        catch
            "unknown"
        end

        # Try to get method-level info
        method_file = "unknown"
        method_line = 0
        try
            ms = methods(f, argtypes)
            if length(ms) >= 1
                m = first(ms)
                func_name = string(m.name)
                mod_name = string(m.module)
                method_file = string(m.file)
                method_line = Int(m.line)
            end
        catch; end

        n_stmts = length(ci.code)

        # Check for optimizer function — skip but record
        if is_optimizer_function(func_name, mod_name)
            FUNCTIONS[key] = FunctionInfo(
                func_name, mod_name, n_stmts, "optimizer_skip",
                String[], false, false, safe_string(argtypes), method_file, method_line
            )
            continue  # Don't recurse into optimizer functions
        end

        # Scan for ccalls/foreigncalls
        ccalls_found = String[]
        for stmt in ci.code
            scan_for_ccalls!(stmt, ccalls_found)
        end

        # Check if this is an AbstractInterpreter interface method
        is_ai = func_name in ABSTRACT_INTERP_METHODS
        is_mt = func_name in METHOD_TABLE_METHODS

        # Classify
        classification = if !isempty(ccalls_found)
            "has_ccall"
        elseif is_ai
            "abstract_interp_interface"
        elseif is_mt
            "method_table_interface"
        else
            "pure_julia"
        end

        FUNCTIONS[key] = FunctionInfo(
            func_name, mod_name, n_stmts, classification,
            ccalls_found, is_ai, is_mt, safe_string(argtypes), method_file, method_line
        )

        # Recurse into called functions (but NOT optimizer functions)
        for stmt in ci.code
            discover_callees!(stmt, ci)
        end
    end
end

function scan_for_ccalls!(stmt::Expr, ccalls::Vector{String})
    if stmt.head === :foreigncall && length(stmt.args) >= 1
        name = stmt.args[1]
        ccall_name = if name isa QuoteNode
            string(name.value)
        elseif name isa String
            name
        elseif name isa Symbol
            string(name)
        else
            safe_string(name)
        end
        push!(ccalls, ccall_name)
    end
    # Recurse into nested exprs
    for arg in stmt.args
        if arg isa Expr
            scan_for_ccalls!(arg, ccalls)
        end
    end
end

function scan_for_ccalls!(stmt, ccalls::Vector{String})
    # Non-Expr statements don't have ccalls
end

function discover_callees!(stmt::Expr, ci::Core.CodeInfo)
    if stmt.head === :invoke && length(stmt.args) >= 2
        mi_or_ci = stmt.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end

        if mi !== nothing
            try
                spec = mi.specTypes
                if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                    func_type = spec.parameters[1]
                    if func_type isa DataType && func_type != Union{} && isdefined(func_type, :instance)
                        func = func_type.instance
                        arg_types = Tuple{spec.parameters[2:end]...}
                        key = get_func_key(func, arg_types)
                        if !(key in VISITED)
                            push!(VISIT_QUEUE, (func, arg_types, key))
                        end
                    end
                end
            catch; end
        end
    end

    # Recurse into nested exprs
    for arg in stmt.args
        if arg isa Expr
            discover_callees!(arg, ci)
        end
    end
end

function discover_callees!(stmt, ci::Core.CodeInfo)
    # Non-Expr: nothing to discover
end

# ============================================================================
# Output Generation
# ============================================================================

function generate_json_output()
    # Group by classification
    pure_julia = FunctionInfo[]
    has_ccall = FunctionInfo[]
    optimizer_skip = FunctionInfo[]
    ai_interface = FunctionInfo[]
    mt_interface = FunctionInfo[]

    for (_, info) in FUNCTIONS
        if info.classification == "pure_julia"
            push!(pure_julia, info)
        elseif info.classification == "has_ccall"
            push!(has_ccall, info)
        elseif info.classification == "optimizer_skip"
            push!(optimizer_skip, info)
        elseif info.classification == "abstract_interp_interface"
            push!(ai_interface, info)
        elseif info.classification == "method_table_interface"
            push!(mt_interface, info)
        end
    end

    sort!(pure_julia; by=x -> x.name)
    sort!(has_ccall; by=x -> x.name)
    sort!(optimizer_skip; by=x -> x.name)
    sort!(ai_interface; by=x -> x.name)
    sort!(mt_interface; by=x -> x.name)

    function info_to_dict(info::FunctionInfo)
        d = Dict{String, Any}(
            "name" => info.name,
            "module" => info.module_name,
            "n_statements" => info.n_statements,
            "classification" => info.classification,
            "spec_types" => info.spec_types,
            "file" => info.method_file,
            "line" => info.method_line,
        )
        if !isempty(info.ccalls)
            d["ccalls"] = info.ccalls
            # Flag known C walls
            walls = String[]
            for cc in info.ccalls
                if haskey(C_WALLS, cc)
                    push!(walls, "$(cc): $(C_WALLS[cc])")
                end
            end
            if !isempty(walls)
                d["c_walls"] = walls
            end
        end
        if info.is_abstract_interp
            d["is_abstract_interp_interface"] = true
        end
        if info.is_method_table
            d["is_method_table_interface"] = true
        end
        d
    end

    non_optimizer = length(pure_julia) + length(has_ccall) + length(ai_interface) + length(mt_interface)

    result = Dict{String, Any}(
        "entry_point" => "Core.Compiler.typeinf(NativeInterpreter, InferenceState)",
        "audit_date" => "2026-02-15",
        "summary" => Dict{String, Any}(
            "total_functions_found" => length(FUNCTIONS),
            "needed_functions" => non_optimizer,
            "pure_julia" => length(pure_julia),
            "has_ccall" => length(has_ccall),
            "abstract_interp_interface" => length(ai_interface),
            "method_table_interface" => length(mt_interface),
            "optimizer_skip" => length(optimizer_skip),
        ),
        "c_walls" => Dict{String, Any}(
            "known_walls" => C_WALLS,
            "found_in_functions" => [
                Dict("name" => info.name, "module" => info.module_name, "ccalls" => info.ccalls)
                for info in has_ccall
                if any(cc -> haskey(C_WALLS, cc), info.ccalls)
            ],
        ),
        "functions" => Dict{String, Any}(
            "pure_julia" => [info_to_dict(f) for f in pure_julia],
            "has_ccall" => [info_to_dict(f) for f in has_ccall],
            "abstract_interp_interface" => [info_to_dict(f) for f in ai_interface],
            "method_table_interface" => [info_to_dict(f) for f in mt_interface],
            "optimizer_skip" => [info_to_dict(f) for f in optimizer_skip],
        ),
    )

    outpath = joinpath(@__DIR__, "typeinf_dependency_graph.json")
    open(outpath, "w") do io
        JSON.print(io, result, 2)
    end
    println("Wrote: $outpath")

    return result
end

function generate_markdown(result)
    outpath = joinpath(@__DIR__, "typeinf_classification.md")
    open(outpath, "w") do io
        println(io, "# Core.Compiler.typeinf Dependency Graph Audit")
        println(io)
        println(io, "**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`")
        println(io, "**Date:** 2026-02-15")
        println(io, "**Methodology:** Walk call graph via `Base.code_typed(optimize=false)`, skip optimizer functions")
        println(io)

        s = result["summary"]
        println(io, "## Summary")
        println(io)
        println(io, "| Category | Count |")
        println(io, "|----------|-------|")
        println(io, "| **Total functions found** | **$(s["total_functions_found"])** |")
        println(io, "| **Needed (non-optimizer)** | **$(s["needed_functions"])** |")
        println(io, "| Pure Julia (compilable) | $(s["pure_julia"]) |")
        println(io, "| Has ccall (C-dependent) | $(s["has_ccall"]) |")
        println(io, "| AbstractInterpreter interface | $(s["abstract_interp_interface"]) |")
        println(io, "| MethodTable interface | $(s["method_table_interface"]) |")
        println(io, "| Optimizer (SKIP) | $(s["optimizer_skip"]) |")
        println(io)

        # C walls section
        println(io, "## C Walls (Must Be Replaced)")
        println(io)
        println(io, "| C Function | Purpose | Replacement Strategy |")
        println(io, "|------------|---------|---------------------|")
        for (name, desc) in sort(collect(C_WALLS))
            println(io, "| `$name` | $(split(desc, " — ")[1]) | $(length(split(desc, " — ")) > 1 ? split(desc, " — ")[2] : "") |")
        end
        println(io)

        # Functions with C walls
        cwall_funcs = result["c_walls"]["found_in_functions"]
        if !isempty(cwall_funcs)
            println(io, "### Functions Containing C Walls")
            println(io)
            println(io, "| Function | Module | C Calls |")
            println(io, "|----------|--------|---------|")
            for f in cwall_funcs
                println(io, "| `$(f["name"])` | $(f["module"]) | $(join(f["ccalls"], ", ")) |")
            end
            println(io)
        end

        # Pure Julia functions
        println(io, "## Pure Julia Functions (Compilable Now)")
        println(io)
        println(io, "| # | Function | Module | Statements | Spec Types |")
        println(io, "|---|----------|--------|------------|------------|")
        for (i, f) in enumerate(result["functions"]["pure_julia"])
            spec = length(f["spec_types"]) > 80 ? f["spec_types"][1:77] * "..." : f["spec_types"]
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) | `$spec` |")
        end
        println(io)

        # Has ccall functions
        println(io, "## C-Dependent Functions (Need Replacement)")
        println(io)
        println(io, "| # | Function | Module | Statements | C Calls |")
        println(io, "|---|----------|--------|------------|---------|")
        for (i, f) in enumerate(result["functions"]["has_ccall"])
            cc = join(get(f, "ccalls", String[]), ", ")
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) | `$cc` |")
        end
        println(io)

        # AbstractInterpreter interface
        if !isempty(result["functions"]["abstract_interp_interface"])
            println(io, "## AbstractInterpreter Interface Methods")
            println(io)
            println(io, "| # | Function | Module | Statements |")
            println(io, "|---|----------|--------|------------|")
            for (i, f) in enumerate(result["functions"]["abstract_interp_interface"])
                println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) |")
            end
            println(io)
        end

        # MethodTable interface
        if !isempty(result["functions"]["method_table_interface"])
            println(io, "## MethodTable Interface Methods")
            println(io)
            println(io, "| # | Function | Module | Statements |")
            println(io, "|---|----------|--------|------------|")
            for (i, f) in enumerate(result["functions"]["method_table_interface"])
                println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) |")
            end
            println(io)
        end

        # Optimizer skip
        println(io, "## Optimizer Functions (SKIPPED — Binaryen Handles)")
        println(io)
        println(io, "| # | Function | Module | Statements |")
        println(io, "|---|----------|--------|------------|")
        for (i, f) in enumerate(result["functions"]["optimizer_skip"])
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) |")
        end
        println(io)

        # Recommendations
        println(io, "## Recommendations")
        println(io)
        println(io, "### DictMethodTable Location")
        println(io, "Recommended: `WasmTarget.jl/src/typeinf/` directory")
        println(io, "- `dict_method_table.jl` — DictMethodTable struct + findall override")
        println(io, "- `wasm_interpreter.jl` — WasmInterpreter <: AbstractInterpreter")
        println(io, "- `populate.jl` — Build-time population script")
        println(io, "- `test_dict_typeinf.jl` — Native Julia verification tests")
        println(io)
        println(io, "### Next Steps")
        println(io, "1. PURE-3001: Classify each function (COMPILES_NOW / NEEDS_PATTERN / C_DEPENDENT)")
        println(io, "2. PURE-3002: Build DictMethodTable + populate script")
        println(io, "3. PURE-3003: Test DictMethodTable in native Julia")
        println(io, "4. PURE-3004: Generate per-function compilation stories")
    end
    println("Wrote: $outpath")
end

# ============================================================================
# Main
# ============================================================================

function main()
    println("=== PURE-3000: Audit Core.Compiler.typeinf Dependency Graph ===")
    println()

    println("Walking call graph from Core.Compiler.typeinf(NativeInterpreter, InferenceState)...")
    println("  Skipping optimizer functions (Binaryen handles optimization)")
    println()

    walk_typeinf_deps!()

    # Count by classification
    classifications = Dict{String, Int}()
    for (_, info) in FUNCTIONS
        classifications[info.classification] = get(classifications, info.classification, 0) + 1
    end

    println("=== Walk Complete ===")
    println("  Total functions found: $(length(FUNCTIONS))")
    for (cls, count) in sort(collect(classifications))
        println("  $cls: $count")
    end
    println()

    # Warn if too many non-optimizer functions
    non_opt = sum(v for (k, v) in classifications if k != "optimizer_skip"; init=0)
    if non_opt > 100
        println("⚠️  WARNING: $(non_opt) non-optimizer functions found (expected ~30-40)")
        println("   Optimizer functions may be leaking into the dependency graph.")
        println("   Review the optimizer skip list and add missing patterns.")
    elseif non_opt < 10
        println("⚠️  WARNING: Only $(non_opt) non-optimizer functions found (expected ~30-40)")
        println("   The walk may be too aggressive at skipping. Review classifications.")
    else
        println("✓  $(non_opt) non-optimizer functions — within expected range (~30-40)")
    end
    println()

    # Generate outputs
    println("Generating JSON output...")
    result = generate_json_output()

    println("Generating Markdown classification...")
    generate_markdown(result)

    println()
    println("=== Done ===")
end

main()
