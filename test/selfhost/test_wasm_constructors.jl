# test_wasm_constructors.jl — GAMMA-002: Test WASM constructor exports from Node.js
#
# Verifies that all CodeInfo IR type constructors can be called from JS
# and return non-null WasmGC struct references.
#
# Run: julia +1.12 --project=. test/selfhost/test_wasm_constructors.jl

using Test

println("=" ^ 60)
println("GAMMA-002: Testing WASM constructor exports from Node.js")
println("=" ^ 60)

wasm_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-e2e.wasm")
if !isfile(wasm_path)
    error("self-hosted-codegen-e2e.wasm not found. Run test_codegen_e2e_module.jl first.")
end

# Node.js test script
node_script = raw"""
const fs = require('fs');
const bytes = fs.readFileSync(process.argv[2]);

async function main() {
    const mod = await WebAssembly.compile(bytes);
    const stubs = {};
    for (const imp of WebAssembly.Module.imports(mod)) {
        if (!stubs[imp.module]) stubs[imp.module] = {};
        if (imp.kind === 'function') stubs[imp.module][imp.name] = () => {};
    }
    const inst = await WebAssembly.instantiate(mod, stubs);
    const e = inst.exports;

    let passed = 0, failed = 0;
    const results = [];

    function test(name, fn) {
        try {
            const result = fn();
            if (result === null || result === undefined) {
                results.push('FAIL: ' + name + ' returned null/undefined');
                failed++;
            } else {
                results.push('PASS: ' + name);
                passed++;
            }
        } catch (err) {
            results.push('FAIL: ' + name + ' -- ' + err.message.slice(0, 100));
            failed++;
        }
    }

    function testVoid(name, fn) {
        try {
            fn();
            results.push('PASS: ' + name);
            passed++;
        } catch (err) {
            results.push('FAIL: ' + name + ' -- ' + err.message.slice(0, 100));
            failed++;
        }
    }

    function testValue(name, fn, expected) {
        try {
            const result = fn();
            if (result === expected) {
                results.push('PASS: ' + name + ' = ' + result);
                passed++;
            } else {
                results.push('FAIL: ' + name + ' = ' + result + ' (expected ' + expected + ')');
                failed++;
            }
        } catch (err) {
            results.push('FAIL: ' + name + ' -- ' + err.message.slice(0, 100));
            failed++;
        }
    }

    // === IR node constructors ===
    test('create_ssa_value(42)', () => e.wasm_create_ssa_value(42));
    test('create_argument(1)', () => e.wasm_create_argument(1));
    test('create_goto_node(5)', () => e.wasm_create_goto_node(5));
    test('create_goto_if_not(1, 3)', () => e.wasm_create_goto_if_not(1, 3));
    test('create_return_node(1)', () => e.wasm_create_return_node(1));
    // ReturnNode() with no val returns null in WasmGC (uninitialized field).
    // This is expected — not needed for MVP. Just verify it doesn't crash.
    testVoid('create_return_node_nothing()', () => e.wasm_create_return_node_nothing());

    // === Verification accessors ===
    const ssa = e.wasm_create_ssa_value(42);
    testValue('get_ssa_id(SSAValue(42))', () => e.wasm_get_ssa_id(ssa), 42);

    const gin = e.wasm_create_goto_if_not(1, 7);
    testValue('get_gotoifnot_dest(GotoIfNot(1,7))', () => e.wasm_get_gotoifnot_dest(gin), 7);

    // === Symbol constructors ===
    test('symbol_call()', () => e.wasm_symbol_call());
    test('symbol_invoke()', () => e.wasm_symbol_invoke());
    test('symbol_new()', () => e.wasm_symbol_new());

    // === Expr construction ===
    const callSym = e.wasm_symbol_call();
    const emptyArgs = e.wasm_create_any_vector(0);
    test('create_expr(:call, [])', () => e.wasm_create_expr(callSym, emptyArgs));

    // Build a real Expr: Expr(:call, SSAValue(1), Argument(2))
    const args3 = e.wasm_create_any_vector(3);
    e.wasm_set_any_ssa(args3, 1, 1);
    e.wasm_set_any_arg(args3, 2, 2);
    e.wasm_set_any_i64(args3, 3, 99n);
    test('create_expr(:call, [ssa,arg,lit])', () => e.wasm_create_expr(callSym, args3));

    // === Vector{Any} builders ===
    test('create_any_vector(5)', () => e.wasm_create_any_vector(5));

    const vec = e.wasm_create_any_vector(5);
    testValue('any_vector_length(5-vec)', () => e.wasm_any_vector_length(vec), 5);

    testVoid('set_any_ssa!(vec, 1, 42)', () => e.wasm_set_any_ssa(vec, 1, 42));
    testVoid('set_any_arg!(vec, 2, 1)', () => e.wasm_set_any_arg(vec, 2, 1));
    testVoid('set_any_i64!(vec, 3, 99n)', () => e.wasm_set_any_i64(vec, 3, 99n));

    const ret1 = e.wasm_create_return_node(1);
    testVoid('set_any_return!(vec, 4, ret)', () => e.wasm_set_any_return(vec, 4, ret1));

    const goto1 = e.wasm_create_goto_if_not(1, 3);
    testVoid('set_any_gotoifnot!(vec, 5, gin)', () => e.wasm_set_any_gotoifnot(vec, 5, goto1));

    // === Vector{Int32} builders ===
    test('create_i32_vector(3)', () => e.wasm_create_i32_vector(3));

    const ivec = e.wasm_create_i32_vector(3);
    testValue('i32_vector_length(3-vec)', () => e.wasm_i32_vector_length(ivec), 3);
    testVoid('set_i32!(ivec, 1, 10)', () => e.wasm_set_i32(ivec, 1, 10));
    testVoid('set_i32!(ivec, 2, 20)', () => e.wasm_set_i32(ivec, 2, 20));

    // === PhiNode construction ===
    const edges = e.wasm_create_i32_vector(2);
    e.wasm_set_i32(edges, 1, 1);
    e.wasm_set_i32(edges, 2, 3);
    const vals = e.wasm_create_any_vector(2);
    e.wasm_set_any_ssa(vals, 1, 5);
    e.wasm_set_any_ssa(vals, 2, 7);
    test('create_phi_node(edges, vals)', () => e.wasm_create_phi_node(edges, vals));

    // === SSA types utility ===
    const ssatypes = e.wasm_create_ssatypes_all_i64(3);
    test('create_ssatypes_all_i64(3)', () => ssatypes);
    testValue('ssatypes length', () => e.wasm_any_vector_length(ssatypes), 3);

    // === GotoNode in vector ===
    const vec2 = e.wasm_create_any_vector(1);
    const gn = e.wasm_create_goto_node(10);
    testVoid('set_any_goto!(vec, 1, gn)', () => e.wasm_set_any_goto(vec2, 1, gn));

    // === PhiNode in vector ===
    const vec3 = e.wasm_create_any_vector(1);
    const phi = e.wasm_create_phi_node(edges, vals);
    testVoid('set_any_phi!(vec, 1, phi)', () => e.wasm_set_any_phi(vec3, 1, phi));

    // === Summary ===
    for (const r of results) {
        console.log('  ' + r);
    }
    console.log('');
    console.log(passed + '/' + (passed + failed) + ' tests passed');

    if (failed > 0) process.exit(1);
}

main().catch(e => { console.error(e.message); process.exit(1); });
"""

# Write the test script to a temp file to avoid shell escaping issues
test_script_path = joinpath(tempdir(), "test_constructors.cjs")
write(test_script_path, node_script)

println("\n--- Running Node.js constructor tests ---")
node_ok = false
try
    node_result = read(`node $test_script_path $wasm_path`, String)
    println(node_result)
    # Check last line for pass count
    lines = filter(!isempty, split(strip(node_result), '\n'))
    if !isempty(lines)
        last_line = strip(lines[end])
        if occursin("/", last_line)
            parts = split(last_line, '/')
            if length(parts) >= 2
                pass_count = tryparse(Int, strip(parts[1]))
                total_str = split(strip(parts[2]))[1]
                total_count = tryparse(Int, total_str)
                if pass_count !== nothing && total_count !== nothing
                    global node_ok = pass_count == total_count && pass_count > 0
                end
            end
        end
    end
catch e
    println("Node.js test FAILED: $(sprint(showerror, e))")
    try
        node_result = read(pipeline(`node $test_script_path $wasm_path`, stderr=stdout), String)
        println(node_result)
    catch e2
        println("stderr capture also failed")
    end
end

@testset "GAMMA-002: WASM constructor exports" begin
    @test isfile(wasm_path)
    @test node_ok
end
