#!/usr/bin/env julia
# PURE-324 attempt 20: Test zext_int behavior
# Hypothesis: UInt32 → Int64 conversion is wrong in Wasm

using WasmTarget
using JuliaSyntax

function do_test(name, f, args_types)
    println("\n=== $name ===")
    try
        bytes = compile(f, args_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(Cmd(["wasm-tools", "validate", "--features=gc", tmpf]))
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("Compiled: $nfuncs funcs, $(length(bytes)) bytes, VALIDATES")

        wasmfile = joinpath(@__DIR__, "..", "browser", "$(name).wasm")
        cp(tmpf, wasmfile, force=true)

        rtpath = joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js")
        node_test = """
const fs = require('fs');
const rc = fs.readFileSync('$rtpath', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile');
    const mod = await rt.load(w, '$name');
    const timer = setTimeout(() => { console.log('$name TIMEOUT'); process.exit(1); }, 5000);
    for (const input of [0, 1, 2, 5, 255]) {
        try {
            const r = mod.exports.$name(input);
            console.log('$name(' + input + ') = ' + r);
        } catch(e) {
            console.log('$name(' + input + ') FAIL: ' + e.message);
        }
    }
    clearTimeout(timer);
})();
"""
        f_test = tempname() * ".js"
        write(f_test, node_test)
        println(strip(read(`node $f_test`, String)))
    catch e
        println("ERROR: $e")
    end
end

# Test 1: Simple UInt32 → Int64 → Int32 (roundtrip)
function test_u32_to_i64(x::UInt32)
    y = Core.zext_int(Int64, x)
    return y % Int32
end

# Test 2: Subtraction after zext
function test_u32_sub(x::UInt32)
    a = Core.zext_int(Int64, x)
    b = Int64(1)
    return (a - b) % Int32
end

# Test 3: Two UInt32 values, convert and subtract
function test_u32_u32_sub(a::UInt32, b::UInt32)
    x = Core.zext_int(Int64, a)
    y = Core.zext_int(Int64, b)
    return (x - y) % Int32
end

# Test 4: Mimic byte_span computation: Int(UInt32(2)) - Int(Int64(1))
function test_byte_span_sim(tok_nb::UInt32, prev_byte::Int64)
    return (Int(tok_nb) - Int(prev_byte)) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for x in UInt32[0, 1, 2, 5, 255]
    println("test_u32_to_i64($(x)) = ", test_u32_to_i64(x))
    println("test_u32_sub($(x)) = ", test_u32_sub(x))
end
println("test_byte_span_sim(UInt32(2), Int64(1)) = ", test_byte_span_sim(UInt32(2), Int64(1)))
println("test_byte_span_sim(UInt32(6), Int64(1)) = ", test_byte_span_sim(UInt32(6), Int64(1)))

do_test("test_u32_to_i64", test_u32_to_i64, (UInt32,))
do_test("test_u32_sub", test_u32_sub, (UInt32,))
do_test("test_byte_span_sim", test_byte_span_sim, (UInt32, Int64))
