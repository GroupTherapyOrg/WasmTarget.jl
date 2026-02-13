#!/usr/bin/env julia
# PURE-324 attempt 20: Test EndMarker comparison in full parse context
# Hypothesis: The EndMarker break in _bump_until_n doesn't work in 404-func context

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
    for (const input of ['1', 'hello', '']) {
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

# Test 1: After parse!, return number of non-TOMBSTONE terminal tokens in output
# Native "1": should be 2 (Integer + toplevel)
# If Wasm returns 3, the EndMarker is leaking into output
function test_token_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    count = Int32(0)
    for node in stream.output
        if JuliaSyntax.kind(node) != JuliaSyntax.K"TOMBSTONE"
            count += Int32(1)
        end
    end
    return count
end

# Test 2: Check if last output token kind == EndMarker
# If so, it's leaking
function test_last_is_endmarker(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    last_node = last(stream.output)
    k = JuliaSyntax.kind(last_node)
    return (k == JuliaSyntax.K"EndMarker") ? Int32(1) : Int32(0)
end

# Test 3: Check if any output token is EndMarker
function test_has_endmarker(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    for node in stream.output
        if JuliaSyntax.kind(node) == JuliaSyntax.K"EndMarker"
            return Int32(1)
        end
    end
    return Int32(0)
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for (name, f) in [
    ("test_token_count", test_token_count),
    ("test_last_is_endmarker", test_last_is_endmarker),
    ("test_has_endmarker", test_has_endmarker)
]
    for input in ["1", "hello", ""]
        println("$name(\"$input\") = ", f(input))
    end
end

# Compile and test each
do_test("test_token_count", test_token_count)
do_test("test_last_is_endmarker", test_last_is_endmarker)
do_test("test_has_endmarker", test_has_endmarker)
