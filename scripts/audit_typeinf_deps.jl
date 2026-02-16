#!/usr/bin/env julia
#
# PURE-3000: Audit Core.Compiler.typeinf Dependency Graph
#
# Walk typeinf's FULL call graph, SKIP optimizer functions.
# Uses two strategies:
# 1. code_typed with optimize=true to find :invoke targets (resolved methods)
# 2. :call with GlobalRef to find Core.Compiler function names, then look up methods
#
# For each function found:
# 1. Record: function name, module, number of statements
# 2. Classify: pure Julia / has ccall / optimizer function (SKIP)
# 3. Flag known C walls
# 4. Record AbstractInterpreter interface methods
#
# Output:
#   scripts/typeinf_dependency_graph.json
#   scripts/typeinf_classification.md
#
# Usage: julia +1.12 --project=WasmTarget.jl WasmTarget.jl/scripts/audit_typeinf_deps.jl

using JSON
using Core.Compiler

# ============================================================================
# Optimizer function names — SKIPPED (Binaryen handles optimization)
# ============================================================================

const OPTIMIZER_NAMES = Set([
    # Inlining
    "ssa_inlining_pass!", "inline_cost", "can_inline", "assm_inline",
    "resolve_todo", "analyze_method!", "inlining_policy",
    "process_simple!", "ir_inline_item!", "ir_inline_unresolved!",
    "batch_inline!", "linear_inline_eligible",
    "early_inline_special_case", "late_inline_special_case",
    "handle_single_case!", "is_valid_type_for_apply_rewrite",
    "handle_cases!", "handle_match!", "compileable_specialization",
    "handle_invoke_call!", "handle_finalizer_call!",
    "handle_opaque_closure_call!",
    # Constant propagation
    "const_prop_entry_heuristic", "const_prop_argument_heuristic",
    "const_prop_rettype_heuristic", "const_prop_function_heuristic",
    "semi_concrete_eval_call", "concrete_eval_call",
    "const_prop_call", "const_prop_methodinstance_heuristic",
    # Dead code elimination
    "adce_pass!", "type_lift_pass!",
    # SROA
    "sroa_pass!", "sroa_mutables!",
    "getfield_elim_pass!", "form_ssa!",
    # Escape analysis
    "escape_analysis", "try_resolve_finalizer!",
    # Slot optimization
    "slot2reg", "type_lift!",
    # Compact/IR manipulation
    "compact!", "cfg_simplify!", "renumber_ir!",
    "finish_current_bb!", "iterate_blocks",
    # IRCode-level optimization passes
    "convert_to_ircode", "run_passes",
    "optimize", "finish!",
    # Dominator tree (optimizer infrastructure)
    "construct_domtree", "construct_postdomtree",
    "update_domtree!", "DomTree",
    # Effect analysis
    "stmt_effect_flags",
    # SSA construction (optimizer infrastructure)
    "construct_ssa!", "domsort_ssa!",
    "insert_phi_nodes!", "rename_uses!",
    "compute_live_ins!",
    # Verify IR (debug only)
    "verify_ir", "verify_linetable",
])

function is_optimizer(name::String)
    name in OPTIMIZER_NAMES && return true
    startswith(name, "ssa_inlining") && return true
    startswith(name, "inline_") && return true
    startswith(name, "const_prop") && return true
    startswith(name, "semi_concrete") && return true
    startswith(name, "concrete_eval") && return true
    startswith(name, "sroa_") && return true
    startswith(name, "adce_") && return true
    startswith(name, "getfield_elim") && return true
    startswith(name, "slot2reg") && return true
    startswith(name, "cfg_simplify") && return true
    startswith(name, "construct_dom") && return true
    startswith(name, "ir_inline") && return true
    startswith(name, "batch_inline") && return true
    return false
end

# ============================================================================
# Known C walls
# ============================================================================

const C_WALLS = Dict(
    "jl_matching_methods" => "method dispatch lookup — DictMethodTable replaces this",
    "jl_gf_invoke_lookup_worlds" => "method lookup path — DictMethodTable replaces this",
    "jl_uncompress_ir" => "decompress method source — pre-decompress at build time",
)

# ============================================================================
# AbstractInterpreter interface
# ============================================================================

