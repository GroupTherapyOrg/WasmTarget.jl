#!/usr/bin/env julia
# PURE-324 attempt 21: What does peek(ps, skip_newlines=true) return after parse_stmts("1")?
# We can't call parse_stmts directly, but parse! calls parse_toplevel.
# Instead, compile a function that:
# 1. Creates ParseStream
# 2. Creates ParseState
# 3. Calls parse_Nary (which is what parse_stmts does first)
# 4. Returns peek(ps, skip_newlines=true)

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

# Test: what kind does peek return after parse! with skip_newlines=true?
# We access stream internals to get the kind value directly
function test_peek_after_parse(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    # After parse!, lookahead should contain EndMarker
    # peek with skip_newlines=true should return EndMarker kind
    k = Base.peek(stream, skip_newlines=true)
    return reinterpret(UInt16, k) % Int32
end

# Test: peek without skip_newlines after parse!
function test_peek_noskip_after_parse(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    k = Base.peek(stream)
    return reinterpret(UInt16, k) % Int32
end

# Test: lookahead_index after parse!
function test_la_index(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return stream.lookahead_index % Int32
end

# Test: lookahead length after parse!
function test_la_len(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return length(stream.lookahead) % Int32
end

# Test: kind of token at lookahead[lookahead_index] after parse!
function test_la_current_kind(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    i = stream.lookahead_index
    tok = stream.lookahead[i]
    k = JuliaSyntax.kind(tok)
    return reinterpret(UInt16, k) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
println("EndMarker kind = ", reinterpret(UInt16, JuliaSyntax.K"EndMarker"))
for input in ["1", "hello"]
    println("test_peek_after_parse(\"$input\") = ", test_peek_after_parse(input))
    println("test_peek_noskip_after_parse(\"$input\") = ", test_peek_noskip_after_parse(input))
    println("test_la_index(\"$input\") = ", test_la_index(input))
    println("test_la_len(\"$input\") = ", test_la_len(input))
    println("test_la_current_kind(\"$input\") = ", test_la_current_kind(input))
end

# Compile
do_test("test_peek_after_parse", test_peek_after_parse)
do_test("test_peek_noskip_after_parse", test_peek_noskip_after_parse)
do_test("test_la_index", test_la_index)
do_test("test_la_len", test_la_len)
do_test("test_la_current_kind", test_la_current_kind)
