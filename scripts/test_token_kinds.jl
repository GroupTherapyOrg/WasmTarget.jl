#!/usr/bin/env julia
# PURE-324 attempt 20: Identify the EXTRA token in Wasm output
# We know output has 4 tokens (expected 3). What's the extra one?

using WasmTarget
using JuliaSyntax

function do_test(name, f, args_types=(String,))
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
    for (const input of ['1', 'hello']) {
        const s = await rt.jsToWasmString(input);
        try {
            const r = mod.exports.$name(s);
            console.log('$name("' + input + '") = ' + r);
        } catch(e) {
            console.log('$name("' + input + '") FAIL: ' + e.message);
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

# Return the Kind value (as i32) for each position in output
# Position 1 = TOMBSTONE (expected)
function test_kind_1(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    node = stream.output[1]
    k = JuliaSyntax.kind(node)
    return reinterpret(UInt16, k) % Int32
end

# Position 2
function test_kind_2(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    node = stream.output[2]
    k = JuliaSyntax.kind(node)
    return reinterpret(UInt16, k) % Int32
end

# Position 3
function test_kind_3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    node = stream.output[3]
    k = JuliaSyntax.kind(node)
    return reinterpret(UInt16, k) % Int32
end

# Position 4 (the EXTRA one in Wasm)
function test_kind_4(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    if length(stream.output) >= 4
        node = stream.output[4]
        k = JuliaSyntax.kind(node)
        return reinterpret(UInt16, k) % Int32
    else
        return Int32(-1)  # not present
    end
end

# Byte span for each position
function test_span_1(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.output[1].byte_span % Int32
end

function test_span_2(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.output[2].byte_span % Int32
end

function test_span_3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.output[3].byte_span % Int32
end

function test_span_4(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    if length(stream.output) >= 4
        return stream.output[4].byte_span % Int32
    end
    return Int32(-1)
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
println("Kind values: TOMBSTONE=", reinterpret(UInt16, JuliaSyntax.K"TOMBSTONE"),
    " Integer=", reinterpret(UInt16, JuliaSyntax.K"Integer"),
    " Identifier=", reinterpret(UInt16, JuliaSyntax.K"Identifier"),
    " toplevel=", reinterpret(UInt16, JuliaSyntax.K"toplevel"),
    " EndMarker=", reinterpret(UInt16, JuliaSyntax.K"EndMarker"),
    " Whitespace=", reinterpret(UInt16, JuliaSyntax.K"Whitespace"),
    " NewlineWs=", reinterpret(UInt16, JuliaSyntax.K"NewlineWs"))
for (name, f) in [
    ("test_kind_1", test_kind_1), ("test_kind_2", test_kind_2),
    ("test_kind_3", test_kind_3), ("test_kind_4", test_kind_4),
    ("test_span_1", test_span_1), ("test_span_2", test_span_2),
    ("test_span_3", test_span_3), ("test_span_4", test_span_4)
]
    for input in ["1", "hello"]
        println("$name(\"$input\") = ", f(input))
    end
end

do_test("test_kind_1", test_kind_1)
do_test("test_kind_2", test_kind_2)
do_test("test_kind_3", test_kind_3)
do_test("test_span_1", test_span_1)
do_test("test_span_2", test_span_2)
do_test("test_span_3", test_span_3)
# Only compile test_kind_4 and test_span_4 if needed
do_test("test_kind_4", test_kind_4)
do_test("test_span_4", test_span_4)