const AI_METHODS = Set([
    "method_table", "InferenceParams", "OptimizationParams",
    "get_inference_cache", "cache_lookup",
    "lock_mi_inference", "unlock_mi_inference",
    "add_remark!", "may_optimize", "may_compress",
    "may_discard_trees", "verbose_stmt_info",
    "bail_out_call", "bail_out_apply", "bail_out_toplevel_call",
])

const MT_METHODS = Set(["findall", "isoverlayed"])

# ============================================================================
# Data structures
# ============================================================================

mutable struct FuncInfo
    name::String
    module_name::String
    n_statements::Int
    classification::String
    ccalls::Vector{String}
    is_ai::Bool  # AbstractInterpreter interface
    is_mt::Bool  # MethodTable interface
    signature::String
    file::String
    line::Int
end

const RESULTS = Dict{String, FuncInfo}()

# Track what we've queued to avoid revisiting
const QUEUED = Set{String}()

# Queue of (function_name_as_symbol, module, specific_argtypes_or_nothing)
const QUEUE = Vector{Tuple{Any, Any, Any}}()

safe_str(@nospecialize x) = try string(x) catch; "???" end

# ============================================================================
# Process one function: get code_typed, classify, discover callees
# ============================================================================

function process!(f, argtypes)
    # Try to get code_typed
    results = try
        Base.code_typed(f, argtypes; optimize=true)
    catch
        try
            Base.code_typed(f, argtypes; optimize=false)
        catch
            return
        end
    end
    isempty(results) && return

    ci_raw, ret_type = results[1]
    ci_raw isa Core.CodeInfo || return
    ci = ci_raw::Core.CodeInfo

    func_name = "unknown"
    mod_name = "unknown"
    file_str = "unknown"
    line_num = 0
    try
        ms = methods(f, argtypes)
        if length(ms) >= 1
            m = first(ms)
            func_name = string(m.name)
            mod_name = string(m.module)
            file_str = string(m.file)
            line_num = Int(m.line)
        end
    catch; end
    if func_name == "unknown"
        func_name = safe_str(f)
        mod_name = try string(parentmodule(f)) catch; "unknown" end
    end

    key = "$func_name($(safe_str(argtypes)))"
    haskey(RESULTS, key) && return

    # Skip optimizer functions (but still record them)
    if is_optimizer(func_name)
        RESULTS[key] = FuncInfo(func_name, mod_name, length(ci.code), "optimizer_skip",
                                String[], false, false, safe_str(argtypes), file_str, line_num)
        return  # Don't recurse
    end

    # Scan for ccalls/foreigncalls
    ccalls = String[]
    for stmt in ci.code
        scan_ccalls!(stmt, ccalls)
    end

    is_ai = func_name in AI_METHODS
    is_mt = func_name in MT_METHODS

    classification = isempty(ccalls) ? "pure_julia" : "has_ccall"

    RESULTS[key] = FuncInfo(func_name, mod_name, length(ci.code), classification,
                            ccalls, is_ai, is_mt, safe_str(argtypes), file_str, line_num)

    # Discover callees from the IR
    discover_callees!(ci)
end

function scan_ccalls!(stmt::Expr, ccalls::Vector{String})
    if stmt.head === :foreigncall && length(stmt.args) >= 1
        name = stmt.args[1]
        s = if name isa QuoteNode
            val = name.value
            if val isa Symbol
                string(val)
            elseif val isa Tuple
                # (:name, :libname) tuple
                string(val[1])
            else
                safe_str(val)
            end
        elseif name isa Symbol
            string(name)
        else
            safe_str(name)
        end
        push!(ccalls, s)
    end
    for arg in stmt.args
        arg isa Expr && scan_ccalls!(arg, ccalls)
    end
end
scan_ccalls!(stmt, ccalls::Vector{String}) = nothing

