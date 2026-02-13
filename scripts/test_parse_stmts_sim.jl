#!/usr/bin/env julia
# PURE-324 attempt 21: Simulate parse_stmts behavior to find the bug
# We compile functions that reproduce individual parts of parse_stmts

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

# Test 1: Does parse_stmts produce the right number of output nodes?
# parse_stmts itself doesn't return output_len, we check the stream output
function test_stmts_output(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    return length(stream.output) % Int32
end

# Test 2: What does parse_Nary return? (true = has semicolons, false = no)
function test_nary_result(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    result = JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public,
                                     (JuliaSyntax.K";",),
                                     (JuliaSyntax.K"NewlineWs",))
    return result ? Int32(1) : Int32(0)
end

# Test 3: output_len after parse_Nary only (before junk check)
function test_nary_output_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public,
                           (JuliaSyntax.K";",),
                           (JuliaSyntax.K"NewlineWs",))
    return length(stream.output) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    println("test_stmts_output(\"$input\") = ", test_stmts_output(input))
    println("test_nary_result(\"$input\") = ", test_nary_result(input))
    println("test_nary_output_len(\"$input\") = ", test_nary_output_len(input))
end

do_test("test_stmts_output", test_stmts_output)
do_test("test_nary_result", test_nary_result)
do_test("test_nary_output_len", test_nary_output_len)
