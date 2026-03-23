# build_e2e_selfhost_final.jl — INT-002-e2e-impl: Build the TRUE self-hosting E2E module
#
# Module: [run_selfhost_final, to_bytes_mvp, new_wasm_module, bytes_len, bytes_get]
# 5-function module, ~52KB, validates with wasm-tools.
#
# Run: julia +1.12 --project=. test/selfhost/build_e2e_selfhost_final.jl

using WasmTarget
using WasmTarget: run_selfhost_final, to_bytes_mvp_i64, new_wasm_module,
    wasm_bytes_length, wasm_bytes_get,
    compile_module_from_ir, compile_from_codeinfo, to_bytes,
    WasmModule, WasmValType

println("=" ^ 70)
println("INT-002-e2e-impl: TRUE Self-Hosting E2E Module")
println("=" ^ 70)

# Step 1: Native verification
println("\n--- Step 1: Native verification ---")
native_bytes = run_selfhost_final()
println("run_selfhost_final native: $(length(native_bytes)) bytes")
tmp = tempname() * ".wasm"
write(tmp, native_bytes)
node_out = strip(read(`node -e "WebAssembly.instantiate(require('fs').readFileSync('$tmp')).then(m=>console.log(String(m.instance.exports.f(5n))))"`, String))
rm(tmp, force=true)
println("f(5n) = $node_out (expected: 26)")
@assert node_out == "26" "Native E2E failed!"

# Step 2: Get code_typed for module functions
println("\n--- Step 2: Collect code_typed ---")
functions_spec = [
    (run_selfhost_final, (), "run"),
    (to_bytes_mvp_i64, (Vector{UInt8},), "to_bytes_mvp_i64"),
    (new_wasm_module, (), "new_wasm_module"),
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

entries = Any[]
for (func, arg_types, name) in functions_spec
    ci, rt = Base.code_typed(func, arg_types; optimize=true)[1]
    push!(entries, (ci, rt, arg_types, name, func))
    println("  $name: $(length(ci.code)) stmts")
end

# Step 3: Individual validation
println("\n--- Step 3: Individual validation ---")
for (ci, rt, arg_types, name, func) in entries
    try
        wasm_bytes = compile_from_codeinfo(ci, rt, name, arg_types)
        tmp = tempname() * ".wasm"
        write(tmp, wasm_bytes)
        run(`wasm-tools validate $tmp`)
        rm(tmp, force=true)
        println("  $name: $(length(wasm_bytes)) bytes, PASS ✓")
    catch e
        println("  $name: FAIL ✗")
    end
end

# Step 4: Build combined module
println("\n--- Step 4: Build combined module ---")
mod = compile_module_from_ir(entries)
combined_bytes = to_bytes(mod)
outpath = joinpath(@__DIR__, "selfhost-final.wasm")
write(outpath, combined_bytes)
println("Combined module: $(length(combined_bytes)) bytes ($(round(length(combined_bytes)/1024, digits=1)) KB)")

# Step 5: Validate combined module
println("\n--- Step 5: Validate combined module ---")
try
    run(`wasm-tools validate $outpath`)
    println("wasm-tools validate: PASS ✓")
catch
    println("wasm-tools validate: FAIL ✗")
    # Try to get error details
    try
        err = read(pipeline(`wasm-tools validate $outpath`, stderr=stdout), String)
        println("  $err")
    catch; end
end

# Step 6: Node.js E2E test
println("\n--- Step 6: Node.js E2E test ---")
node_script = raw"""
const fs = require('fs');
const bytes = fs.readFileSync(process.argv[2]);
WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } }).then(m => {
    const e = m.instance.exports;
    console.log('Exports:', Object.keys(e).join(', '));
    try {
        const result = e.run();
        console.log('run() returned GC ref');
        const len = e.wasm_bytes_length(result);
        console.log('Output bytes:', len);
        const wasmBytes = new Uint8Array(len);
        for (let i = 0; i < len; i++) {
            wasmBytes[i] = e.wasm_bytes_get(result, i + 1);
        }
        console.log('Extracted', wasmBytes.length, 'bytes');
        return WebAssembly.instantiate(wasmBytes);
    } catch(err) {
        console.log('TRAP:', err.message);
        process.exit(1);
    }
}).then(m2 => {
    if (!m2) return;
    const f = m2.instance.exports.f;
    const result = f(5n);
    console.log('f(5n) =', String(result));
    console.log('f(5n) === 26n:', result === 26n);
    if (result !== 26n) process.exit(1);
    console.log('SUCCESS: TRUE self-hosting E2E complete!');
}).catch(err => {
    console.log('ERROR:', err.message);
    process.exit(1);
});
"""

# Write script to temp file and run
script_path = tempname() * ".cjs"
write(script_path, node_script)
try
    result = read(`node $script_path $outpath`, String)
    println(result)
catch e
    println("Node.js test failed: $(sprint(showerror, e))")
    # Try to capture stderr too
    try
        result = read(pipeline(`node $script_path $outpath`, stderr=stdout), String)
        println(result)
    catch; end
end
rm(script_path, force=true)

println("\n" * "=" ^ 70)
println("Build complete: $outpath")
println("=" ^ 70)