function discover_callees!(ci::Core.CodeInfo)
    ssatypes = ci.ssavaluetypes

    for stmt in ci.code
        stmt isa Expr || continue

        if stmt.head === :invoke && length(stmt.args) >= 2
            # Resolved method call — extract from MethodInstance
            mi_or_ci = stmt.args[1]
            mi = if mi_or_ci isa Core.MethodInstance
                mi_or_ci
            elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                mi_or_ci.def
            else
                nothing
            end

            if mi isa Core.MethodInstance
                try
                    spec = mi.specTypes
                    if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                        func_type = spec.parameters[1]
                        if func_type isa DataType && func_type != Union{} && isdefined(func_type, :instance)
                            func = func_type.instance
                            arg_types = Tuple{spec.parameters[2:end]...}
                            enqueue!(func, arg_types)
                        end
                    end
                catch; end
            end

        elseif stmt.head === :call && length(stmt.args) >= 1
            func_ref = stmt.args[1]
            if func_ref isa GlobalRef && func_ref.mod === Core.Compiler
                # Core.Compiler function called via dispatch
                name = func_ref.name
                enqueue_compiler_func!(name, stmt, ci, ssatypes)
            end
        end
    end
end

function enqueue!(f, argtypes)
    key = "$(safe_str(f))($(safe_str(argtypes)))"
    key in QUEUED && return
    push!(QUEUED, key)
    push!(QUEUE, (f, nothing, argtypes))
end

function enqueue_compiler_func!(name::Symbol, stmt::Expr, ci, ssatypes)
    # Try to resolve function and infer arg types
    f = try getfield(Core.Compiler, name) catch; return end
    (f isa Function || f isa Type) || return

    # Try to infer argument types from SSA types
    arg_types = infer_call_argtypes(stmt, ci, ssatypes)

    if arg_types !== nothing
        key = "$(name)($(safe_str(arg_types)))"
        key in QUEUED && return
        push!(QUEUED, key)
        push!(QUEUE, (f, nothing, arg_types))
    else
        # Can't infer types — try each method of this function
        # Only do this for Core.Compiler functions
        try
            for m in methods(f)
                m.module === Core.Compiler || continue
                sig = m.sig
                if sig isa DataType && sig <: Tuple
                    params = sig.parameters
                    if length(params) >= 2  # at least typeof(f) + 1 arg
                        arg_types = Tuple{params[2:end]...}
                        key = "$(name)($(safe_str(arg_types)))"
                        key in QUEUED && continue
                        push!(QUEUED, key)
                        push!(QUEUE, (f, nothing, arg_types))
                    end
                end
            end
        catch; end
    end
end

function infer_call_argtypes(stmt::Expr, ci, ssatypes)
    length(stmt.args) < 2 && return nothing
    args = Any[]
    for i in 2:length(stmt.args)
        t = infer_val_type(stmt.args[i], ci, ssatypes)
        t === nothing && return nothing
        push!(args, t)
    end
    try Tuple{args...} catch; nothing end
end

function infer_val_type(@nospecialize(val), ci, ssatypes)
    if val isa Core.SSAValue
        idx = val.id
        if ssatypes isa Vector && 1 <= idx <= length(ssatypes)
            t = ssatypes[idx]
            t isa Type && return t
            t isa Core.Const && return typeof(t.val)
            t isa Core.PartialStruct && return t.typ
        end
        return nothing
    elseif val isa Core.Argument
        n = val.n
        if ci.slottypes !== nothing && 1 <= n <= length(ci.slottypes)
            t = ci.slottypes[n]
            t isa Type && return t
        end
        return nothing
    elseif val isa GlobalRef
        try typeof(getfield(val.mod, val.name)) catch; nothing end
    elseif val isa QuoteNode
        typeof(val.value)
    elseif val isa Bool
        Bool
    elseif val isa Int
        typeof(val)
    elseif val isa Type
        Type{val}
    else
        typeof(val)
    end
end

# ============================================================================
# Main walk
# ============================================================================

function walk!()
    # Seed with typeinf entry point
    push!(QUEUE, (Core.Compiler.typeinf, nothing,
                  Tuple{Core.Compiler.NativeInterpreter, Core.Compiler.InferenceState}))
    push!(QUEUED, "typeinf(NativeInterpreter, InferenceState)")

    processed = 0
    while !isempty(QUEUE)
        f, _, argtypes = popfirst!(QUEUE)
        process!(f, argtypes)
        processed += 1

        if processed > 1000
            println("⚠️  Safety valve at $processed — stopping")
            break
        end

        # Print progress periodically
        if processed % 50 == 0
            println("  ... processed $processed ($(length(RESULTS)) unique, $(length(QUEUE)) queued)")
        end
    end

    println("  Processed $processed total, $(length(RESULTS)) unique functions")
