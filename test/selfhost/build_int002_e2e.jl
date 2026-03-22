# build_int002_e2e.jl — INT-002: E2E true self-hosting
#
# Build a WASM module where the REAL codegen (compile_from_ir_prebaked)
# compiles f(x::Int64)=x*x+1 entirely inside WASM.
#
# Run: julia +1.12 --project=. test/selfhost/build_int002_e2e.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_from_ir_inplace,
                  compile_from_ir_prebaked, WasmModule, TypeRegistry,
                  wasm_bytes_length, wasm_bytes_get,
                  InplaceCompilationContext, AbstractCompilationContext

println("=" ^ 70)
println("INT-002: E2E True Self-Hosting — Codegen in WASM")
println("=" ^ 70)

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Pre-compute CodeInfo at build time (native Julia)
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: Pre-compute CodeInfo for f(x::Int64) = x*x+1 ---")

ci_f, rt_f = Base.code_typed(x -> x * x + Int64(1), (Int64,))[1]
println("  CodeInfo: $(length(ci_f.code)) statements, return type: $rt_f")

# Verify native E2E works
native_bytes = compile_from_ir_inplace([(ci_f, Int64, (Int64,), "f")])
println("  Native compile: $(length(native_bytes)) bytes")
tmpfile = tempname() * ".wasm"
write(tmpfile, native_bytes)
native_valid = try
    run(pipeline(`wasm-tools validate --features=gc $tmpfile`, stderr=devnull, stdout=devnull))
    true
catch; false; end
println("  Native validate: $(native_valid ? "PASS" : "FAIL")")
if native_valid
    node_out = read(`node -e "
    const bytes = require('fs').readFileSync('$tmpfile');
    WebAssembly.instantiate(bytes).then(m => {
        console.log(String(m.instance.exports.f(5n)));
    }).catch(e => console.error(e.message));
    "`, String)
    println("  Native f(5n) = $(strip(node_out))")
end
rm(tmpfile, force=true)

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Compile codegen function to WASM
# ═══════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Compile codegen to WASM ---")

# The all-in-one function that captures CodeInfo and runs the REAL codegen
# compile_from_ir_inplace now uses TypeRegistry(Val(:minimal)) — no Dict()
const _baked_ci = ci_f
const _baked_rt = rt_f

function wasm_compile_f()::Vector{UInt8}
    entries = [(_baked_ci, Int64, (Int64,), "f")]
    return compile_from_ir_inplace(entries)
end

# Verify wasm_compile_f works natively
test_bytes = wasm_compile_f()
println("  wasm_compile_f() natively: $(length(test_bytes)) bytes")

# Get typed IR for the all-in-one function
println("  Getting code_typed for wasm_compile_f...")
all_ci = Base.code_typed(wasm_compile_f, (); optimize=true)
if !isempty(all_ci)
    ci_all, rt_all = all_ci[1]
    n_stmts = length(ci_all.code)
    n_gotoifnots = count(x -> x isa Core.GotoIfNot, ci_all.code)
    println("  IR: $n_stmts stmts, $n_gotoifnots GotoIfNots, return: $rt_all")
else
    println("  ERROR: code_typed returned empty")
end

# Compile to WASM using compile_module_from_ir (single function)
println("  Compiling to WASM...")
try
    # Method 1: compile as single function via compile_module_from_ir
    ci_compile, rt_compile = Base.code_typed(wasm_compile_f, (); optimize=true)[1]
    entry = (ci_compile, rt_compile, (), "wasm_compile_f", wasm_compile_f)

    # Also add byte extraction functions
    ci_len, rt_len = Base.code_typed(wasm_bytes_length, (Vector{UInt8},); optimize=true)[1]
    entry_len = (ci_len, rt_len, (Vector{UInt8},), "wasm_bytes_length", wasm_bytes_length)

    ci_get, rt_get = Base.code_typed(wasm_bytes_get, (Vector{UInt8}, Int32); optimize=true)[1]
    entry_get = (ci_get, rt_get, (Vector{UInt8}, Int32), "wasm_bytes_get", wasm_bytes_get)

    all_entries = [entry, entry_len, entry_get]

    mod = compile_module_from_ir(all_entries)
    module_bytes = WasmTarget.to_bytes(mod)
    println("  Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Exports: $(length(mod.exports))")

    output_path = joinpath(@__DIR__, "..", "..", "e2e-int002.wasm")
    write(output_path, module_bytes)

    # Validate
    valid = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  wasm-tools validate: PASS")
        true
    catch
        err_out = try read(pipeline(`wasm-tools validate --features=gc $output_path`; stderr=stderr), String) catch ex; sprint(showerror, ex) end
        println("  wasm-tools validate: FAIL")
        println("    $(string(err_out)[1:min(300,end)])")
        false
    end

    if valid
        # Test in Node.js — THE CRITICAL TEST
        println("\n--- Step 3: Execute codegen in WASM → f(5n)===26n ---")
        node_script = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');
        WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(async ({instance}) => {
            const e = instance.exports;
            console.log('Exports:', Object.keys(e).join(', '));

            // Call the codegen function — this runs compile_from_ir_prebaked IN WASM
            console.log('Calling wasm_compile_f()...');
            try {
                const wasm_output = e.wasm_compile_f();
                console.log('Codegen returned:', wasm_output);

                if (wasm_output === null) {
                    console.log('ERROR: codegen returned null');
                    process.exit(1);
                }

                // Extract bytes from WasmGC Vector{UInt8}
                const len = e.wasm_bytes_length(wasm_output);
                console.log('Output WASM size:', len, 'bytes');

                const output_bytes = new Uint8Array(len);
                for (let i = 0; i < len; i++) {
                    output_bytes[i] = e.wasm_bytes_get(wasm_output, i + 1);  // 1-based
                }

                // Compile the output WASM
                const compiled = await WebAssembly.instantiate(output_bytes);
                const f = compiled.instance.exports.f;
                const result = f(5n);
                console.log('f(5n) =', String(result));

                if (result === 26n) {
                    console.log('SUCCESS: f(5n) === 26n — REAL codegen executing in WASM!');
                } else {
                    console.log('WRONG: expected 26n, got', String(result));
                }
            } catch(err) {
                console.log('TRAP:', err.message);
                process.exit(1);
            }
        }).catch(e => {
            console.error('Load failed:', e.message);
            process.exit(1);
        });
        """
        try
            node_result = read(`node -e $node_script`, String)
            println(strip(node_result))
        catch e
            println("  Node.js execution failed: $(sprint(showerror, e)[1:min(300,end)])")
        end
    end
catch e
    println("  Compilation FAILED: $(sprint(showerror, e)[1:min(500,end)])")
    println("  Backtrace:")
    for (exc, bt) in current_exceptions()
        showerror(stdout, exc, bt; backtrace=true)
        println()
    end
end

println("\n" * "=" ^ 70)
println("INT-002 build complete")
println("=" ^ 70)
