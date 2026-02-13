#!/usr/bin/env julia
# PURE-324 attempt 20: Debug byte_span computation
# Key question: Is byte_span computed correctly? Or is next_byte incremented wrong?

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

# Test 1: Number of output tokens after parse!
function test_output_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return length(stream.output) % Int32
end

# Test 2: byte_span of the LAST output token
# RawGreenNode has a byte_span field
function test_last_span(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    node = last(stream.output)
    return node.byte_span % Int32
end

# Test 3: Sum of all byte_spans in output
function test_total_span(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    total = 0
    for node in stream.output
        total += node.byte_span
    end
    return total % Int32
end

# Test 4: next_byte BEFORE parse! (should be 1)
function test_nb_before(s::String)
    stream = JuliaSyntax.ParseStream(s)
    return stream.next_byte % Int32
end

# Test 5: next_byte AFTER parse!
function test_nb_after(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.next_byte % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for (name, f) in [
    ("test_output_len", test_output_len),
    ("test_last_span", test_last_span),
    ("test_total_span", test_total_span),
    ("test_nb_before", test_nb_before),
    ("test_nb_after", test_nb_after)
]
    for input in ["1", "hello"]
        println("$name(\"$input\") = ", f(input))
    end
end

# Compile and test each
do_test("test_output_len", test_output_len)
do_test("test_last_span", test_last_span)
do_test("test_total_span", test_total_span)
do_test("test_nb_before", test_nb_before)
do_test("test_nb_after", test_nb_after)
