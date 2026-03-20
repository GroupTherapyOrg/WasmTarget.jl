# METH-002: Test return type table in unified codegen module
#
# Adds composite_hash and lookup_return_type to the codegen E2E module.
# Verifies from Node.js: create table, populate, lookup.
#
# Run: julia +1.12 --project=. test/selfhost/test_return_type_in_module.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  BasicBlock, WasmValType

# Load return type table functions
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "return_type_table.jl"))

println("=" ^ 60)
println("METH-002: Return type table in codegen module")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Define functions — existing codegen + return type table
# ═══════════════════════════════════════════════════════════════════════════════

all_functions = [
    # ─── Existing codegen functions (subset for faster build) ─────────
    # Byte encoding
    (encode_leb128_signed, (Int32,), "encode_leb128_signed_i32"),
    (encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned"),
    # I32 vector builders (needed for table construction from JS)
    (WasmTarget.wasm_create_i32_vector, (Int32,), "wasm_create_i32_vector"),
    (WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32), "wasm_set_i32"),
    (WasmTarget.wasm_i32_vector_length, (Vector{Int32},), "wasm_i32_vector_length"),

    # ─── METH-002: Return type table functions ────────────────────────
    (composite_hash, (Int32, Vector{Int32}), "composite_hash"),
    (lookup_return_type, (Vector{Int32}, UInt32), "lookup_return_type"),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Get typed IR
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")

entries = Tuple[]
for (f, atypes, name) in all_functions
    try
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        push!(entries, (ci, rt, atypes, name, f))
        println("  ✓ $name ($(length(ci.code)) stmts)")
    catch e
        println("  ✗ $name — $(sprint(showerror, e)[1:min(120,end)])")
    end
end
println("  Total: $(length(entries))")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Compile combined module
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Compile combined module ---")

module_compiled = false
module_bytes = UInt8[]
n_exports = 0

try
    mod = compile_module_from_ir(entries)
    global module_bytes = to_bytes(mod)
    global module_compiled = true
    global n_exports = length(mod.exports)
    println("  ✓ Module: $(length(module_bytes)) bytes ($(round(length(module_bytes)/1024, digits=1)) KB)")
    println("  Exports: $n_exports")
    for exp in mod.exports
        println("    - $(exp.name)")
    end
catch e
    println("  ✗ Module failed: $(sprint(showerror, e)[1:min(300,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Validate
# ═══════════════════════════════════════════════════════════════════════════════

validate_ok = false
load_ok = false
lookup_ok = false

output_path = joinpath(@__DIR__, "..", "..", "rt-table-module.wasm")

if module_compiled
    write(output_path, module_bytes)
    println("\n--- Step 3: Validate + Node.js ---")

    global validate_ok = try
        run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
        println("  ✓ wasm-tools validate PASSED")
        true
    catch
        println("  ✗ wasm-tools validate FAILED")
        false
    end

    if validate_ok
        # Test from Node.js: create a table, populate it, verify lookups
        node_script = """
        const fs = require('fs');
        const bytes = fs.readFileSync('$(output_path)');

        async function main() {
            const mod = await WebAssembly.compile(bytes);
            const stubs = {};
            for (const imp of WebAssembly.Module.imports(mod)) {
                if (!stubs[imp.module]) stubs[imp.module] = {};
                if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
            }
            const inst = await WebAssembly.instantiate(mod, stubs);
            const e = inst.exports;

            const exports = Object.keys(e);
            console.log(exports.length + ' exports loaded');

            // Test 1: composite_hash is deterministic
            // NOTE: wasm_set_i32/wasm_create_i32_vector use 1-based Julia indexing
            const args1 = e.wasm_create_i32_vector(2);
            e.wasm_set_i32(args1, 1, 7);  // TypeID for Int64 (1-based)
            e.wasm_set_i32(args1, 2, 7);  // TypeID for Int64

            // Hash should be consistent (UInt32 maps to i32 in WASM)
            const h1 = e.composite_hash(42, args1);
            const h2 = e.composite_hash(42, args1);
            console.log('hash deterministic: ' + (h1 === h2));

            // Test 2: lookup_return_type on a small table
            // Create a table with 32 slots (16 pairs of key/value, 50% load)
            const table = e.wasm_create_i32_vector(32);
            // Fill with -1 (empty sentinel) — 1-based indexing
            for (let i = 1; i <= 32; i++) {
                e.wasm_set_i32(table, i, -1);
            }

            // Insert one entry: hash_key=h1 → ret_typeid=7 (Int64)
            // lookup_return_type uses 1-based indexing internally
            // Compute slot: h1 % 16 (table_size = 32/2 = 16)
            const h1_unsigned = h1 >>> 0;  // Convert to unsigned
            const slot_0based = (h1_unsigned % 16) * 2;
            const slot_1based = slot_0based + 1;  // Convert to 1-based
            e.wasm_set_i32(table, slot_1based, h1);      // key = hash
            e.wasm_set_i32(table, slot_1based + 1, 7);   // value = typeid(Int64) = 7

            // Lookup should find it
            const result = e.lookup_return_type(table, h1_unsigned);
            console.log('lookup found: ' + result + ' (expected 7)');

            // Lookup of non-existent key should return -1
            const miss = e.lookup_return_type(table, 0xDEADBEEF >>> 0);
            console.log('lookup miss: ' + miss + ' (expected -1)');

            // Summary
            const pass = (h1 === h2) && (result === 7) && (miss === -1);
            console.log('ALL PASS: ' + pass);
            if (!pass) process.exit(1);
        }
        main().catch(e => { console.error(e.message); process.exit(1); });
        """

        try
            local node_result = read(`node -e $node_script`, String)
            for line in split(strip(node_result), '\n')
                println("  Node.js: $line")
            end
            global load_ok = contains(node_result, "exports loaded")
            global lookup_ok = contains(node_result, "ALL PASS: true")
        catch e
            println("  ✗ Node.js failed: $(sprint(showerror, e)[1:min(200,end)])")
        end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary + Tests
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("METH-002 Summary:")
println("  Functions compiled: $(length(entries))")
println("  Module size: $(round(length(module_bytes)/1024, digits=1)) KB")
println("  Exports: $n_exports")
println("  wasm-tools validate: $validate_ok")
println("  Node.js loads: $load_ok")
println("  Node.js lookup: $lookup_ok")
println("=" ^ 60)

@testset "METH-002: Return type table in module" begin
    @test length(entries) >= 7
    @test module_compiled
    @test validate_ok
    @test load_ok
    @test lookup_ok
end

# Clean up
try rm(output_path) catch end

println("\nAll METH-002 tests complete.")
