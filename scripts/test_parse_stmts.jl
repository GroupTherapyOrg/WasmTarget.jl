#!/usr/bin/env julia
# PURE-324 attempt 20: Narrow error to parse_stmts internals
# parse_stmts calls parse_Nary which calls parse_public → parse_docstring → parse_eq → ...
# For "1", the chain is: parse_atom → bumps Integer → returns

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

# Test: Check output after just parse_Nary (the first thing parse_stmts does)
# parse_stmts does: parse_Nary → junk check → maybe emit
function test_output_after_nary(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    mark = JuliaSyntax.position(ps)
    JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))
    return length(stream.output) % Int32
end

# Test: Check errors after parse_Nary
function test_errors_after_nary(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    mark = JuliaSyntax.position(ps)
    JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))
    return length(stream.diagnostics) % Int32
end

# Test: Check peek after parse_Nary (should be EndMarker)
function test_peek_after_nary(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    mark = JuliaSyntax.position(ps)
    JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))
    k = JuliaSyntax.peek(ps)
    return reinterpret(UInt16, k) % Int32
end

# Test: Check the junk detection in parse_stmts
# The code: while peek(ps) ∉ KSet"EndMarker NewlineWs" ... end
# If peek returns wrong kind, junk detection triggers
function test_junk_peek(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    mark = JuliaSyntax.position(ps)
    JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))
    # This is what parse_stmts checks after parse_Nary
    k = JuliaSyntax.peek(ps)
    is_end = (k == JuliaSyntax.K"EndMarker") ? Int32(1) : Int32(0)
    is_newline = (k == JuliaSyntax.K"NewlineWs") ? Int32(1) : Int32(0)
    # Return: 1 = EndMarker, 2 = NewlineWs, 0 = something else (junk!)
    if is_end == Int32(1)
        return Int32(1)
    elseif is_newline == Int32(1)
        return Int32(2)
    else
        return Int32(0)  # JUNK detected!
    end
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    println("test_output_after_nary(\"$input\") = ", test_output_after_nary(input))
    println("test_errors_after_nary(\"$input\") = ", test_errors_after_nary(input))
    println("test_peek_after_nary(\"$input\") = ", test_peek_after_nary(input))
    println("test_junk_peek(\"$input\") = ", test_junk_peek(input))
end

do_test("test_output_after_nary", test_output_after_nary)
do_test("test_errors_after_nary", test_errors_after_nary)
do_test("test_peek_after_nary", test_peek_after_nary)
do_test("test_junk_peek", test_junk_peek)