end

# ============================================================================
# Dedup and clean results
# ============================================================================

function dedup_results()
    # Group by (name, module) and keep the most informative version
    by_name = Dict{String, Vector{FuncInfo}}()
    for (_, info) in RESULTS
        key = "$(info.name)@$(info.module_name)"
        if !haskey(by_name, key)
            by_name[key] = FuncInfo[]
        end
        push!(by_name[key], info)
    end

    # For each group, merge ccalls and keep max statements
    merged = Dict{String, FuncInfo}()
    for (key, infos) in by_name
        best = infos[1]
        all_ccalls = Set{String}()
        for info in infos
            for cc in info.ccalls
                push!(all_ccalls, cc)
            end
            if info.n_statements > best.n_statements
                best = info
            end
        end

        # Merge specializations info
        if length(infos) > 1
            spec = join([i.signature for i in infos], " | ")
            merged_info = FuncInfo(best.name, best.module_name, best.n_statements,
                                  !isempty(all_ccalls) ? "has_ccall" : best.classification,
                                  collect(all_ccalls), best.is_ai, best.is_mt,
                                  spec, best.file, best.line)
            merged[key] = merged_info
        else
            merged[key] = best
        end
    end

    return merged
end

# ============================================================================
# Output: JSON
# ============================================================================

function generate_json(merged)
    pure = FuncInfo[]
    has_cc = FuncInfo[]
    optimizer = FuncInfo[]

    for (_, r) in merged
        if r.classification == "pure_julia"
            push!(pure, r)
        elseif r.classification == "has_ccall"
            push!(has_cc, r)
        elseif r.classification == "optimizer_skip"
            push!(optimizer, r)
        end
    end

    sort!(pure; by=x -> x.name)
    sort!(has_cc; by=x -> x.name)
    sort!(optimizer; by=x -> x.name)

    to_dict(r) = Dict{String,Any}(
        "name" => r.name,
        "module" => r.module_name,
        "n_statements" => r.n_statements,
        "classification" => r.classification,
        "ccalls" => unique(r.ccalls),
        "is_abstract_interp_interface" => r.is_ai,
        "is_method_table_interface" => r.is_mt,
        "signature" => r.signature,
        "file" => r.file,
        "line" => r.line,
    )

    # Find functions with known C walls
    c_wall_fns = [r for r in has_cc if any(cc -> haskey(C_WALLS, cc), r.ccalls)]

    non_opt = length(pure) + length(has_cc)

    result = Dict{String,Any}(
        "entry_point" => "Core.Compiler.typeinf(NativeInterpreter, InferenceState)",
        "audit_date" => "2026-02-15",
        "summary" => Dict{String,Any}(
            "total_unique_functions" => length(merged),
            "needed_non_optimizer" => non_opt,
            "pure_julia" => length(pure),
            "has_ccall" => length(has_cc),
            "optimizer_skip" => length(optimizer),
        ),
        "c_walls" => Dict{String,Any}(
            "known_walls" => C_WALLS,
            "functions_with_walls" => [to_dict(r) for r in c_wall_fns],
        ),
        "functions" => Dict{String,Any}(
            "pure_julia" => [to_dict(r) for r in pure],
            "has_ccall" => [to_dict(r) for r in has_cc],
            "optimizer_skip" => [to_dict(r) for r in optimizer],
        ),
    )

    outpath = joinpath(@__DIR__, "typeinf_dependency_graph.json")
    open(outpath, "w") do io
        JSON.print(io, result, 2)
    end
    println("Wrote: $outpath")
    return result
end

# ============================================================================
# Output: Markdown
# ============================================================================

