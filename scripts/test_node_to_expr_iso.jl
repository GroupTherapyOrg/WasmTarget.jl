#!/usr/bin/env julia
# PURE-325 Agent 27: Isolate node_to_expr on "1+1" children
using WasmTarget, JuliaSyntax

# Test 1: Does parse_julia_literal work for K"Integer" in the full module?
function test_pjl_int()::Int64
    txtbuf = UInt8[0x31]  # "1"
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Integer", JuliaSyntax.RawFlags(0x0000))
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, 1:1)
    if result isa Int64
        return result
    elseif result isa Int128
        return Int64(2)
    elseif result isa Symbol
        return Int64(-1)
    else
        return Int64(-999)
    end
end

# Test 2: parsestmt for "1" — leaf only, should work
function test_parsestmt_leaf()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1")
    if result isa Int64
        return Int32(result)
    elseif result isa Expr
        return Int32(2)
    else
        return Int32(-1)
    end
end

# Test 3: parsestmt for "1+1" — the crash reproducer
function test_parsestmt_call()::Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    if result isa Expr
        return Int32(1)
    else
        return Int32(0)
    end
end

# Native Julia ground truth
println("=== Native Julia Ground Truth ===")
println("test_pjl_int(): ", test_pjl_int())
println("test_parsestmt_leaf(): ", test_parsestmt_leaf())
println("test_parsestmt_call(): ", test_parsestmt_call())
println("parsestmt(Expr, \"1\") = ", repr(JuliaSyntax.parsestmt(Expr, "1")))
println("parsestmt(Expr, \"1+1\") = ", repr(JuliaSyntax.parsestmt(Expr, "1+1")))

function run_node_test(wasm_file, func_name, expected)
    node_test = """
    const fs = require('fs');
    const rtCode = fs.readFileSync('WasmTarget.jl/browser/wasmtarget-runtime.js', 'utf-8');
    const WRT = new Function(rtCode + '\\nreturn WasmTargetRuntime;')();
    (async () => {
        const rt = new WRT();
        const w = fs.readFileSync('$wasm_file');
        const mod = await rt.load(w, 'test');
        try {
            const r = mod.exports.$(func_name)();
            const exp = $(expected)n;
            console.log('$(func_name): ' + r + (r === exp ? ' CORRECT' : ' WRONG (expected ' + exp + ')'));
        } catch(e) {
            console.log('$(func_name): FAIL — ' + e.message.substring(0, 100));
        }
    })();
    """
    tmpf = tempname() * ".js"
    write(tmpf, node_test)
    return strip(read(`node $tmpf`, String))
end

# Compile and test each function
for (name, func, args, expected) in [
    ("test_pjl_int", test_pjl_int, (), 1),
    ("test_parsestmt_leaf", test_parsestmt_leaf, (), 1),
    ("test_parsestmt_call", test_parsestmt_call, (), 1),
]
    println("\n=== Compiling $name ===")
    try
        bytes = compile(func, args)
        println("$name: $(length(bytes)) bytes")
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("$name: $nfuncs functions, VALIDATES")
        wasm_file = "WasmTarget.jl/browser/$(name).wasm"
        write(wasm_file, bytes)
        println(run_node_test(wasm_file, name, expected))
    catch e
        println("$name: ERROR — ", sprint(showerror, e))
    end
end
