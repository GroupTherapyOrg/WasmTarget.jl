#!/usr/bin/env julia
# PURE-324 attempt 21: Test peek behavior after parse
# Hypothesis: peek(ps, skip_newlines=true) doesn't return EndMarker in Wasm,
# causing parse_toplevel to loop an extra time and parse_atom to emit error node

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

# Test: After parse!, what kind does peek return with skip_newlines=true?
# EndMarker kind value
function test_peek_skip_nl(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    # After parse!, peek should return EndMarker (kind=2)
    k = Base.peek(stream, skip_newlines=true)
    return reinterpret(UInt16, k) % Int32
end

# Test: What is the peek_count after parse!?
function test_peek_count(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.peek_count % Int32
end

# Test: What is the lookahead_index after parse!?
function test_lookahead_idx(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.lookahead_index % Int32
end

# Test: How many entries in lookahead after parse!?
function test_lookahead_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return length(stream.lookahead) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    println("EndMarker kind = ", reinterpret(UInt16, JuliaSyntax.K"EndMarker"))
    println("test_peek_skip_nl(\"$input\") = ", test_peek_skip_nl(input))
    println("test_peek_count(\"$input\") = ", test_peek_count(input))
    println("test_lookahead_idx(\"$input\") = ", test_lookahead_idx(input))
    println("test_lookahead_len(\"$input\") = ", test_lookahead_len(input))
end

# Compile and test
do_test("test_peek_skip_nl", test_peek_skip_nl)
do_test("test_peek_count", test_peek_count)
do_test("test_lookahead_idx", test_lookahead_idx)
do_test("test_lookahead_len", test_lookahead_len)
