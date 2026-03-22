# build_e2e_full.jl — Build E2E module: wasm_compile_baked + ALL codegen callees
#
# This builds a WASM module that can compile f(x::Int64)=x*x+1 entirely in WASM.
# Key insight: compile_from_ir_inplace avoids Dict (uses TypeRegistry_minimal)
# and avoids copy_wasm_module/copy_type_registry (no FrozenCompilationState).
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_full.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  wasm_bytes_length, wasm_bytes_get

println("=" ^ 70)
println("Building E2E full module (compile_from_ir_inplace + all callees)")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════
# Bake the CodeInfo at module load time
# ═══════════════════════════════════════════════════════════════════
ci_baked, rt_baked = Base.code_typed(x -> x * x + 1, (Int64,); optimize=true)[1]
entries_baked = [(ci_baked, rt_baked, (Int64,), "f")]

function wasm_compile_baked()::Vector{UInt8}
    return compile_from_ir_inplace(entries_baked)
end

# ═══════════════════════════════════════════════════════════════════
# Function list: wasm_compile_baked (opt=true) + callees (opt varies)
# ═══════════════════════════════════════════════════════════════════

all_functions = Tuple{Any, Tuple, String, Bool}[
    # ── Entry point: baked compiler ──
    (wasm_compile_baked, (), "wasm_compile_baked", false),

    # ── Level 1: Direct callees of compile_from_ir_inplace ──
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type", false),
    (WasmTarget.needs_anyref_boxing, (Union,), "needs_anyref_boxing", false),
    (WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!", false),

    # ── Level 2: Code generation core ──
    (WasmTarget.generate_body, (CompilationContext,), "generate_body", false),
    (WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured", false),
    (WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code", false),
    (WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks", false),

    # ── Level 3: Statement compilation (opt=false — large) ──
    (WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement", true),

    # ── Level 4: Call/invoke dispatchers (opt=false — large) ──
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

    # ── Level 8: LEB128 + serialization ──
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned", false),
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32", false),
    (encode_leb128_signed, (Int64,), "encode_leb128_signed_i64", false),
    (WasmTarget.to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict", false),

    # ── Level 9: Constant value compilation ──
    (compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64", false),
    (compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32", false),
    (compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64", false),
    (compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool", false),

    # ── Level 10: Byte extraction ──
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length", false),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get", false),
]

# ═══════════════════════════════════════════════════════════════════
# Compile
# ═══════════════════════════════════════════════════════════════════

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
println("  Succeeded: $(length(entries))/$(length(all_functions))")
!isempty(failed) && println("  Failed: $(join(failed, ", "))")

println("\n--- Step 2: Compile combined module ---")
module_bytes = UInt8[]
try
    global mod = compile_module_from_ir(entries)
    global module_bytes = WasmTarget.to_bytes(mod)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Functions: $(length(mod.functions)), Exports: $(length(mod.exports))")
catch e
    println("  ✗ FAILED: $(sprint(showerror, e)[1:min(500,end)])")
    rethrow()
end

output_path = joinpath(@__DIR__, "..", "..", "self-hosted-e2e-full.wasm")
write(output_path, module_bytes)

println("\n--- Step 3: Validate ---")
validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    println("  ✓ wasm-tools validate PASSED")
    true
catch
    # Get the error
    err_out = try
        read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr), String)
    catch ex
        sprint(showerror, ex)
    end
    println("  ✗ wasm-tools validate FAILED")
    println("    $(err_out[1:min(200,end)])")
    false
end

# Also validate individual functions
if !validate_ok
    println("\n--- Step 3b: Individual function validation ---")
    pass = 0
    fail = 0
    for (i, (ci, rt, atypes, name, f)) in enumerate(entries)
        try
            single_bytes = WasmTarget.compile(f, atypes)
            tmp = tempname() * ".wasm"
            write(tmp, single_bytes)
            run(pipeline(`wasm-tools validate --features=gc $tmp`, stderr=devnull, stdout=devnull))
            pass += 1
            rm(tmp; force=true)
        catch
            fail += 1
            println("    FAIL: $name")
        end
    end
    println("  Individual: $pass pass, $fail fail")
end

println("\n--- Step 4: Node.js E2E ---")
if validate_ok
    node_script = """
    const fs = require("fs");
    (async () => {
        const bytes = fs.readFileSync("$(output_path)");
        const mod = await WebAssembly.compile(bytes);
        const stubs = {};
        for (const imp of WebAssembly.Module.imports(mod)) {
            if (!stubs[imp.module]) stubs[imp.module] = {};
            if (imp.kind === "function") stubs[imp.module][imp.name] = (...args) => {};
        }
        const inst = await WebAssembly.instantiate(mod, stubs);
        const { wasm_compile_baked, wasm_bytes_length, wasm_bytes_get } = inst.exports;

        console.log("Calling wasm_compile_baked()...");
        const wasm_output = wasm_compile_baked();
        const len = wasm_bytes_length(wasm_output);
        console.log("Output: " + len + " bytes");

        const output_bytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            output_bytes[i] = wasm_bytes_get(wasm_output, i + 1);
        }

        const output_mod = await WebAssembly.compile(output_bytes);
        const output_inst = await WebAssembly.instantiate(output_mod);
        const f = output_inst.exports.f;
        const result = f(5n);
        console.log("f(5n) = " + result);
        console.log("f(5n) === 26n: " + (result === 26n));

        if (result === 26n) {
            console.log("SUCCESS: TRUE SELF-HOSTING — f(5n)===26n via REAL codegen in WASM");
        } else {
            console.log("WRONG RESULT");
            process.exit(1);
        }
    })();
    """
    try
        result = read(`node -e $node_script`, String)
        println(result)
    catch e
        println("  Node.js error: $(string(e)[1:min(200,end)])")
    end
else
    println("  Skipped (module doesn't validate)")
end

println("\n" * "=" ^ 70)
println("Summary: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(entries)) functions, validates=$validate_ok")
println("=" ^ 70)
