#!/usr/bin/env julia
# enumerate_critical_path_v2.jl — PURE-6025
#
# PHASE 1: Just enumerate the delta functions between interpreter and codegen seeds.
# No compilation — just discover_dependencies and diff the lists.
# This avoids the stack overflow from compile_module_from_ir corrupting the process.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Helper functions
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

println("=== PURE-6025: Enumerate critical path delta ===")
println("Started: $(Dates.now())")
flush(stdout)

# ── Step 1: Discover INTERPRETER seed deps ────────────────────────────────────
println("Step 1: Discovering INTERPRETER seed dependencies...")
flush(stdout)
interp_seed = [
    (_wasm_eval_arith, (Vector{UInt8},)),
    (eval_julia_test_eval_arith, (Vector{UInt8},)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
    (_wasm_simple_call_expr, (JuliaSyntax.ParseStream,)),
    (_wasm_build_tree_expr, (JuliaSyntax.ParseStream,)),
    (_wasm_leaf_to_expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.Kind, Vector{UInt8}, UInt32)),
    (_wasm_node_to_expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
    (_wasm_parseargs!, (Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
    (_wasm_string_to_Expr, (JuliaSyntax.RedTreeCursor, JuliaSyntax.SourceFile, Vector{UInt8}, UInt32)),
    (_wasm_untokenize_kind, (JuliaSyntax.Kind, Bool)),
    (_wasm_untokenize_head, (JuliaSyntax.SyntaxHead,)),
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

t0 = time()
interp_deps = WasmTarget.discover_dependencies(interp_seed)
t1 = time()
println("  INTERPRETER: $(length(interp_deps)) functions ($(round(t1-t0, digits=1))s)")
flush(stdout)

# ── Step 2: Discover CODEGEN seed deps ────────────────────────────────────────
println("\nStep 2: Discovering CODEGEN seed dependencies...")
flush(stdout)
codegen_seed = [
    interp_seed...,
    (_wasm_eval_arith_to_bytes, (Vector{UInt8},)),
    (_wasm_compile_codeinfo_to_bytes, (Core.CodeInfo, Type, String, Tuple)),
    (eval_julia_test_arith_to_bytes, (Vector{UInt8},)),
]

t0 = time()
codegen_deps = WasmTarget.discover_dependencies(codegen_seed)
t1 = time()
println("  CODEGEN: $(length(codegen_deps)) functions ($(round(t1-t0, digits=1))s)")
flush(stdout)

# ── Step 3: Find and list the DELTA ────────────────────────────────────────────
interp_set = Set(interp_deps)
delta_deps = [(f, t) for (f, t) in codegen_deps if (f, t) ∉ interp_set]

println("\nStep 3: Delta analysis")
println("  INTERPRETER: $(length(interp_deps)) functions")
println("  CODEGEN: $(length(codegen_deps)) functions")
println("  DELTA: $(length(delta_deps)) new functions in codegen path")
flush(stdout)

# ── Step 4: Categorize delta functions ────────────────────────────────────────
println("\n=== DELTA FUNCTIONS ($(length(delta_deps))) ===")
flush(stdout)

# Group by module
module_groups = Dict{String, Vector{Tuple{String, String}}}()
for (func, arg_types) in delta_deps
    mod_name = string(parentmodule(func))
    func_name = string(nameof(func))
    type_str = join([string(t) for t in arg_types], ", ")
    if !haskey(module_groups, mod_name)
        module_groups[mod_name] = []
    end
    push!(module_groups[mod_name], (func_name, type_str))
end

for (mod_name, funcs) in sort(collect(module_groups))
    println("\n--- $mod_name ($(length(funcs)) functions) ---")
    for (func_name, type_str) in sort(funcs)
        println("  $func_name($type_str)")
    end
end
flush(stdout)

# ── Step 5: Write results file ────────────────────────────────────────────────
outfile = joinpath(@__DIR__, "critical_path_v2_delta.txt")
open(outfile, "w") do io
    println(io, "# PURE-6025: Critical path delta (codegen - interpreter)")
    println(io, "# Generated: $(Dates.now())")
    println(io, "# INTERPRETER: $(length(interp_deps)) functions")
    println(io, "# CODEGEN: $(length(codegen_deps)) functions")
    println(io, "# DELTA: $(length(delta_deps)) functions")
    println(io)
    for (mod_name, funcs) in sort(collect(module_groups))
        println(io, "## $mod_name ($(length(funcs)))")
        for (func_name, type_str) in sort(funcs)
            println(io, "  $func_name($type_str)")
        end
        println(io)
    end
end

println("\n\nResults written to: $outfile")
println("Done: $(Dates.now())")
flush(stdout)
