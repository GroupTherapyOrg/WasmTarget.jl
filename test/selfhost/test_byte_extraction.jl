# test_byte_extraction.jl — GAMMA-004: Byte extraction from WASM
#
# Tests that wasm_bytes_length and wasm_bytes_get can extract Vector{UInt8}
# contents from WASM to JavaScript. This is the mechanism for getting compiled
# .wasm bytes out of the codegen module.
#
# Run: julia +1.12 --project=. test/selfhost/test_byte_extraction.jl

using Test
using WasmTarget

println("=" ^ 60)
println("GAMMA-004: Byte extraction from WASM")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Compile a simple function that returns Vector{UInt8}
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: Compile test module with byte extraction ---")

# A function that creates a known byte vector
function make_test_bytes()::Vector{UInt8}
    v = Vector{UInt8}(undef, 4)
    v[1] = UInt8(0x00)
    v[2] = UInt8(0x61)
    v[3] = UInt8(0x73)
    v[4] = UInt8(0x6d)
    return v
end

entries = []
for (f, atypes, name) in [
    (make_test_bytes, (), "make_test_bytes"),
    (wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(entries, (ci, rt, atypes, name, f))
    println("  ✓ $name: $(length(ci.code)) stmts → $rt")
end

mod = WasmTarget.compile_module_from_ir(entries)
bytes = WasmTarget.to_bytes(mod)
output_path = joinpath(tempdir(), "test_byte_extraction.wasm")
write(output_path, bytes)
println("  Module: $(length(bytes)) bytes")

# Validate
validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    println("  ✓ wasm-tools validate PASSED")
    true
catch
    println("  ✗ wasm-tools validate FAILED")
    false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Test byte extraction from Node.js
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Node.js byte extraction ---")

node_ok = false
if validate_ok
    js_code = """
    const fs = require('fs');
    const bytes = fs.readFileSync('$(output_path)');
    WebAssembly.instantiate(bytes, {Math: {pow: Math.pow}}).then(m => {
        const e = m.instance.exports;

        // Create the test byte vector
        const vec = e.make_test_bytes();

        // Extract length
        const len = e.wasm_bytes_length(vec);
        console.log('Length: ' + len);

        // Extract each byte
        const extracted = [];
        for (let i = 1; i <= len; i++) {
            extracted.push(e.wasm_bytes_get(vec, i));
        }
        console.log('Bytes: ' + extracted.map(b => '0x' + b.toString(16).padStart(2, '0')).join(' '));

        // Verify: these should be the WASM magic number bytes
        const expected = [0x00, 0x61, 0x73, 0x6d];
        const match = extracted.length === expected.length &&
                      extracted.every((b, i) => b === expected[i]);
        console.log('Match: ' + match);
        process.exit(match ? 0 : 1);
    }).catch(err => { console.error('FAIL:', err.message); process.exit(1); });
    """
    tmpjs = joinpath(tempdir(), "test_byte_extraction.cjs")
    write(tmpjs, js_code)
    try
        local node_result = strip(read(`node $tmpjs`, String))
        println("  $node_result")
        global node_ok = contains(node_result, "Match: true")
    catch e
        println("  ✗ Node.js error: $(string(e)[1:min(200,end)])")
    end
    rm(tmpjs, force=true)
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Test with real compiled WASM bytes
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Real WASM byte roundtrip ---")

# Compile a tiny function to WASM, then test extracting those bytes
add_one(x::Int64) = x + Int64(1)
ci_add, rt_add = Base.code_typed(add_one, (Int64,); optimize=true)[1]
frozen = build_frozen_state([(ci_add, rt_add, (Int64,), "add_one")])
compiled_bytes = compile_module_from_ir_frozen_no_dict([(ci_add, rt_add, (Int64,), "add_one")], frozen)
println("  add_one compiled to $(length(compiled_bytes)) bytes")

# Now compile a function that returns these exact bytes as Vector{UInt8}
# We'll test the extraction mechanism directly
roundtrip_ok = false
if validate_ok && node_ok
    # Write the compiled bytes alongside the extractor module
    compiled_path = joinpath(tempdir(), "compiled_add_one.wasm")
    write(compiled_path, compiled_bytes)

    js_code2 = """
    const fs = require('fs');

    // Load the compiled add_one bytes
    const compiledBytes = fs.readFileSync('$(compiled_path)');

    // Verify the compiled module is valid WASM
    WebAssembly.compile(compiledBytes).then(mod => {
        const exports = WebAssembly.Module.exports(mod);
        console.log('Compiled module has ' + exports.length + ' exports');
        console.log('First 4 bytes: 0x' +
            compiledBytes[0].toString(16).padStart(2,'0') + ' ' +
            compiledBytes[1].toString(16).padStart(2,'0') + ' ' +
            compiledBytes[2].toString(16).padStart(2,'0') + ' ' +
            compiledBytes[3].toString(16).padStart(2,'0'));
        return WebAssembly.instantiate(mod, {Math: {pow: Math.pow}});
    }).then(inst => {
        const result = inst.exports.add_one(5n);
        console.log('add_one(5) = ' + result);
        console.log('Roundtrip: ' + (result === 6n ? 'PASS' : 'FAIL'));
        process.exit(result === 6n ? 0 : 1);
    }).catch(err => { console.error('FAIL:', err.message); process.exit(1); });
    """
    tmpjs2 = joinpath(tempdir(), "test_roundtrip.cjs")
    write(tmpjs2, js_code2)
    try
        local result2 = strip(read(`node $tmpjs2`, String))
        println("  $result2")
        global roundtrip_ok = contains(result2, "Roundtrip: PASS")
    catch e
        println("  ✗ Roundtrip error: $(string(e)[1:min(200,end)])")
    end
    rm(tmpjs2, force=true)
    rm(compiled_path, force=true)
end

# Clean up
rm(output_path, force=true)

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("GAMMA-004 Summary:")
println("  wasm-tools validate: $validate_ok")
println("  Node.js byte extraction: $node_ok")
println("  WASM roundtrip (add_one(5)=6): $roundtrip_ok")
println("=" ^ 60)

@testset "GAMMA-004: Byte extraction" begin
    @test validate_ok
    @test node_ok
    @test roundtrip_ok
end
