#!/usr/bin/env julia
# PURE-324 attempt 21: What does peek() return after parsing the expression?
# Key hypothesis: peek() doesn't return EndMarker after parsing "1",
# causing parse_stmts error recovery to fire and emit error token

using WasmTarget
using JuliaSyntax

# First check: what does peek return after the main parse?
# In parse_stmts, after parse_Nary completes, there's:
#   while peek(ps) ∉ KSet"EndMarker NewlineWs"
# We need to know what peek returns at that point.

# Strategy: compile a function that calls parse! and then checks peek
# BUT parse_stmts is internal... We can't directly call it.

# Alternative: Return the byte_span of output[3] to see if the error token has span
function test_output_span_3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    # output[3] should be toplevel in native, error in Wasm
    return stream.output[3].byte_span % Int32
end

# Return the byte_span of output[4] if it exists (0 otherwise)
function test_output_span_4(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    if length(stream.output) >= 4
        return stream.output[4].byte_span % Int32
    end
    return Int32(-1)
end

# Return next_byte before and after parse
function test_nb_diff(s::String)
    stream = JuliaSyntax.ParseStream(s)
    nb_before = stream.next_byte
    JuliaSyntax.parse!(stream)
    nb_after = stream.next_byte
    return (nb_after - nb_before) % Int32
end

# Return the node_span_or_orig_kind of output[3] (this differentiates terminal from nonterminal)
function test_output_nspan_3(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    node = stream.output[3]
    return node.node_span_or_orig_kind % Int32
end

# Check: is output[3] a terminal node? (node_span_or_orig_kind <= 0 means nonterminal)
# Actually, RawGreenNode: if is_terminal(node), node_span_or_orig_kind is orig_kind
# If !is_terminal(node), node_span_or_orig_kind is -node_span (negative = nonterminal)

# Native ground truth
println("=== Native Julia Ground Truth ===")
for input in ["1", "hello"]
    stream = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(stream)
    println("parse!(\"$input\"):")
    println("  output_len = ", length(stream.output))
    println("  nb_before = 1, nb_after = ", stream.next_byte)
    for i in 1:length(stream.output)
        node = stream.output[i]
        h = JuliaSyntax.head(node)
        println("  out[$i]: kind=$(h.kind), span=$(node.byte_span), nspan=$(node.node_span_or_orig_kind), flags=$(h.flags)")
    end
    # Check what position the toplevel node covers
    println("  toplevel at out[3], covers ", stream.output[3].byte_span, " bytes")
end

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

# Run tests
println("\nNative ground truth for specific functions:")
for input in ["1", "hello"]
    println("test_output_span_3(\"$input\") = ", test_output_span_3(input))
    println("test_nb_diff(\"$input\") = ", test_nb_diff(input))
    println("test_output_nspan_3(\"$input\") = ", test_output_nspan_3(input))
end

do_test("test_output_span_3", test_output_span_3)
do_test("test_output_span_4", test_output_span_4)
do_test("test_nb_diff", test_nb_diff)
do_test("test_output_nspan_3", test_output_nspan_3)
