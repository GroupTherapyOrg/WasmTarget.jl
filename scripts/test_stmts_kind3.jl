#!/usr/bin/env julia
# PURE-324 attempt 21: What is the 3rd output node from parse_stmts in Wasm?

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

# What kind is output[3] after parse_stmts?
function test_stmts_kind3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    if length(stream.output) >= 3
        h = JuliaSyntax.head(stream.output[3])
        return reinterpret(UInt16, h.kind) % Int32
    end
    return Int32(-1)
end

# What are the flags of output[3]?
function test_stmts_flags3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    if length(stream.output) >= 3
        h = JuliaSyntax.head(stream.output[3])
        return h.flags % Int32
    end
    return Int32(-1)
end

# What is the byte_span of output[3]?
function test_stmts_span3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    if length(stream.output) >= 3
        return stream.output[3].byte_span % Int32
    end
    return Int32(-1)
end

# What is the nspan of output[3]?
function test_stmts_nspan3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    if length(stream.output) >= 3
        return stream.output[3].node_span_or_orig_kind % Int32
    end
    return Int32(-1)
end

# What does peek return right after parse_Nary in parse_stmts context?
# Can't call parse_stmts internals directly, but can compile parse_stmts
# and check peek after it returns
function test_peek_after_stmts(s::String)
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)
    JuliaSyntax.parse_stmts(ps)
    k = Base.peek(stream)
    return reinterpret(UInt16, k) % Int32
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    println("test_stmts_kind3(\"$input\") = ", test_stmts_kind3(input))
    println("test_stmts_flags3(\"$input\") = ", test_stmts_flags3(input))
    println("test_stmts_span3(\"$input\") = ", test_stmts_span3(input))
    println("test_stmts_nspan3(\"$input\") = ", test_stmts_nspan3(input))
    println("test_peek_after_stmts(\"$input\") = ", test_peek_after_stmts(input))
end

do_test("test_stmts_kind3", test_stmts_kind3)
do_test("test_stmts_flags3", test_stmts_flags3)
do_test("test_stmts_span3", test_stmts_span3)
do_test("test_stmts_nspan3", test_stmts_nspan3)
do_test("test_peek_after_stmts", test_peek_after_stmts)