function generate_markdown(result)
    outpath = joinpath(@__DIR__, "typeinf_classification.md")
    open(outpath, "w") do io
        println(io, "# Core.Compiler.typeinf Dependency Graph Audit (PURE-3000)")
        println(io)
        println(io, "**Entry point:** `Core.Compiler.typeinf(NativeInterpreter, InferenceState)`")
        println(io, "**Date:** 2026-02-15")
        println(io, "**Method:** Walk call graph via `Base.code_typed(optimize=true)`, recurse into")
        println(io, "both `:invoke` targets (resolved MethodInstances) and `:call` targets")
        println(io, "(GlobalRef to Core.Compiler functions). Skip optimizer functions.")
        println(io)

        s = result["summary"]
        println(io, "## Summary")
        println(io)
        println(io, "| Category | Count |")
        println(io, "|----------|-------|")
        println(io, "| **Total unique functions** | **$(s["total_unique_functions"])** |")
        println(io, "| **Needed (non-optimizer)** | **$(s["needed_non_optimizer"])** |")
        println(io, "| Pure Julia (compilable) | $(s["pure_julia"]) |")
        println(io, "| Has ccall (C-dependent) | $(s["has_ccall"]) |")
        println(io, "| Optimizer (SKIP) | $(s["optimizer_skip"]) |")
        println(io)

        # C Walls
        println(io, "## Known C Walls (Must Be Replaced)")
        println(io)
        println(io, "| C Function | Purpose | Replacement |")
        println(io, "|------------|---------|-------------|")
        for (name, desc) in sort(collect(C_WALLS))
            parts = split(desc, " — ")
            println(io, "| `$name` | $(parts[1]) | $(length(parts) > 1 ? parts[2] : "") |")
        end
        println(io)

        cw = result["c_walls"]["functions_with_walls"]
        if !isempty(cw)
            println(io, "### Functions Containing Known C Walls")
            println(io)
            for f in cw
                println(io, "- **`$(f["name"])`** ($(f["module"])): $(join(unique(f["ccalls"]), ", "))")
            end
            println(io)
        end

        # Pure Julia
        pure = result["functions"]["pure_julia"]
        println(io, "## Pure Julia Functions ($(length(pure)))")
        println(io)
        println(io, "These can be compiled to Wasm directly.")
        println(io)
        println(io, "| # | Function | Module | Stmts | AI? | MT? | File |")
        println(io, "|---|----------|--------|-------|-----|-----|------|")
        for (i, f) in enumerate(pure)
            ai = f["is_abstract_interp_interface"] ? "AI" : ""
            mt = f["is_method_table_interface"] ? "MT" : ""
            file = basename(f["file"])
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) | $ai | $mt | $file:$(f["line"]) |")
        end
        println(io)

        # Has ccall
        cc = result["functions"]["has_ccall"]
        println(io, "## C-Dependent Functions ($(length(cc)))")
        println(io)
        println(io, "These contain foreigncalls and need pure Julia replacements.")
        println(io)
        println(io, "| # | Function | Module | Stmts | C Calls | C Wall? |")
        println(io, "|---|----------|--------|-------|---------|---------|")
        for (i, f) in enumerate(cc)
            ccalls_str = join(unique(f["ccalls"]), ", ")
            wall = any(c -> haskey(C_WALLS, c), f["ccalls"]) ? "YES" : ""
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) | `$ccalls_str` | $wall |")
        end
        println(io)

        # Optimizer skip
        opt = result["functions"]["optimizer_skip"]
        println(io, "## Optimizer Functions ($(length(opt)) — SKIPPED)")
        println(io)
        println(io, "Binaryen handles optimization. These are not compiled to Wasm.")
        println(io)
        println(io, "| # | Function | Module | Stmts |")
        println(io, "|---|----------|--------|-------|")
        for (i, f) in enumerate(opt)
            println(io, "| $i | `$(f["name"])` | $(f["module"]) | $(f["n_statements"]) |")
        end
        println(io)

        # Architecture recommendations
        println(io, "## Architecture Recommendation")
        println(io)
        println(io, "### DictMethodTable Location")
        println(io, "```")
        println(io, "WasmTarget.jl/src/typeinf/")
        println(io, "  dict_method_table.jl  — DictMethodTable <: MethodTableView")
        println(io, "  wasm_interpreter.jl   — WasmInterpreter <: AbstractInterpreter")
        println(io, "  populate.jl           — Build-time Dict population")
        println(io, "  test_dict_typeinf.jl  — Native Julia verification")
        println(io, "```")
        println(io)
        println(io, "### C Wall Replacement Strategy")
        println(io, "| Wall | Strategy |")
        println(io, "|------|----------|")
        println(io, "| `jl_matching_methods` | DictMethodTable: Dict{Type, MethodLookupResult} pre-populated at build time |")
        println(io, "| `jl_gf_invoke_lookup_worlds` | Same DictMethodTable (different lookup path, same data) |")
        println(io, "| `jl_uncompress_ir` | Pre-decompress CodeInfo at build time, store in Dict |")
        println(io)
        println(io, "### Other ccalls Found (not C walls)")
        println(io)
        all_ccalls = Set{String}()
        for f in cc
            for c in f["ccalls"]
                haskey(C_WALLS, c) || push!(all_ccalls, c)
            end
        end
        println(io, "| ccall | Purpose | Strategy |")
        println(io, "|-------|---------|----------|")
        for c in sort(collect(all_ccalls))
            purpose = if c == "jl_hrtime"
                "High-resolution timer"
            elseif c == "jl_string_ptr"
                "Get string pointer"
            elseif c == "jl_uv_puts"
                "Write to stream"
            elseif c == "jl_get_world_counter"
                "Get world age"
            elseif c == "jl_type_intersection"
                "Type intersection"
            elseif c == "jl_genericmemory_copyto"
                "Memory copy"
            elseif c == "jl_fill_codeinst"
                "Fill code instance cache"
            elseif c == "jl_promote_cis_to_current" || c == "jl_promote_ci_to_current"
                "Promote code instance"
            elseif c == "memset"
                "Memory set (libc)"
            elseif startswith(c, "mpfr_")
                "MPFR big float comparison"
            else
                "?"
            end
            strategy = if c in ("jl_hrtime", "jl_string_ptr", "jl_uv_puts")
                "SKIP — only used for timing/debug output"
            elseif c in ("jl_get_world_counter",)
                "Return constant world age (set at build time)"
            elseif c == "jl_type_intersection"
                "Implement in pure Julia (subtype lattice)"
            elseif c in ("jl_genericmemory_copyto", "memset")
                "Use Wasm memory.copy / memory.fill"
            elseif c in ("jl_fill_codeinst", "jl_promote_cis_to_current", "jl_promote_ci_to_current")
                "SKIP — cache management, not needed for single-shot typeinf"
            elseif startswith(c, "mpfr_")
                "SKIP — only in MPFR comparison, not on critical path"
            else
                "Investigate"
            end
            println(io, "| `$c` | $purpose | $strategy |")
        end
        println(io)

        # Next steps
        println(io, "## Next Steps")
        println(io)
        println(io, "1. **PURE-3001**: Try compiling each pure Julia function individually with WasmTarget")
        println(io, "   - Classify: COMPILES_NOW / NEEDS_PATTERN / C_DEPENDENT")
        println(io, "2. **PURE-3002**: Build DictMethodTable (pure Julia Dict replaces jl_matching_methods)")
        println(io, "3. **PURE-3003**: Test in native Julia (Dict typeinf CodeInfo == standard CodeInfo)")
        println(io, "4. **PURE-3004**: Per-function compilation stories from classification")
    end
    println("Wrote: $outpath")
