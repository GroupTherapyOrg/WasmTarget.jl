# PHASE-1M-004: Build self-hosted-codegen-mini.wasm
#
# Compiles the pure codegen functions to WasmGC as a multi-function module.
# Uses frozen state (PHASE-1M-002) and pre-resolved GlobalRefs (PHASE-1M-003).
#
# Run: julia +1.12 --project=. test/selfhost/build_mini_codegen.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, get_typed_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  build_frozen_state, compile_module_from_ir_frozen,
                  preprocess_ir_entries

println("=" ^ 60)
println("PHASE-1M-004: Building self-hosted-codegen-mini.wasm")
println("=" ^ 60)

# ─── Step 1: Identify all codegen functions to compile ──────────────────────
println("\n--- Step 1: Identifying codegen functions ---")

# The pure codegen functions from PHASE-1M-001 profiling:
codegen_functions = Tuple{Any, Tuple, String}[]

# Level 0: Byte encoding (foundational)
push!(codegen_functions, (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"))
push!(codegen_functions, (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64"))
push!(codegen_functions, (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"))

# Level 1: Constant compilation (specialized by value type)
push!(codegen_functions, (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32"))
push!(codegen_functions, (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64"))
push!(codegen_functions, (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64"))
push!(codegen_functions, (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool"))

# Level 2: Type mapping
push!(codegen_functions, (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type"))

# Level 3: Main codegen entry point
push!(codegen_functions, (WasmTarget.generate_body, (CompilationContext,), "generate_body"))

# Level 4: Statement/value/call compilation
push!(codegen_functions, (WasmTarget.compile_statement, (Any, Int, CompilationContext), "compile_statement"))
push!(codegen_functions, (WasmTarget.compile_value, (Any, CompilationContext), "compile_value"))
push!(codegen_functions, (WasmTarget.compile_call, (Expr, Int, CompilationContext), "compile_call"))
push!(codegen_functions, (WasmTarget.compile_invoke, (Expr, Int, CompilationContext), "compile_invoke"))

println("  Functions to compile: $(length(codegen_functions))")
for (f, argtypes, name) in codegen_functions
    println("    - $name$(argtypes)")
end

# ─── Step 2: Get typed IR for each function ─────────────────────────────────
println("\n--- Step 2: Getting typed IR ---")

ir_entries = []
failed = String[]
for (f, arg_types, name) in codegen_functions
    try
        ci, ret_type = Base.code_typed(f, arg_types)[1]
        push!(ir_entries, (ci, ret_type, arg_types, name))
        n_stmts = length(ci.code)
        println("  ✓ $name: $n_stmts stmts, returns $ret_type")
    catch e
        push!(failed, "$name: $(sprint(showerror, e))")
        println("  ✗ $name: FAILED to get IR")
    end
end

if !isempty(failed)
    println("\n  FAILED IR extraction:")
    for msg in failed
        println("    $msg")
    end
end

# ─── Step 3: Pre-process IR (resolve GlobalRefs) ───────────────────────────
println("\n--- Step 3: Pre-processing IR (GlobalRef resolution) ---")

preprocessed = preprocess_ir_entries(ir_entries)
println("  Preprocessed $(length(preprocessed)) IR entries")

# ─── Step 4: Compile to multi-function WASM module ──────────────────────────
println("\n--- Step 4: Compiling to WASM ---")

t0 = time()
try
    mod = compile_module_from_ir(preprocessed)
    bytes = to_bytes(mod)
    elapsed = time() - t0

    println("  SUCCESS: $(length(bytes)) bytes in $(round(elapsed, digits=2))s")
    println("  Size: $(round(length(bytes)/1024, digits=1)) KB")

    # Save the module
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-mini.wasm")
    write(output_path, bytes)
    println("  Saved to: $output_path")

    # List exports
    println("\n  Exports:")
    for exp in mod.exports
        println("    - $(exp.name) (kind=$(exp.kind), idx=$(exp.index))")
    end

catch e
    elapsed = time() - t0
    println("  FAILED after $(round(elapsed, digits=2))s")
    println("  Error: $(sprint(showerror, e))")

    # Try individual compilation to find the problematic function
    println("\n  Trying individual compilation to isolate failures...")
    for (ci, ret_type, arg_types, name) in preprocessed
        try
            mod_single = compile_module_from_ir([(ci, ret_type, arg_types, name)])
            bytes_single = to_bytes(mod_single)
            println("    ✓ $name: $(length(bytes_single)) bytes")
        catch e2
            msg = sprint(showerror, e2)
            short = length(msg) > 80 ? msg[1:80] * "..." : msg
            println("    ✗ $name: $short")
        end
    end
end

# ─── Step 5: Validate with wasm-tools ──────────────────────────────────────
output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-mini.wasm")
if isfile(output_path)
    println("\n--- Step 5: Validation ---")
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools !== nothing
        result = try
            Base.run(pipeline(`$(wasm_tools) validate $(output_path)`, stderr=devnull))
            "PASS"
        catch
            # Try with GC features
            try
                Base.run(pipeline(`$(wasm_tools) validate --features gc,reference-types,exception-handling $(output_path)`, stderr=devnull))
                "PASS (with features)"
            catch
                "FAIL"
            end
        end
        println("  wasm-tools validate: $result")
    else
        println("  wasm-tools not found — skipping validation")
    end

    # Try loading in Node.js
    node = Sys.which("node")
    if node !== nothing
        js_test = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');
        WebAssembly.compile(bytes).then(mod => {
            const exports = WebAssembly.Module.exports(mod);
            console.log('Module loaded: ' + exports.length + ' exports');
            exports.forEach(e => console.log('  ' + e.name + ' (' + e.kind + ')'));
        }).catch(e => {
            console.error('FAIL: ' + e.message);
            process.exit(1);
        });
        """
        println("\n  Node.js loading test:")
        try
            node_result = Base.read(`$(node) -e $(js_test)`, String)
            println("  $node_result")
        catch e
            println("  Node.js test failed: $(sprint(showerror, e))")
        end
    end
end

println("\n=== PHASE-1M-004: Build complete ===")
