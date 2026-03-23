# build_int002_impl.jl — INT-002-impl: E2E codegen via multi-function module
#
# BREAKTHROUGH: generate_body(ICtx) validates with optimize=false (22KB).
# compile_from_ir_prebaked validates with optimize=true (22KB).
# Strategy: compile compile_from_ir_prebaked (opt=true) + generate_body (opt=false)
# + to_bytes_no_dict callees in one module. FunctionRegistry wires :invoke calls.
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_impl.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_codeinfo,
                  compile_from_ir_inplace, compile_from_ir_prebaked,
                  WasmModule, TypeRegistry, FunctionRegistry,
                  InplaceCompilationContext, AbstractCompilationContext,
                  IntKeyMap, WasmStackValidator,
                  wasm_bytes_length, wasm_bytes_get,
                  generate_body, generate_structured, generate_block_code,
                  analyze_blocks, BasicBlock,
                  fix_broken_select_instructions, fix_numeric_to_ref_local_stores,
                  fix_consecutive_local_sets, strip_excess_after_function_end,
                  fix_local_get_set_type_mismatch, fix_array_len_wrap,
                  fix_i64_local_in_i32_ops, fix_i32_wrap_after_i32_ops,
                  to_bytes_mvp, to_bytes_no_dict, get_concrete_wasm_type,
                  WasmValType, I32, I64, F32, F64, AnyRef, EqRef,
                  encode_leb128_unsigned,
                  _wasm_valtype_byte, ValidatorLabel,
                  populate_type_constant_globals!

println("=" ^ 70)
println("INT-002-impl: E2E Codegen — Multi-Function Module")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Pre-compute CodeInfo + verify native E2E
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: Pre-compute + native verify ---")

ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("Target: f(x::Int64) = x*x+1 → $(length(ci_f.code)) stmts")

native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("Native E2E: $(length(native_bytes)) bytes")

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Define entry function wrapping compile_from_ir_prebaked
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Define entry function ---")

const _baked_ci = ci_f

function wasm_codegen(mod::WasmModule, reg::TypeRegistry)::Vector{UInt8}
    entries = [(_baked_ci, Int64, (Int64,), "f")]
    return compile_from_ir_prebaked(entries, mod, reg)
end

# Verify native
test_bytes = wasm_codegen(WasmModule(), TypeRegistry(Val(:minimal)))
println("wasm_codegen native: $(length(test_bytes)) bytes")

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Collect all functions for the module
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Collect functions ---")

# Entry function (optimize=true — Julia inlines compile_from_ir_prebaked)
ci_entry, rt_entry = Base.code_typed(wasm_codegen, (WasmModule, TypeRegistry); optimize=true)[1]
n_inv_entry = count(x -> x isa Expr && x.head === :invoke, ci_entry.code)
println("Entry: $(length(ci_entry.code)) stmts, $n_inv_entry invokes")

# generate_body with optimize=FALSE — validates with ICtx!
ci_gb, rt_gb = Base.code_typed(generate_body, (InplaceCompilationContext,); optimize=false)[1]
println("generate_body(ICtx,opt=false): $(length(ci_gb.code)) stmts")

# to_bytes_mvp (closure-free serializer)
ci_tb, rt_tb = Base.code_typed(to_bytes_mvp, (Vector{UInt8}, Vector{WasmValType}); optimize=true)[1]
println("to_bytes_mvp: $(length(ci_tb.code)) stmts")

# Helper functions for JS interop
ci_mod, rt_mod = Base.code_typed(WasmModule, (); optimize=true)[1]
ci_reg, rt_reg = Base.code_typed(TypeRegistry, (Val{:minimal},); optimize=true)[1]
ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]

# Build entries list: (code_info, return_type, arg_types, name, func_ref)
all_entries = Any[
    (ci_entry, rt_entry, (WasmModule, TypeRegistry), "codegen", wasm_codegen),
    (ci_gb, rt_gb, (InplaceCompilationContext,), "generate_body", generate_body),
    (ci_tb, rt_tb, (Vector{UInt8}, Vector{WasmValType}), "to_bytes_mvp", to_bytes_mvp),
    (ci_mod, rt_mod, (), "new_mod", WasmModule),
    (ci_reg, rt_reg, (Val{:minimal},), "new_reg", TypeRegistry),
    (ci_len, rt_len, (Vector{UInt8},), "bytes_len", wasm_bytes_length),
    (ci_get, rt_get, (Vector{UInt8}, Int32), "bytes_get", wasm_bytes_get),
]

