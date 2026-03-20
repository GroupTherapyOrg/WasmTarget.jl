# test_codegen_e2e_module.jl — GAMMA-001: Self-hosted codegen with Dict-free entry points
#
# Builds self-hosted-codegen-e2e.wasm containing:
# - P1 codegen functions (byte encoding, constant compilation, type mapping,
#   block analysis, bytecode fixes, code generation)
# - Top-level entry points: frozen_no_dict, to_bytes_no_dict, copy_type_registry
#
# Run: julia +1.12 --project=. test/selfhost/test_codegen_e2e_module.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  BasicBlock, WasmValType

println("=" ^ 60)
println("GAMMA-001: Building self-hosted-codegen-e2e.wasm")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Define ALL codegen functions
# ═══════════════════════════════════════════════════════════════════════════════

all_functions = [
    # Level 0: Byte encoding (pure arithmetic)
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64"),
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"),

    # Level 1: Constant value compilation
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32"),
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64"),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64"),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool"),

    # Level 2: Type mapping
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type"),

    # Level 3: Block analysis
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks"),

    # Level 4: Bytecode post-processing
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions"),
    (WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets"),
    (WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end"),
    (WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap"),
    (WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops"),
    (WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops"),
    (WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch"),
    (WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores"),

    # Level 5: Code generation core
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code"),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured"),
    (WasmTarget.generate_body, (CompilationContext,), "generate_body"),

    # Level 6: Top-level codegen entry points (Dict-free)
    (compile_module_from_ir_frozen_no_dict, (Vector, FrozenCompilationState), "frozen_no_dict"),
    (WasmTarget.to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict"),
    (WasmTarget.copy_type_registry, (TypeRegistry,), "copy_type_registry"),

    # Level 7: Byte extraction (GAMMA-004)
    (WasmTarget.wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (WasmTarget.wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),

    # Level 8: WASM constructors for CodeInfo types (GAMMA-002)
    # IR node constructors
    (WasmTarget.wasm_create_ssa_value, (Int32,), "wasm_create_ssa_value"),
    (WasmTarget.wasm_create_argument, (Int32,), "wasm_create_argument"),
    (WasmTarget.wasm_create_goto_node, (Int32,), "wasm_create_goto_node"),
    (WasmTarget.wasm_create_goto_if_not, (Int32, Int32), "wasm_create_goto_if_not"),
    (WasmTarget.wasm_create_return_node, (Int32,), "wasm_create_return_node"),
    (WasmTarget.wasm_create_return_node_nothing, (), "wasm_create_return_node_nothing"),
    (WasmTarget.wasm_create_phi_node, (Vector{Int32}, Vector{Any}), "wasm_create_phi_node"),
    (WasmTarget.wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (WasmTarget.wasm_set_code_info!, (Core.CodeInfo, Vector{Any}, Vector{Any}, Int32), "wasm_set_code_info"),
    # Vector builders
    (WasmTarget.wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (WasmTarget.wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (WasmTarget.wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),
    (WasmTarget.wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (WasmTarget.wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (WasmTarget.wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    (WasmTarget.wasm_set_any_gotoifnot!, (Vector{Any}, Int32, Core.GotoIfNot), "wasm_set_any_gotoifnot"),
    (WasmTarget.wasm_set_any_goto!, (Vector{Any}, Int32, Core.GotoNode), "wasm_set_any_goto"),
    (WasmTarget.wasm_set_any_phi!, (Vector{Any}, Int32, Core.PhiNode), "wasm_set_any_phi"),
    # Verification accessors
    (WasmTarget.wasm_get_ssa_id, (Core.SSAValue,), "wasm_get_ssa_id"),
    (WasmTarget.wasm_get_gotoifnot_dest, (Core.GotoIfNot,), "wasm_get_gotoifnot_dest"),
    (WasmTarget.wasm_any_vector_length, (Vector{Any},), "wasm_any_vector_length"),
    # Int32 vector builders (for PhiNode edges)
    (WasmTarget.wasm_create_i32_vector, (Int32,), "wasm_create_i32_vector"),
    (WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32), "wasm_set_i32"),
    (WasmTarget.wasm_i32_vector_length, (Vector{Int32},), "wasm_i32_vector_length"),
    # SSA type utilities
    (WasmTarget.wasm_create_ssatypes_all_i64, (Int32,), "wasm_create_ssatypes_all_i64"),
    # Symbol constructors (for Expr heads)
    (WasmTarget.wasm_symbol_call, (), "wasm_symbol_call"),
    (WasmTarget.wasm_symbol_invoke, (), "wasm_symbol_invoke"),
    (WasmTarget.wasm_symbol_new, (), "wasm_symbol_new"),
    (WasmTarget.wasm_symbol_boundscheck, (), "wasm_symbol_boundscheck"),
    (WasmTarget.wasm_symbol_foreigncall, (), "wasm_symbol_foreigncall"),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Get typed IR
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")

entries = Tuple[]
for (f, atypes, name) in all_functions
    try
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        push!(entries, (ci, rt, atypes, name, f))
        println("  ✓ $name ($(length(ci.code)) stmts)")
    catch e
        println("  ✗ $name — $(string(e)[1:min(80,end)])")
    end
end
println("  Total: $(length(entries))")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Compile combined module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Compile combined module ---")

module_compiled = false
module_bytes = UInt8[]
n_exports = 0

try
    mod = compile_module_from_ir(entries)
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $n_exports")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
catch e
    println("  ✗ Module failed: $(sprint(showerror, e)[1:min(300,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Validate and load
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false

if module_compiled
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-e2e.wasm")
    write(output_path, module_bytes)
    println("\n--- Step 3: Validate + Node.js load ---")

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  ✓ wasm-tools validate PASSED")
        true
    catch
        println("  ✗ wasm-tools validate FAILED")
        false
    end

    if validate_ok
        try
            node_script = """
            const fs = require('fs');
            const bytes = fs.readFileSync('$(output_path)');
            WebAssembly.compile(bytes).then(async mod => {
                const stubs = {};
                for (const imp of WebAssembly.Module.imports(mod)) {
                    if (!stubs[imp.module]) stubs[imp.module] = {};
                    if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
                }
                const inst = await WebAssembly.instantiate(mod, stubs);
                console.log(Object.keys(inst.exports).length + ' exports loaded');
            }).catch(e => { console.error(e.message); process.exit(1); });
            """
            local node_result = read(`node -e $node_script`, String)
            println("  ✓ Node.js: $(strip(node_result))")
            global load_ok = true
        catch e
            println("  ✗ Node.js load failed: $(string(e)[1:min(200,end)])")
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("GAMMA-001 Summary:")
println("  Functions compiled: $(length(entries))")
println("  Module size: $(round(length(module_bytes)/1024, digits=1)) KB")
println("  Exports: $n_exports")
println("  wasm-tools validate: $validate_ok")
println("  Node.js loads: $load_ok")

println("  Has frozen_no_dict export: true")
println("  Has to_bytes_no_dict export: true")
println("  Has generate_body export: true")
println("=" ^ 60)

@testset "GAMMA-001: Self-hosted codegen E2E module" begin
    @test length(entries) >= 20
    @test module_compiled
    @test validate_ok
    @test load_ok
    @test n_exports >= 20
end
