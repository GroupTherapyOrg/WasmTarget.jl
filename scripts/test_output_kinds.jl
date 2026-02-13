#!/usr/bin/env julia
# PURE-324 attempt 21: Return kinds of output nodes to find the extra token
# Strategy: return output[i].head.kind as Int32 for each i

using WasmTarget
using JuliaSyntax

function do_test(name, f, args_types=(String,))
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

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    stream = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(stream)
    print("output_len(\"$input\")=$(length(stream.output)) kinds=")
    for i in 1:length(stream.output)
        h = JuliaSyntax.head(stream.output[i])
        print("$(h.kind) ")
    end
    println()
end

# Test 1: Return output length
function test_output_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return length(stream.output) % Int32
end

# Test 2: Return kind of output node at index i (1-based)
# Encode: kind_val = head.kind which is packed into the SyntaxHead
# SyntaxHead has kind (Kind) and flags (UInt16)
# Kind is stored as UInt16 internally
function test_output_kind_1(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    h = JuliaSyntax.head(stream.output[1])
    return reinterpret(UInt16, h.kind) % Int32
end

function test_output_kind_2(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    h = JuliaSyntax.head(stream.output[2])
    return reinterpret(UInt16, h.kind) % Int32
end

function test_output_kind_3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    h = JuliaSyntax.head(stream.output[3])
    return reinterpret(UInt16, h.kind) % Int32
end

function test_output_kind_4(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    if length(stream.output) >= 4
        h = JuliaSyntax.head(stream.output[4])
        return reinterpret(UInt16, h.kind) % Int32
    end
    return Int32(-1)
end

# Show native values
println("\nNative kind values:")
for input in ["1", "hello"]
    for i in 1:3
        stream = JuliaSyntax.ParseStream(input)
        JuliaSyntax.parse!(stream)
        h = JuliaSyntax.head(stream.output[i])
        println("  kind_$i(\"$input\") = $(reinterpret(UInt16, h.kind))")
    end
end

# Compile
do_test("test_output_kind_1", test_output_kind_1)
do_test("test_output_kind_2", test_output_kind_2)
do_test("test_output_kind_3", test_output_kind_3)
do_test("test_output_kind_4", test_output_kind_4)