# Also try adding generate_structured and fix passes for wiring
opt_true_funcs = [
    (generate_structured, (InplaceCompilationContext, Vector{BasicBlock}), "generate_structured"),
    (generate_block_code, (InplaceCompilationContext, BasicBlock), "generate_block_code"),
    (analyze_blocks, (Vector{Any},), "analyze_blocks"),
    (fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select"),
    (fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets"),
    (strip_excess_after_function_end, (Vector{UInt8},), "strip_excess"),
    (fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap"),
    (fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32"),
    (fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_type"),
    (fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_in_i32"),
    (fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int), "fix_num_to_ref"),
    (get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_wasm_type"),
    (populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_globals"),
]

for (f, argtypes, name) in opt_true_funcs
    try
        ci, rt = Base.code_typed(f, argtypes; optimize=true)[1]
        push!(all_entries, (ci, rt, argtypes, name, f))
        println("  $name: $(length(ci.code)) stmts")
    catch e
        println("  $name: SKIP ($(sprint(showerror, e)[1:min(80,end)]))")
    end
end

println("\nTotal entries: $(length(all_entries))")

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Individual validation filter (INT-001 approach)
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 4: Individual validation ---")

valid_entries = Tuple[]
invalid_names = String[]
for (ci, rt, args, name, f) in all_entries
    local tmppath
    try
        bytes = WasmTarget.compile_from_codeinfo(ci, rt, name, args)
        tmppath = joinpath(tempdir(), "int002_$(name).wasm")
        write(tmppath, bytes)
        result = try read(`wasm-tools validate $tmppath`, String) catch e; "error" end
        rm(tmppath, force=true)
        if isempty(result)
            push!(valid_entries, (ci, rt, args, name, f))
            println("  ✓ $name: $(length(bytes)) bytes")
        else
            push!(invalid_names, name)
            println("  ✗ $name: FAIL")
        end
    catch e
        push!(invalid_names, name)
        println("  ✗ $name: ERROR")
    end
end

println("\nValidation: $(length(valid_entries))/$(length(all_entries)) pass")
if !isempty(invalid_names)
    println("Invalid: $(join(invalid_names, ", "))")
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Build combined module
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 5: Build combined module ---")

module_bytes = UInt8[]
module_compiled = false
n_exports = 0

# Try two approaches:
# A) Only validated functions (safe)
# B) ALL functions including codegen entry (might work in combined module)
for (label, entries_to_use) in [("validated-only", valid_entries), ("all-functions", all_entries)]
    println("\n  Building: $label ($(length(entries_to_use)) funcs)")
    try
        mod = compile_module_from_ir(entries_to_use)
        mbytes = WasmTarget.to_bytes(mod)
        println("  Module: $(length(mbytes)) bytes ($(round(length(mbytes)/1024, digits=1)) KB), $(length(mod.exports)) exports")

        tmppath = joinpath(tempdir(), "int002_combined_$(label).wasm")
        write(tmppath, mbytes)
        result = try read(`wasm-tools validate $tmppath`, String) catch e; "error" end
        rm(tmppath, force=true)
        valid = isempty(result)
        println("  wasm-tools validate: $(valid ? "PASS" : "FAIL: $(result[1:min(150,end)])")")

        if valid && !module_compiled
            module_bytes = mbytes
            module_compiled = true
            n_exports = length(mod.exports)
        end
    catch e
        println("  Build FAILED: $(sprint(showerror, e)[1:min(200,end)])")
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# Step 6: Validate + Node.js E2E test
# ═══════════════════════════════════════════════════════════════════════════

validate_ok = false
e2e_ok = false

if module_compiled
    println("\n--- Step 6: Validate + E2E test ---")
    output_path = joinpath(@__DIR__, "..", "..", "e2e-int002-impl.wasm")
    write(output_path, module_bytes)
    println("Written: $output_path")

    result = try read(`wasm-tools validate $output_path`, String) catch e; "error: $e" end
    validate_ok = isempty(result)
    println("wasm-tools validate: $(validate_ok ? "PASS" : "FAIL: $(result[1:min(200,end)])")")

    if validate_ok
        js_code = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');

        async function run() {
            try {
                const { instance } = await WebAssembly.instantiate(bytes, {
                    Math: { pow: Math.pow }
                });
                const e = instance.exports;
                console.log('Exports:', Object.keys(e).join(', '));

                let mod, reg;
                if (e.new_mod) { mod = e.new_mod(); console.log('WasmModule: ok'); }
                if (e.new_reg) { reg = e.new_reg(); console.log('TypeRegistry: ok'); }

                if (mod && reg && e.codegen) {
                    console.log('Running codegen...');
                    const wasm_output = e.codegen(mod, reg);

                    if (wasm_output && e.bytes_len && e.bytes_get) {
                        const len = e.bytes_len(wasm_output);
                        console.log('Output bytes:', len);
                        const output = new Uint8Array(len);
                        for (let i = 0; i < len; i++) output[i] = e.bytes_get(wasm_output, i + 1);

                        const { instance: inner } = await WebAssembly.instantiate(output);
                        const result = inner.exports.f(5n);
                        console.log('f(5n) =', result);
                        console.log('f(5n) === 26n:', result === 26n);
                        if (result === 26n) console.log('SUCCESS: TRUE SELF-HOSTING E2E!');
                    }
                }
            } catch (err) {
                console.log('Error:', err.message || err);
            }
        }
        run();
        """
        node_result = try read(`node -e $js_code`, String) catch e; "node error: $e" end
        println("\nNode.js E2E:")
        for line in split(node_result, '\n')
            println("  $line")
        end
        e2e_ok = occursin("f(5n) === 26n: true", node_result)
    end
end

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 70)
println("INT-002-impl SUMMARY")
println("=" ^ 70)
println("Native E2E: $(length(test_bytes)) bytes")
println("Entry function: $(length(ci_entry.code)) stmts, $n_inv_entry invokes")
println("Individual validation: $(length(valid_entries))/$(length(all_entries))")
println("Combined module: $(module_compiled ? "$(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)" : "FAILED")")
println("wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")
println("E2E f(5n)===26n: $(e2e_ok ? "SUCCESS" : "not yet")")
println("=" ^ 70)
