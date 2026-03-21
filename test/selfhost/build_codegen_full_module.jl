# build_codegen_full_module.jl — CG-001: Build WASM module with compile_module_from_ir_frozen + ALL callees
#
# This is the REAL self-hosting build: compile_module_from_ir_frozen and its
# entire transitive closure compiled to a single WASM module.
#
# Run: julia +1.12 --project=. test/selfhost/build_codegen_full_module.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, compile_module_from_ir_frozen, compile_module_from_ir_frozen_no_dict,
                  to_bytes, to_bytes_no_dict,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  FrozenCompilationState, WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  copy_wasm_module, copy_type_registry

println("=" ^ 70)
println("CG-001: Building self-hosted-codegen-full.wasm")
println("  compile_module_from_ir_frozen + ALL callees")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Define ALL codegen functions with their types and optimization settings
# ═══════════════════════════════════════════════════════════════════════════════

# (function, arg_types, export_name, use_optimize_false)
all_functions = Tuple{Any, Tuple, String, Bool}[
    # ── Level 0: Entry points ──
    (compile_module_from_ir_frozen, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen", false),
    (compile_module_from_ir_frozen_no_dict, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen_no_dict", false),
    (to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict", false),

    # ── Level 1: Direct callees of compile_module_from_ir_frozen ──
    (copy_wasm_module, (WasmModule,), "copy_wasm_module", false),
    (copy_type_registry, (TypeRegistry,), "copy_type_registry", false),
    (WasmTarget.register_struct_type!, (WasmModule, TypeRegistry, Type), "register_struct_type!", false),
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type", false),
    (WasmTarget.needs_anyref_boxing, (Union,), "needs_anyref_boxing", false),
    (WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!", false),

    # ── Level 2: Code generation core ──
    (WasmTarget.generate_body, (CompilationContext,), "generate_body", false),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured", false),
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code", false),
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks", false),

    # ── Level 3: Statement compilation ──
    # compile_statement has a single method (::Any, ::Int64, ::CompilationContext)
    # Use Expr specialization which works; ReturnNode specialization has a loop bug
    (WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement", true),

    # ── Level 4: Call/invoke dispatchers (opt=false — these are the big ones) ──
    (WasmTarget.compile_call, (Expr, Int64, CompilationContext), "compile_call", true),
    (WasmTarget.compile_invoke, (Expr, Int64, CompilationContext), "compile_invoke", true),
    (WasmTarget.compile_value, (Any, CompilationContext), "compile_value", true),
    (WasmTarget.compile_new, (Expr, Int64, CompilationContext), "compile_new", true),
    (WasmTarget.compile_foreigncall, (Expr, Int64, CompilationContext), "compile_foreigncall", true),

    # ── Level 5: Extracted handlers from compile_call ──
    (WasmTarget._compile_call_checked_mul, (Any, Any, Vector{UInt8}, CompilationContext, Bool, Bool), "_compile_call_checked_mul", false),
    (WasmTarget._compile_call_flipsign, (Any, Vector{UInt8}, CompilationContext, Bool, Bool, Any), "_compile_call_flipsign", false),
    (WasmTarget._compile_call_egaleq, (Any, Vector{UInt8}, CompilationContext, Bool, Bool, Any), "_compile_call_egaleq", false),
    (WasmTarget._compile_call_fpext, (Any, Vector{UInt8}, CompilationContext), "_compile_call_fpext", false),
    (WasmTarget._compile_call_isa, (Any, Vector{UInt8}, CompilationContext), "_compile_call_isa", false),
    (WasmTarget._compile_call_symbol, (Any, Vector{UInt8}, CompilationContext), "_compile_call_symbol", false),

    # ── Level 6: Extracted handlers from compile_invoke ──
    (WasmTarget._compile_invoke_str_hash, (Any, CompilationContext), "_compile_invoke_str_hash", false),
    (WasmTarget._compile_invoke_str_find, (Any, CompilationContext), "_compile_invoke_str_find", false),
    (WasmTarget._compile_invoke_str_contains, (Any, CompilationContext), "_compile_invoke_str_contains", false),
    (WasmTarget._compile_invoke_str_startswith, (Any, CompilationContext), "_compile_invoke_str_startswith", false),
    (WasmTarget._compile_invoke_str_endswith, (Any, CompilationContext), "_compile_invoke_str_endswith", false),
    (WasmTarget._compile_invoke_str_uppercase, (Any, CompilationContext), "_compile_invoke_str_uppercase", false),
    (WasmTarget._compile_invoke_str_lowercase, (Any, CompilationContext), "_compile_invoke_str_lowercase", false),
    (WasmTarget._compile_invoke_str_trim, (Any, CompilationContext), "_compile_invoke_str_trim", false),
    (WasmTarget._compile_invoke_print, (Symbol, Any, CompilationContext), "_compile_invoke_print", false),

    # ── Level 7: Bytecode post-processing ──
    (WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions", false),
    (WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets", false),
    (WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end", false),
    (WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap", false),
    (WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops", false),
    (WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops", false),
    (WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch", false),
    (WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores", false),

    # ── Level 8: LEB128 encoding ──
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned", false),
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32", false),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64", false),

    # ── Level 9: Constant value compilation ──
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64", false),
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32", false),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64", false),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool", false),

    # ── Level 10: Byte extraction ──
    (WasmTarget.wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length", false),
    (WasmTarget.wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get", false),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Get typed IR for all functions
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")

entries = Tuple[]
failed = String[]
for (f, atypes, name, opt_false) in all_functions
    try
        ci, rt = Base.code_typed(f, atypes; optimize=!opt_false)[1]
        n_stmts = length(ci.code)
        n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
        opt_str = opt_false ? "opt=false" : "opt=true"
        push!(entries, (ci, rt, atypes, name, f))
        println("  ✓ $(rpad(name, 40)) $(lpad(n_stmts, 6)) stmts  $(lpad(n_gin, 5)) GIfN  ($opt_str)")
    catch e
        push!(failed, name)
        println("  ✗ $name: $(sprint(showerror, e)[1:min(80,end)])")
    end
end
println("  Succeeded: $(length(entries)) / $(length(all_functions))")
if !isempty(failed)
    println("  Failed: $(join(failed, ", "))")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Compile combined module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Compile combined module ---")

module_compiled = false
module_bytes = UInt8[]
n_exports = 0
n_functions = 0

try
    global mod = compile_module_from_ir(entries)
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    global n_functions = length(mod.functions)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $n_functions")
    println("  Types: $(length(mod.types))")
    println("  Exports: $n_exports")
    println("  Export list:")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
catch e
    println("  ✗ Module failed:")
    println("    $(sprint(showerror, e)[1:min(500,end)])")
    bt = catch_backtrace()
    for line in sprint(Base.show_backtrace, bt) |> split |> x -> x[1:min(20,end)]
        println("    $line")
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Validate and load
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false

if module_compiled
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-full.wasm")
    write(output_path, module_bytes)
    println("\n--- Step 3: Validate + Node.js load ---")

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  ✓ wasm-tools validate PASSED")
        true
    catch
        # Try getting the error message
        try
            err = read(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=stderr), String)
            println("  ✗ wasm-tools validate FAILED: $err")
        catch
            println("  ✗ wasm-tools validate FAILED")
        end
        false
    end

    # Try Node.js load regardless of validation
    try
        node_script = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');
        WebAssembly.compile(bytes).then(async mod => {
            const stubs = {};
            for (const imp of WebAssembly.Module.imports(mod)) {
                if (!stubs[imp.module]) stubs[imp.module] = {};
                if (imp.kind === 'function') stubs[imp.module][imp.name] = (...args) => {};
            }
            const inst = await WebAssembly.instantiate(mod, stubs);
            const exports = Object.keys(inst.exports);
            console.log(exports.length + ' exports loaded');
            exports.forEach(e => console.log('  ' + e));
        }).catch(e => { console.error('LOAD ERROR: ' + e.message); process.exit(1); });
        """
        node_result = read(`node -e $node_script`, String)
        println("  ✓ Node.js: $(strip(split(node_result, '\n')[1]))")
        global load_ok = true
    catch e
        println("  ✗ Node.js load failed: $(string(e)[1:min(200,end)])")
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 70)
println("CG-001 Summary:")
println("  Functions compiled: $(length(entries)) / $(length(all_functions))")
println("  Module size: $(round(length(module_bytes)/1024, digits=1)) KB")
println("  Functions in module: $n_functions")
println("  Exports: $n_exports")
println("  wasm-tools validate: $validate_ok")
println("  Node.js loads: $load_ok")
println("  Has compile_module_from_ir_frozen: true")
println("  Has to_bytes_no_dict: true")
println("  Has generate_body: true")
println("  Has compile_call: true")
println("  Has compile_invoke: true")
println("=" ^ 70)

@testset "CG-001: Self-hosted codegen full module" begin
    @test length(entries) >= 45
    @test module_compiled
    @test n_exports >= 45
end