end

# ============================================================================
# Main
# ============================================================================

function main()
    println("=== PURE-3000: Audit Core.Compiler.typeinf Dependency Graph ===")
    println()
    println("Walking call graph from typeinf(NativeInterpreter, InferenceState)...")
    println("  Skipping optimizer functions (Binaryen handles optimization)")
    println()

    walk!()

    println()
    println("Deduplicating by (name, module)...")
    merged = dedup_results()

    classifications = Dict{String, Int}()
    for (_, r) in merged
        classifications[r.classification] = get(classifications, r.classification, 0) + 1
    end

    println()
    println("=== Results (deduped) ===")
    println("  Total unique: $(length(merged))")
    for (cls, count) in sort(collect(classifications))
        println("    $cls: $count")
    end

    non_opt = sum(v for (k, v) in classifications if k != "optimizer_skip"; init=0)
    println()
    if non_opt > 100
        println("⚠️  $(non_opt) non-optimizer functions (expected ~30-40, optimizer may be leaking)")
    elseif non_opt < 10
        println("⚠️  Only $(non_opt) non-optimizer functions (walk may be too shallow)")
    else
        println("✓  $(non_opt) non-optimizer functions — within expected range")
    end
    println()

    println("Generating outputs...")
    result = generate_json(merged)
    generate_markdown(result)
    println()
    println("=== Done ===")
end

main()
