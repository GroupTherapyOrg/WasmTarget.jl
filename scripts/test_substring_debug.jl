#!/usr/bin/env julia
# PURE-324: Check SubString construction in Stage C4 context
# Hypothesis: SubString's offset field is wrong when compiled with 488 funcs

using WasmTarget
using JuliaSyntax

# Test 1: SubString offset in isolation (should work)
function test_ss_offset(s::String)::Int64
    ss = SubString(s, 1, ncodeunits(s))
    return ss.offset
end

# Test 2: SubString in parsestmt context (compile with _parse dependencies)
# We need to trigger the same compilation context as stage_c4
# The issue might be that SubString gets compiled differently when _parse is included

# Let me check: what does SourceFile#8 actually do with the SubString?
# The SourceFile constructor gets a SubString and counts newlines in it
# Let's compile a function that does the same thing:

function count_newlines_ss(s::String)::Int32
    ss = SubString(s, 1, ncodeunits(s))
    count = Int32(0)
    for i in 1:ncodeunits(ss)
        if codeunit(ss, i) == UInt8('\n')
            count += Int32(1)
        end
    end
    return count
end

# Compile and test in isolation
println("=== Test 1: SubString offset (isolation) ===")
try
    bytes = compile(test_ss_offset, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("$nfuncs funcs, $(length(bytes)) bytes")

    # Check SubString type
    println("Types:")
    types = read(`bash -c "wasm-tools print $tmpf | head -50 | grep struct"`, String)
    println(types)

    # Test in Node
    cp(tmpf, joinpath(@__DIR__, "..", "browser", "test_ss_offset.wasm"), force=true)
    node_code = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_ss_offset.wasm"))');
const mod = await rt.load(w, 'test_ss_offset');
const s = await rt.jsToWasmString('hello');
try {
    const r = mod.exports.test_ss_offset(s);
    console.log('test_ss_offset PASS:', r, '(expected 0)');
} catch(e) {
    console.log('test_ss_offset FAIL:', e.message);
}
"""
    tmpjs = tempname() * ".mjs"
    write(tmpjs, node_code)
    run(`node $tmpjs`)
catch e
    println("ERROR: $e")
end

println("\n=== Test 2: count_newlines_ss (isolation) ===")
try
    bytes = compile(count_newlines_ss, (String,))
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("$nfuncs funcs, $(length(bytes)) bytes")

    cp(tmpf, joinpath(@__DIR__, "..", "browser", "test_nl_ss.wasm"), force=true)
    node_code = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_nl_ss.wasm"))');
const mod = await rt.load(w, 'count_newlines_ss');
for (const [input, expected] of [['hello', 0], ['a\\nb', 1], ['a\\nb\\nc', 2]]) {
    const s = await rt.jsToWasmString(input);
    try {
        const r = mod.exports.count_newlines_ss(s);
        console.log('count_newlines_ss("' + input + '"):', r, r == expected ? 'PASS' : 'FAIL (expected ' + expected + ')');
    } catch(e) {
        console.log('count_newlines_ss("' + input + '") FAIL:', e.message);
    }
}
"""
    tmpjs = tempname() * ".mjs"
    write(tmpjs, node_code)
    run(`node $tmpjs`)
catch e
    println("ERROR: $e")
end

# Now compile the SAME function but with _parse in the same module
println("\n=== Test 3: count_newlines_ss WITH _parse in module ===")
function stage_c4_with_nl(s::String)
    JuliaSyntax._parse(:statement, false, Expr, s, 1)
end

try
    # Compile both functions in the same module
    bytes = WasmTarget.compile_multi([
        (count_newlines_ss, (String,)),
        (stage_c4_with_nl, (String,)),
    ])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("$nfuncs funcs, $(length(bytes)) bytes")

    cp(tmpf, joinpath(@__DIR__, "..", "browser", "test_nl_with_parse.wasm"), force=true)
    node_code = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_nl_with_parse.wasm"))');
const mod = await rt.load(w, 'count_newlines_ss');
for (const [input, expected] of [['hello', 0], ['a\\nb', 1], ['1', 0]]) {
    const s = await rt.jsToWasmString(input);
    try {
        const r = mod.exports.count_newlines_ss(s);
        console.log('count_newlines_ss("' + input + '"):', r, r == expected ? 'PASS' : 'FAIL (expected ' + expected + ')');
    } catch(e) {
        console.log('count_newlines_ss("' + input + '") FAIL:', e.message);
    }
}
"""
    tmpjs = tempname() * ".mjs"
    write(tmpjs, node_code)
    run(`node $tmpjs`)
catch e
    println("ERROR: $e")
end
