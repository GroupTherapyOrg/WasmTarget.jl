#!/usr/bin/env julia
# compile_eval_julia_minimal.jl — PURE-6024
#
# Minimal compile: ONLY essential pipeline functions + a few key diagnostics.
# Strips out 60+ diagnostic functions that clutter the seed and cause validation errors.
# The previous compile_eval_julia_stubbed.jl had eval_julia_test_parse_all_children
# which uses parse_julia_literal (returns Any → anyref), causing validation failure.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Helper functions to extract bytes from WasmGC Vector{UInt8} result
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

# Core.Compiler optimization functions to stub — never called with may_optimize=false
const INFERENCE_WHITELIST = Set([
    # Core inference loop
    "typeinf_frame", "typeinf", "typeinf_nocycle", "typeinf_local",
    "_typeinf", "typeinf_edge",
    # Inference state construction
    "InferenceState", "finish", "retrieve_code_info",
    "most_general_argtypes",
    # Abstract interpretation
    "abstract_call", "abstract_call_gf_by_type", "abstract_call_method",
    "abstract_call_known", "abstract_call_opaque_closure",
    "abstract_eval_statement", "abstract_eval_special_value",
    "abstract_eval_value", "abstract_eval_cfunction",
    "abstract_eval_ssavalue", "abstract_eval_globalref",
    "abstract_eval_global", "abstract_interpret",
    "abstract_eval_new", "abstract_eval_phi",
    "resolve_call_cycle!",
    # Effect analysis
    "check_inconsistentcy!", "refine_effects!",
    "builtin_effects",
    # Lattice operations
    "issimplertype", "widenconst", "tname_intersect", "tuplemerge",
    # Type functions (tfunc)
    "getfield_tfunc", "getfield_nothrow", "fieldtype_nothrow",
    "setfield!_nothrow", "isdefined_tfunc", "isdefined_nothrow",
    "apply_type_nothrow", "sizeof_nothrow", "typebound_nothrow",
    "memoryrefop_builtin_common_nothrow",
    # Type analysis
    "argextype", "isknowntype", "is_lattice_equal",
    # Generic functions also used by inference (not optimization-only)
    "push!", "scan!", "check_inconsistentcy!", "something",
    # Caching
    "cache_lookup", "transform_result_for_cache",
])

function main()
    println("=== PURE-6024: Minimal eval_julia compile (pipeline + key diagnostics only) ===")
    println("Started: $(Dates.now())")
    println()

    # Step 0: Verify native pipeline
    println("Step 0: Verify native eval_julia works...")
    for (expr, expected) in [("1+1", 2), ("2+3", 5), ("10-3", 7), ("6*7", 42)]
        result = eval_julia_native(expr)
        status = result == expected ? "CORRECT" : "WRONG (got $result)"
        println("  eval_julia_native(\"$expr\") = $result — $status")
    end
    println()

    # Step 1: Discover dependencies — MINIMAL seed
    println("Step 1: Discovering dependencies (minimal seed)...")
    seed = [
        # === ESSENTIAL PIPELINE ===
        (eval_julia_to_bytes_vec, (Vector{UInt8},)),
        (eval_julia_result_length, (Vector{UInt8},)),
        (eval_julia_result_byte, (Vector{UInt8}, Int32)),
        (make_byte_vec, (Int32,)),
        (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
        # === WASM-COMPATIBLE PARSERS ===
        (_wasm_simple_call_expr, (JuliaSyntax.ParseStream,)),
        (_wasm_build_tree_expr, (JuliaSyntax.ParseStream,)),
        (_wasm_leaf_to_expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.Kind, Vector{UInt8}, UInt32)),
        (_wasm_node_to_expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
        (_wasm_parseargs!, (Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
        (_wasm_string_to_Expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
        (_wasm_untokenize_kind, (JuliaSyntax.Kind, Bool)),
        (_wasm_untokenize_head, (JuliaSyntax.SyntaxHead,)),
        # === KEY DIAGNOSTICS (all return Int32, known to work) ===
        (eval_julia_test_ps_create, (Vector{UInt8},)),
        (eval_julia_test_parse_only, (Vector{UInt8},)),
        (eval_julia_test_input_len, (Vector{UInt8},)),
        (eval_julia_test_build_tree_wasm, (Vector{UInt8},)),
        (eval_julia_test_simple_call, (Vector{UInt8},)),
        (eval_julia_test_simple_call_steps, (Vector{UInt8},)),
        (eval_julia_test_flat_call, (Vector{UInt8},)),
        (_wasm_simple_call_expr_flat, (JuliaSyntax.ParseStream,)),
        (eval_julia_test_parse_arith, (Vector{UInt8},)),
        (_wasm_parse_arith, (JuliaSyntax.ParseStream,)),
    ]
    all_funcs = WasmTarget.discover_dependencies(seed)
    println("  Found $(length(all_funcs)) functions")
    println()

    # Step 2: Identify optimization pass functions to stub
    stub_names = Set{String}()
    kept_names = Set{String}()
    for (f, arg_types, name) in all_funcs
        mod = try parentmodule(f) catch; nothing end
        mod_name = try string(nameof(mod)) catch; "" end
        base_name = replace(name, r"_\d+$" => "")
        is_compiler_mod = mod_name == "Compiler"
        is_opt_submod = mod_name == "EscapeAnalysis"
        if (is_compiler_mod && !(base_name in INFERENCE_WHITELIST)) || is_opt_submod
            push!(stub_names, name)
        elseif is_compiler_mod
            push!(kept_names, name)
        end
    end
    println("  Core.Compiler functions: $(length(stub_names) + length(kept_names))")
    println("  Stubbing $(length(stub_names)) (optimization), keeping $(length(kept_names)) (inference)")
    for n in sort(collect(stub_names))
        println("    STUB: $n")
    end
    println()

    # Step 3: Compile with stubs
    println("Step 3: Compiling with stub_names...")
    t_start = time()
    wasm_bytes = WasmTarget.compile_multi(seed; stub_names=stub_names)
    t_elapsed = time() - t_start
    println("  COMPILE SUCCESS: $(length(wasm_bytes)) bytes ($(round(t_elapsed, digits=1))s)")
    println()

    # Step 4: Validate
    outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
    mkpath(dirname(outf))
    write(outf, wasm_bytes)
    println("Step 4: Validating output/eval_julia.wasm ($(length(wasm_bytes)) bytes)...")

    errbuf = IOBuffer()
    validate_ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf, stdout=devnull))
        validate_ok = true
    catch; end

    if validate_ok
        println("  VALIDATES ✓")
        print_buf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
        wasm_text = String(take!(print_buf))
        func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
        println("  Function count: $func_count")
        println()
        println("  RESULT: VALIDATES ✓ — ready to test for CORRECT")
    else
        err_msg = String(take!(errbuf))
        println("  VALIDATE_ERROR:")
        println("  $err_msg")

        m = match(r"func (\d+) failed", err_msg)
        if m !== nothing
            func_idx = Base.parse(Int, m.captures[1])
            println()
            println("  Failed func index: $func_idx")
            print_buf = IOBuffer()
            try
                Base.run(pipeline(`wasm-tools print $outf`, stdout=print_buf))
                wasm_text = String(take!(print_buf))
                for line in split(wasm_text, '\n')
                    if contains(line, "(export") && contains(line, "(func $(func_idx))")
                        println("  Export: $line")
                    end
                end
            catch; end
        end
        exit(1)
    end

    println()
    println("Done: $(Dates.now())")
end

main()
