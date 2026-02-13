#!/usr/bin/env julia
# PURE-324 attempt 21: Test Kind comparison and `in` operator
# Hypothesis: K"EndMarker" ∈ KSet"EndMarker NewlineWs" is mis-compiled

using WasmTarget
using JuliaSyntax

function do_test(name, f, args_types)
    println("\n=== $name ===")
    try
        bytes = compile(f, args_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
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
    const timer = setTimeout(() => { console.log('$name TIMEOUT'); process.exit(1); }, 10000);
    try {
        const args = [752];
        const r = mod.exports.$name(args[0]);
        console.log('$name(752) = ' + r);
    } catch(e) {
        console.log('$name(752) FAIL: ' + e.message);
    }
    try {
        const r2 = mod.exports.$name(44);
        console.log('$name(44) = ' + r2);
    } catch(e) {
        console.log('$name(44) FAIL: ' + e.message);
    }
    try {
        const r3 = mod.exports.$name(1);
        console.log('$name(1) = ' + r3);
    } catch(e) {
        console.log('$name(1) FAIL: ' + e.message);
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

# Test 1: Kind equality
function test_kind_eq(k::UInt16)
    kind = reinterpret(JuliaSyntax.Kind, k)
    return (kind === JuliaSyntax.K"EndMarker") ? Int32(1) : Int32(0)
end

# Test 2: Kind in tuple
function test_kind_in(k::UInt16)
    kind = reinterpret(JuliaSyntax.Kind, k)
    result = kind in (JuliaSyntax.K"EndMarker", JuliaSyntax.K"NewlineWs")
    return result ? Int32(1) : Int32(0)
end

# Test 3: Kind not-in tuple (the actual condition in parse_stmts)
function test_kind_notin(k::UInt16)
    kind = reinterpret(JuliaSyntax.Kind, k)
    result = kind ∉ (JuliaSyntax.K"EndMarker", JuliaSyntax.K"NewlineWs")
    return result ? Int32(1) : Int32(0)
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
println("K\"EndMarker\" = ", reinterpret(UInt16, JuliaSyntax.K"EndMarker"))
println("K\"NewlineWs\" = ", reinterpret(UInt16, JuliaSyntax.K"NewlineWs"))
println("K\"Integer\" = ", reinterpret(UInt16, JuliaSyntax.K"Integer"))

for k in [UInt16(752), UInt16(44), UInt16(1)]
    println("test_kind_eq($k) = ", test_kind_eq(k))
    println("test_kind_in($k) = ", test_kind_in(k))
    println("test_kind_notin($k) = ", test_kind_notin(k))
end

do_test("test_kind_eq", test_kind_eq, (UInt16,))
do_test("test_kind_in", test_kind_in, (UInt16,))
do_test("test_kind_notin", test_kind_notin, (UInt16,))
