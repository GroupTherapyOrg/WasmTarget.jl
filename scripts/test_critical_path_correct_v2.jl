#!/usr/bin/env julia
# test_critical_path_correct_v2.jl — PURE-6025
#
# Batch isolation testing of critical path functions for the codegen-in-WASM path.
#
# Strategy:
# 1. Discover deps for INTERPRETER seed (_wasm_eval_arith — 569 funcs, all VALIDATE)
# 2. Discover deps for CODEGEN seed (_wasm_eval_arith_to_bytes — includes compile_module_from_ir)
# 3. Find the DELTA: functions only in codegen seed
# 4. Compile each delta function INDIVIDUALLY
# 5. Report: VALIDATES / COMPILE_ERROR / VALIDATE_ERROR for each
#
# This tells us exactly how many codegen functions need fixing before
# the codegen-in-WASM path can work.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Helper functions (same as compile_eval_julia_arith.jl)
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end

function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

println("=== PURE-6025: Critical path batch isolation test ===")
println("Started: $(Dates.now())")
println()

# ── Step 1: Discover INTERPRETER seed deps ────────────────────────────────────
println("Step 1: Discovering INTERPRETER seed dependencies...")
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
println()

# ── Step 2: Discover CODEGEN seed deps ────────────────────────────────────────
println("Step 2: Discovering CODEGEN seed dependencies...")
codegen_seed = [
    # Everything from interpreter seed PLUS:
    interp_seed...,
    # The codegen-in-WASM entry points:
    (_wasm_eval_arith_to_bytes, (Vector{UInt8},)),
    (_wasm_compile_codeinfo_to_bytes, (Core.CodeInfo, Type, String, Tuple)),
    (eval_julia_test_arith_to_bytes, (Vector{UInt8},)),
]

t0 = time()
codegen_deps = WasmTarget.discover_dependencies(codegen_seed)
t1 = time()
println("  CODEGEN: $(length(codegen_deps)) functions ($(round(t1-t0, digits=1))s)")
println()

# ── Step 3: Find the DELTA ────────────────────────────────────────────────────
# Build sets of (function, arg_types) for comparison
interp_set = Set(interp_deps)
delta_deps = [d for d in codegen_deps if d ∉ interp_set]
println("Step 3: Delta analysis")
println("  INTERPRETER: $(length(interp_deps)) functions (already VALIDATES)")
println("  CODEGEN: $(length(codegen_deps)) functions")
println("  DELTA (new in codegen): $(length(delta_deps)) functions")
println()

# ── Step 4: Compile each delta function individually ──────────────────────────
println("Step 4: Compiling each delta function individually...")
println()

validates = String[]
validate_errors = Tuple{String, String}[]
compile_errors = Tuple{String, String}[]

for (i, (func, arg_types)) in enumerate(delta_deps)
    func_name = string(nameof(func))
    type_str = join([string(t) for t in arg_types], ", ")
    label = "$func_name($(type_str))"

    # Try to compile individually
    local wasm_bytes
    try
        wasm_bytes = WasmTarget.compile_multi([(func, arg_types)])
    catch e
        push!(compile_errors, (label, sprint(showerror, e)[1:min(200, end)]))
        if i <= 20 || i % 50 == 0
            println("  [$i/$(length(delta_deps))] $label — COMPILE_ERROR")
        end
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end
    rm(tmpf; force=true)

    if ok
        push!(validates, label)
        if i <= 20 || i % 50 == 0
            println("  [$i/$(length(delta_deps))] $label — VALIDATES ✓")
        end
    else
        err_msg = String(take!(errbuf))
        first_line = split(err_msg, '\n')[1]
        push!(validate_errors, (label, first_line))
        if i <= 20 || i % 50 == 0
            println("  [$i/$(length(delta_deps))] $label — VALIDATE_ERROR: $first_line")
        end
    end
end

println()
println("=== RESULTS ===")
println("  VALIDATES: $(length(validates))/$(length(delta_deps))")
println("  VALIDATE_ERROR: $(length(validate_errors))/$(length(delta_deps))")
println("  COMPILE_ERROR: $(length(compile_errors))/$(length(delta_deps))")
println()

# ── Step 5: Write detailed results ──────────────────────────────────────────
outfile = joinpath(@__DIR__, "critical_path_v2_results.txt")
open(outfile, "w") do io
    println(io, "# PURE-6025: Critical path batch isolation test results")
    println(io, "# Generated: $(Dates.now())")
    println(io, "# INTERPRETER: $(length(interp_deps)) functions (all VALIDATE)")
    println(io, "# CODEGEN: $(length(codegen_deps)) functions")
    println(io, "# DELTA: $(length(delta_deps)) functions")
    println(io, "#")
    println(io, "# VALIDATES: $(length(validates))")
    println(io, "# VALIDATE_ERROR: $(length(validate_errors))")
    println(io, "# COMPILE_ERROR: $(length(compile_errors))")
    println(io)

    println(io, "## VALIDATES ($(length(validates))):")
    for v in validates
        println(io, "  ✓ $v")
    end
    println(io)

    println(io, "## VALIDATE_ERROR ($(length(validate_errors))):")
    for (label, err) in validate_errors
        println(io, "  ✗ $label — $err")
    end
    println(io)

    println(io, "## COMPILE_ERROR ($(length(compile_errors))):")
    for (label, err) in compile_errors
        println(io, "  ✗ $label — $err")
    end
end
println("Results written to: $outfile")
println()
println("Done: $(Dates.now())")
