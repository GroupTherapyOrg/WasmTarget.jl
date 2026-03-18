# PHASE-1M-004: Build self-hosted-codegen-mini.wasm (v2 — targeted subset)
#
# Strategy: compile the functions that compile in seconds individually,
# then assemble into a multi-function module. The massive functions
# (compile_statement: 24K stmts, compile_call: 132K, compile_invoke: 146K)
# are excluded from this iteration — they need optimization work.
#
# Run: julia +1.12 --project=. test/selfhost/build_mini_codegen_v2.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, get_typed_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  build_frozen_state, compile_module_from_ir_frozen,
                  preprocess_ir_entries

using JSON, Dates

println("=" ^ 60)
println("PHASE-1M-004: Building self-hosted-codegen-mini.wasm (v2)")
println("=" ^ 60)

# ─── Step 1: Define the mini codegen function set ───────────────────────────
# These are functions that compiled individually in <30s each.
# They represent the core building blocks of the codegen pipeline.

codegen_functions = [
    # Level 0: Byte encoding (pure arithmetic + Vector{UInt8})
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64"),
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"),

    # Level 1: Constant value compilation (specialized per-type)
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32"),
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64"),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64"),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool"),

    # Level 2: Type mapping
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type"),

    # Level 3: Main entry point (calls into compile_statement etc. — stubs for now)
    (WasmTarget.generate_body, (CompilationContext,), "generate_body"),
]

println("  Functions: $(length(codegen_functions))")

# ─── Step 2: Get typed IR ──────────────────────────────────────────────────
println("\n--- Step 2: Getting typed IR ---")

ir_entries = []
for (f, arg_types, name) in codegen_functions
    ci, ret_type = Base.code_typed(f, arg_types)[1]
    push!(ir_entries, (ci, ret_type, arg_types, name))
    println("  $name: $(length(ci.code)) stmts → $ret_type")
end

# ─── Step 3: Note on GlobalRef preprocessing ────────────────────────────────
# GlobalRef preprocessing (PHASE-1M-003) is for Phase 1-009 (CodeInfo transport).
# For PHASE-1M-004, we compile the codegen functions directly — they keep their
# GlobalRefs and the compiler handles them natively during compilation.
println("\n--- Step 3: Skipping GlobalRef preprocessing (not needed for compilation) ---")

# ─── Step 4: Compile to multi-function WASM ─────────────────────────────────
println("\n--- Step 4: Compiling multi-function WASM module ---")
t0 = time()
mod = compile_module_from_ir(ir_entries)
bytes = to_bytes(mod)
elapsed = time() - t0

println("  $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB) in $(round(elapsed, digits=2))s")
println("  Functions: $(length(mod.functions))")
println("  Types: $(length(mod.types))")
println("  Exports: $(length(mod.exports))")

for exp in mod.exports
    println("    - $(exp.name) (kind=$(exp.kind), idx=$(exp.idx))")
end

# ─── Step 5: Save and validate ──────────────────────────────────────────────
output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-mini.wasm")
write(output_path, bytes)
println("\n--- Step 5: Saved to $output_path ---")

# Validate with wasm-tools
wasm_tools = Sys.which("wasm-tools")
if wasm_tools !== nothing
    println("  wasm-tools validate:")
    try
        output = Base.read(pipeline(`$(wasm_tools) validate $(output_path)`, stderr=stdout), String)
        println("  PASS")
    catch e
        println("  FAIL — trying with features...")
        try
            output = Base.read(`$(wasm_tools) validate --features all $(output_path)`, String)
            println("  PASS (with --features all)")
        catch e2
            # Get the actual error
            try
                err = Base.read(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stderr=stdout), String)
                println("  FAIL: $err")
            catch e3
                println("  FAIL: $(sprint(showerror, e3))")
            end
        end
    end
end

# Test loading in Node.js
node = Sys.which("node")
if node !== nothing
    println("\n  Node.js load test:")
    js_code = """
    const fs = require('fs');
    const buf = fs.readFileSync('$(output_path)');
    WebAssembly.compile(buf).then(mod => {
        const exps = WebAssembly.Module.exports(mod);
        console.log('OK: ' + exps.length + ' exports');
        exps.forEach(e => console.log('  ' + e.name + ' (' + e.kind + ')'));
    }).catch(e => {
        console.error('FAIL: ' + e.message.substring(0, 200));
        process.exit(1);
    });
    """
    try
        result = Base.read(`$(node) -e $(js_code)`, String)
        print("  $result")
    catch e
        println("  Node.js FAIL: $(sprint(showerror, e))")
    end
end

# ─── Step 6: Save build metadata ───────────────────────────────────────────
println("\n--- Step 6: Build metadata ---")

metadata = Dict(
    "story" => "PHASE-1M-004",
    "timestamp" => string(Dates.now()),
    "version" => "v2-targeted",
    "functions_compiled" => length(codegen_functions),
    "function_names" => [name for (_, _, name) in codegen_functions],
    "wasm_bytes" => length(bytes),
    "wasm_kb" => round(length(bytes)/1024, digits=1),
    "compile_time_s" => round(elapsed, digits=2),
    "module_functions" => length(mod.functions),
    "module_types" => length(mod.types),
    "module_exports" => length(mod.exports),
    "excluded_large_functions" => [
        "compile_statement (24K stmts — too large for initial build)",
        "compile_call (132K stmts — too large for initial build)",
        "compile_invoke (146K stmts — too large for initial build)",
    ],
    "acceptance" => length(bytes) < 5_000_000 ? "PASS (< 5 MB)" : "FAIL (> 5 MB)",
)

meta_path = joinpath(@__DIR__, "mini_codegen_build_results.json")
open(meta_path, "w") do io
    JSON.print(io, metadata, 2)
end
println("  Saved to $meta_path")

println("\n=== PHASE-1M-004 v2: Build complete ===")
println("  Size: $(round(length(bytes)/1024, digits=1)) KB (budget: 5 MB)")
println("  Functions: $(length(codegen_functions)) compiled")
println("  Status: Level 0-3 codegen compiled and assembled")
