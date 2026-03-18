# PHASE-1M-004: Exploratory compilation of codegen functions to WASM
#
# Goal: Try to compile each pure codegen function and see what works/fails.
# This is step 1 — understanding what's feasible.
#
# Run: julia +1.12 --project=. test/selfhost/explore_codegen_compilation.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, get_typed_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned

println("=" ^ 60)
println("PHASE-1M-004: Exploring codegen function compilation")
println("=" ^ 60)

# Helper: try to compile a function and report result
function try_compile(f, arg_types, name)
    print("  $name$(arg_types): ")
    try
        ci, rt = Base.code_typed(f, arg_types)[1]
        ir_entries = [(ci, rt, arg_types, name)]
        mod = compile_module_from_ir(ir_entries)
        bytes = to_bytes(mod)
        println("OK — $(length(bytes)) bytes, returns $rt")
        return (true, bytes, rt)
    catch e
        msg = sprint(showerror, e)
        short = length(msg) > 120 ? msg[1:120] * "..." : msg
        println("FAIL — $short")
        return (false, nothing, nothing)
    end
end

# ─── Test 1: encode_leb128 functions (simplest — pure byte emission) ─────────
println("\n--- Level 0: Encoding functions ---")
try_compile(encode_leb128_signed, (Int32,), "encode_leb128_signed")
try_compile(encode_leb128_signed, (Int64,), "encode_leb128_signed")
try_compile(encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned")

# ─── Test 2: compile_const_value (simple codegen, takes concrete val type) ────
println("\n--- Level 1: compile_const_value (specialized) ---")
try_compile(compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32")
try_compile(compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64")
try_compile(compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64")
try_compile(compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool")

# ─── Test 3: get_concrete_wasm_type (type mapping) ──────────────────────────
println("\n--- Level 2: get_concrete_wasm_type ---")
try_compile(get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type")

# ─── Test 4: Simple analysis functions ───────────────────────────────────────
println("\n--- Level 3: Analysis functions ---")
try
    # analyze_basic_blocks takes (code_info, ...) — check signature
    analyze_fn = WasmTarget.analyze_basic_blocks
    m = methods(analyze_fn)
    println("  analyze_basic_blocks: $(length(m)) methods")
    for method in m
        println("    $method")
    end
catch e
    println("  analyze_basic_blocks: not accessible — $e")
end

try
    analyze_fn = WasmTarget.analyze_loop_headers
    m = methods(analyze_fn)
    println("  analyze_loop_headers: $(length(m)) methods")
    for method in m
        println("    $method")
    end
catch e
    println("  analyze_loop_headers: not accessible — $e")
end

# ─── Test 5: generate_body (the main target) ─────────────────────────────────
println("\n--- Level 4: generate_body ---")
try_compile(WasmTarget.generate_body, (CompilationContext,), "generate_body")

println("\n=== Exploration complete ===")
