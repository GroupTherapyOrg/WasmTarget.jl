# PHASE-1M-004: Build self-hosted-codegen-mini.wasm (v4 — manual function list)
#
# Strategy: Manually list ALL known codegen functions with exact signatures.
# Compile each individually to verify it works, then assemble together.
# Phase 1-mini target: arithmetic + simple conditionals (no loops/try-catch).
#
# Run: julia +1.12 --project=. test/selfhost/build_mini_codegen_v4.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  BasicBlock, WasmValType

using JSON, Dates

println("=" ^ 60)
println("PHASE-1M-004: Building self-hosted-codegen-mini.wasm (v4)")
println("  Strategy: manual function list, individual validation")
println("=" ^ 60)

# ─── Step 1: Define ALL codegen functions with exact signatures ───────────

codegen_functions = [
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

    # Level 4: Bytecode post-processing (fix_* functions)
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

    # Level 6: Main entry point
    (WasmTarget.generate_body, (CompilationContext,), "generate_body"),
]

# ─── Step 2: Get IR and validate each individually ────────────────────────

println("\n--- Step 2: Getting typed IR for $(length(codegen_functions)) functions ---")

ir_entries = []
failed = []
for (f, arg_types, name) in codegen_functions
    try
        ci, rt = Base.code_typed(f, arg_types)[1]
        push!(ir_entries, (ci, rt, arg_types, name, f))
        println("  ✓ $name: $(length(ci.code)) stmts → $rt")
    catch e
        push!(failed, (name, e))
        println("  ✗ $name: $(sprint(showerror, e)[1:min(120,end)])")
    end
end

println("\n  $(length(ir_entries)) succeeded, $(length(failed)) failed")

# ─── Step 3: Compile individually first to find any single-function issues ─

println("\n--- Step 3: Individual compilation test ---")
individual_results = Dict{String, Any}()

for (ci, rt, arg_types, name, f) in ir_entries
    try
        mod = compile_module_from_ir([(ci, rt, arg_types, name)])
        bytes = to_bytes(mod)
        # Quick validate
        output_path = "/tmp/test_$(name).wasm"
        write(output_path, bytes)
        wasm_tools = Sys.which("wasm-tools")
        valid = false
        if wasm_tools !== nothing
            try
                run(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stdout=devnull, stderr=devnull))
                valid = true
            catch
            end
        end
        individual_results[name] = (bytes=length(bytes), valid=valid)
        status = valid ? "✓ VALID" : "✗ INVALID"
        println("  $status $name: $(length(bytes)) bytes")
    catch e
        individual_results[name] = (bytes=0, valid=false, error=sprint(showerror, e)[1:min(200,end)])
        println("  ✗ FAIL $name: $(sprint(showerror, e)[1:min(100,end)])")
    end
end

valid_count = count(v -> v.valid, values(individual_results))
println("\n  $(valid_count)/$(length(individual_results)) validate individually")

# ─── Step 4: Compile valid functions together ─────────────────────────────

println("\n--- Step 4: Multi-function assembly ---")

# Use only functions that validated individually
valid_entries = []
for (ci, rt, arg_types, name, f) in ir_entries
    if haskey(individual_results, name) && individual_results[name].valid
        push!(valid_entries, (ci, rt, arg_types, name, f))
    end
end

println("  Assembling $(length(valid_entries)) validated functions...")

t0 = time()
try
    mod = compile_module_from_ir(valid_entries)
    bytes = to_bytes(mod)
    elapsed = time() - t0

    println("  SUCCESS: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB) in $(round(elapsed, digits=1))s")
    println("  Functions: $(length(mod.functions))")
    println("  Types: $(length(mod.types))")
    println("  Exports: $(length(mod.exports))")

    for exp in mod.exports
        println("    - $(exp.name)")
    end

    # Save
    output_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-mini.wasm")
    write(output_path, bytes)
    println("\n  Saved to $output_path")

    # Validate
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools !== nothing
        try
            run(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stdout=devnull, stderr=devnull))
            println("  wasm-tools validate: PASS")
        catch
            err = try Base.read(pipeline(`$(wasm_tools) validate --features all $(output_path)`, stderr=stdout), String) catch; "unknown" end
            println("  wasm-tools validate: FAIL")
            println("    $err")
        end
    end

    # Node.js test
    node = Sys.which("node")
    if node !== nothing
        js_code = """
        const fs = require('fs');
        const buf = fs.readFileSync('$(output_path)');
        WebAssembly.compile(buf).then(mod => {
            const exps = WebAssembly.Module.exports(mod);
            console.log('Node.js: OK, ' + exps.length + ' exports');
            exps.forEach(e => console.log('  ' + e.name + ' (' + e.kind + ')'));
        }).catch(e => {
            console.error('Node.js FAIL: ' + e.message.substring(0, 300));
            process.exit(1);
        });
        """
        try
            result = Base.read(`$(node) -e $(js_code)`, String)
            print("  $result")
        catch e
            println("  Node.js: FAIL")
        end
    end

    # Save metadata
    metadata = Dict(
        "story" => "PHASE-1M-004",
        "timestamp" => string(Dates.now()),
        "version" => "v4-manual",
        "functions_attempted" => length(codegen_functions),
        "functions_compiled" => length(valid_entries),
        "function_names" => [name for (_, _, _, name) in valid_entries],
        "individually_valid" => valid_count,
        "wasm_bytes" => length(bytes),
        "wasm_kb" => round(length(bytes)/1024, digits=1),
        "compile_time_s" => round(elapsed, digits=1),
        "module_functions" => length(mod.functions),
        "module_types" => length(mod.types),
        "module_exports" => length(mod.exports),
        "acceptance_size" => length(bytes) < 5_000_000 ? "PASS (< 5 MB)" : "FAIL (> 5 MB)",
    )

    meta_path = joinpath(@__DIR__, "mini_codegen_build_results.json")
    open(meta_path, "w") do io
        JSON.print(io, metadata, 2)
    end
    println("\n  Metadata saved")

catch e
    elapsed = time() - t0
    println("  FAILED after $(round(elapsed, digits=1))s")
    println("  $(sprint(showerror, e)[1:min(500,end)])")
end

println("\n=== PHASE-1M-004 v4 complete ===")
