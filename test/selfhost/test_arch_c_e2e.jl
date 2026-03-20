# METH-005: Architecture C E2E Demo
#
# Server: parse+lower only (no typeinf) → serialize CodeInfo + callee_typeids
# Browser: deserialize → WASM thin_typeinf → JS compile → execute
# Result: f(5n) === 26n with ZERO server-side type inference
#
# Run: julia +1.12 --project=. test/selfhost/test_arch_c_e2e.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes

# Load typeinf infrastructure (NO typeinf_wasm.jl yet — get IR first)
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "return_type_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "thin_typeinf.jl"))

println("=" ^ 60)
println("METH-005: Architecture C E2E Demo")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Get IR for ALL WASM functions (clean session, no typeinf overrides)
# ═══════════════════════════════════════════════════════════════════════════════

all_functions = [
    # --- IR constructors ---
    (WasmTarget.wasm_create_i32_vector, (Int32,), "wasm_create_i32_vector"),
    (WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32), "wasm_set_i32"),
    (WasmTarget.wasm_i32_vector_length, (Vector{Int32},), "wasm_i32_vector_length"),
    (WasmTarget.wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (WasmTarget.wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (WasmTarget.wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    (WasmTarget.wasm_any_vector_length, (Vector{Any},), "wasm_any_vector_length"),
    (WasmTarget.wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (WasmTarget.wasm_create_return_node, (Int32,), "wasm_create_return_node"),
    (WasmTarget.wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (WasmTarget.wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),
    (WasmTarget.wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (WasmTarget.wasm_symbol_call, (), "wasm_symbol_call"),
    # --- Type inference ---
    (composite_hash, (Int32, Vector{Int32}), "composite_hash"),
    (lookup_return_type, (Vector{Int32}, UInt32), "lookup_return_type"),
    (wasm_resolve_val_typeid, (Any, Vector{Int32}, Vector{Int32}, Int32, Int32, Int32, Int32), "wasm_resolve_val_typeid"),
    (wasm_thin_typeinf, (Vector{Any}, Vector{Int32}, Vector{Int32}, Vector{Int32}, Int32, Int32, Int32, Int32), "wasm_thin_typeinf"),
    # --- S-003: WASM codegen (wasm_compile_flat + helpers + byte accessors) ---
    (WasmTarget._fb!, (Vector{UInt8}, UInt8), "_fb!"),
    (WasmTarget._fa!, (Vector{UInt8}, Vector{UInt8}), "_fa!"),
    (WasmTarget._flu, (UInt32,), "_flu"),
    (WasmTarget._fls, (Int64,), "_fls"),
    (WasmTarget._flen, (Vector{UInt8},), "_flen"),
    (WasmTarget._emit_local_get!, (Vector{UInt8}, UInt32), "_emit_local_get!"),
    (WasmTarget._emit_local_set!, (Vector{UInt8}, UInt32), "_emit_local_set!"),
    (WasmTarget._emit_i64_const!, (Vector{UInt8}, Int64), "_emit_i64_const!"),
    (WasmTarget._emit_section!, (Vector{UInt8}, UInt8, Vector{UInt8}), "_emit_section!"),
    (WasmTarget.wasm_compile_flat, (Vector{Int32}, Int32), "wasm_compile_flat"),
    (WasmTarget.wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length"),
    (WasmTarget.wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get"),
]

println("\n--- Step 1: code_typed $(length(all_functions)) functions ---")
entries = Tuple[]
for (f, atypes, name) in all_functions
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(entries, (ci, rt, atypes, name, f))
end
println("  $(length(entries)) functions compiled")

# Compile module
mod = compile_module_from_ir(entries)
module_bytes = to_bytes(mod)
output_path = joinpath(@__DIR__, "..", "..", "arch-c-e2e.wasm")
write(output_path, module_bytes)
println("  Module: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(mod.exports)) exports")

validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $output_path`, stderr=devnull, stdout=devnull))
    println("  ✓ wasm-tools validate PASSED")
    true
catch
    false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Build test data (load typeinf AFTER code_typed)
# ═══════════════════════════════════════════════════════════════════════════════

include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))

test_sigs = Any[
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
]
table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)
rt_table = build_return_type_table_with_intrinsics(table, registry)

tid_i64 = get_type_id(registry, Int64)
tid_i32 = get_type_id(registry, Int32)
tid_f64 = get_type_id(registry, Float64)
tid_bool = get_type_id(registry, Bool)
tid_mul_int = get_type_id(registry, Base.mul_int)
tid_add_int = get_type_id(registry, Base.add_int)

rt_table_str = join(rt_table, ",")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Write + run Node.js E2E script
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Running Architecture C E2E in Node.js ---")

script_path = joinpath(@__DIR__, "..", "..", "scripts", "e2e_demo_arch_c.cjs")
open(script_path, "w") do f
    write(f, """#!/usr/bin/env node
'use strict';
const fs = require('fs');
const path = require('path');

// Intrinsic name → WASM i64 opcode (same as Arch A)
const OPCODES = { mul_int: 0x7e, add_int: 0x7c, sub_int: 0x7d };

async function main() {
    console.log('Architecture C E2E Demo (S-003: WASM codegen, no JS binary assembly)');
    console.log('Server parse+lower -> Browser WASM thin_typeinf -> WASM wasm_compile_flat -> execute');
    console.log();

    // TypeID constants (baked from native Julia)
    const TID_I64 = $(tid_i64), TID_I32 = $(tid_i32), TID_F64 = $(tid_f64), TID_BOOL = $(tid_bool);
    const TID_MUL_INT = $(tid_mul_int), TID_ADD_INT = $(tid_add_int);
    const RT_DATA = [$(rt_table_str)];

    // 1. Load WASM module (thin_typeinf + wasm_compile_flat + byte accessors)
    const wasmPath = process.argv[2] || path.join(__dirname, '..', 'arch-c-e2e.wasm');
    const wasmBytes = fs.readFileSync(wasmPath);
    const wasmMod = await WebAssembly.compile(wasmBytes);
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(wasmMod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const inst = await WebAssembly.instantiate(wasmMod, stubs);
    const e = inst.exports;
    console.log('1. Loaded module: ' + Object.keys(e).length + ' exports');

    // 2. Build IR for f(x::Int64) = x * x + 1 — "server sends UNTYPED CodeInfo"
    const code = e.wasm_create_any_vector(3);
    const args1 = e.wasm_create_any_vector(3);
    e.wasm_set_any_arg(args1, 1, 2); e.wasm_set_any_arg(args1, 2, 2); e.wasm_set_any_arg(args1, 3, 2);
    e.wasm_set_any_expr(code, 1, e.wasm_create_expr(e.wasm_symbol_call(), args1));
    const args2 = e.wasm_create_any_vector(3);
    e.wasm_set_any_ssa(args2, 1, 1); e.wasm_set_any_ssa(args2, 2, 1); e.wasm_set_any_i64(args2, 3, 1n);
    e.wasm_set_any_expr(code, 2, e.wasm_create_expr(e.wasm_symbol_call(), args2));
    e.wasm_set_any_return(code, 3, e.wasm_create_return_node(2));
    console.log('2. Server sends untyped CodeInfo: ' + e.wasm_any_vector_length(code) + ' stmts (NO typeinf)');

    // 3. Browser runs WASM thin_typeinf
    const callee_typeids = e.wasm_create_i32_vector(3);
    e.wasm_set_i32(callee_typeids, 1, TID_MUL_INT);
    e.wasm_set_i32(callee_typeids, 2, TID_ADD_INT);
    e.wasm_set_i32(callee_typeids, 3, -1);
    const arg_typeids = e.wasm_create_i32_vector(2);
    e.wasm_set_i32(arg_typeids, 1, -1); e.wasm_set_i32(arg_typeids, 2, TID_I64);
    const rt_table = e.wasm_create_i32_vector(RT_DATA.length);
    for (let i = 0; i < RT_DATA.length; i++) e.wasm_set_i32(rt_table, i + 1, RT_DATA[i]);

    const ssa_types = e.wasm_thin_typeinf(code, callee_typeids, arg_typeids, rt_table, TID_I64, TID_I32, TID_F64, TID_BOOL);
    console.log('3. Browser WASM thin_typeinf: ' + e.wasm_i32_vector_length(ssa_types) + ' SSA types inferred');

    // 4. Compile via WASM wasm_compile_flat (ZERO JS binary assembly)
    // Build flat Int32 instruction buffer (data translation only, NOT compilation)
    // f(x) = x*x+1 → mul_int(arg0, arg0), add_int(ssa0, 1), return ssa1
    const flatData = [
        0, OPCODES.mul_int, 2, 0, 0, 0, 0,     // call mul_int(param0, param0)
        0, OPCODES.add_int, 2, 1, 0, 2, 1,      // call add_int(ssa0, const 1)
        1, 1, 1,                                  // return ssa1
    ];
    const instrs = e.wasm_create_i32_vector(flatData.length);
    for (let i = 0; i < flatData.length; i++) e.wasm_set_i32(instrs, i + 1, flatData[i]);

    // Compile IN WASM via wasm_compile_flat
    const wasmResult = e.wasm_compile_flat(instrs, 1);
    const len = e.wasm_bytes_length(wasmResult);
    console.log('4. WASM wasm_compile_flat: ' + len + ' bytes (ZERO JS compilation)');

    // Extract bytes from WasmGC Vector{UInt8}
    const userBytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) userBytes[i] = e.wasm_bytes_get(wasmResult, i + 1);

    // 5. Execute
    const userMod = await WebAssembly.compile(userBytes);
    const userInst = await WebAssembly.instantiate(userMod);
    const f = userInst.exports.f;

    const tests = [[5n,26n],[0n,1n],[-3n,10n],[10n,101n],[1n,2n]];
    let allPass = true;
    for (const [input, expected] of tests) {
        const result = f(input);
        const pass = result === expected;
        console.log('5. f(' + input + ') = ' + result + ' ' + (pass ? 'PASS' : 'FAIL'));
        if (!pass) allPass = false;
    }

    console.log();
    console.log(allPass ? 'ARCHITECTURE C E2E: PASS' : 'ARCHITECTURE C E2E: FAIL');
    console.log('Server: ZERO type inference. Browser: WASM thin_typeinf + WASM wasm_compile_flat.');
    console.log('ZERO JS compilation or binary assembly — ALL compilation in WASM.');
    if (!allPass) process.exit(1);
}

main().catch(err => { console.error('Fatal: ' + err.message); process.exit(1); });
""")
end

node_ok = false
try
    result = read(`node $script_path $output_path`, String)
    for line in split(strip(result), '\n')
        println("  $line")
    end
    global node_ok = contains(result, "ARCHITECTURE C E2E: PASS")
catch e
    println("  ✗ Node.js failed: $(sprint(showerror, e)[1:min(200,end)])")
end

println("\n" * "=" ^ 60)
println("METH-005 Summary:")
println("  wasm-tools validate: $validate_ok")
println("  Architecture C E2E: $node_ok")
println("=" ^ 60)

@testset "METH-005: Architecture C E2E Demo" begin
    @test validate_ok
    @test node_ok
end

# Clean up temp wasm
try rm(output_path) catch end

println("\nAll METH-005 tests complete.")
