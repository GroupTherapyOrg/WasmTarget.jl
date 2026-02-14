#!/usr/bin/env julia
# PURE-325 Agent 27: Diagnose the "1+1" crash
# Strategy: compile a simple function that calls parsestmt(Expr, "1+1")
# but wraps it in try/catch to detect where the crash happens
using WasmTarget, JuliaSyntax

# Test 1: Simple check — does node_to_expr return nothing for any child?
# We can't test node_to_expr directly because it needs cursor state.
# But we can test parsestmt — if it crashes, the bug is in the build_tree path.
# If it succeeds, the fix worked.

# Instead of testing the internals, let me test smaller steps of what parsestmt does.
# parsestmt(Expr, s) calls:
#   _parse(Symbol, Bool, Expr, s, 1) which calls:
#     ParseStream(s) -> parse!(stream) -> build_tree(Expr, stream)
#
# build_tree(Expr, stream) is where it goes from GreenNode -> Expr
# This involves: node_to_expr -> parseargs! -> recursive node_to_expr
#
# From agents 22, the cursor iteration works fine. The issue is in what
# node_to_expr does WITH the iterated children.
#
# Key insight: for "1+1", the tree is:
#   toplevel
#     call
#       Integer("1")
#       Identifier("+")
#       Integer("1")
#
# node_to_expr on Integer("1") should call:
#   _expr_leaf_val -> parse_julia_literal(txtbuf, head, range) -> 1
# This works in isolation (test_pjl_int = 1 CORRECT).
#
# node_to_expr on Identifier("+") should call:
#   _expr_leaf_val -> parse_julia_literal(txtbuf, head, range) -> Symbol("+")
# And then is_identifier(k) returns true -> lower_identifier_name(val, k) -> :+
#
# The crash could be because:
# 1. parse_julia_literal for Identifier("+") crashes (Symbol construction)
# 2. node_to_expr returns nothing (should_include_node returns false)
# 3. fixup_Expr_child fails (the "x" crash is here — illegal cast)

# Let me test parse_julia_literal for Identifier("+")
function test_pjl_identifier()::Int32
    txtbuf = UInt8[UInt8('+')]
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"Identifier", JuliaSyntax.RawFlags(0x0000))
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, 1:1)
    if result isa Symbol
        return Int32(1)  # Symbol returned
    elseif result isa Int64
        return Int32(-1)  # wrong type
    else
        return Int32(-2)  # unexpected
    end
end

# Test parse_julia_literal for operator "+"
function test_pjl_operator()::Int32
    txtbuf = UInt8[UInt8('+')]
    head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"+", JuliaSyntax.RawFlags(0x0000))
    result = JuliaSyntax.parse_julia_literal(txtbuf, head, 1:1)
    if result isa Symbol
        return Int32(1)
    elseif result === nothing
        return Int32(0)
    else
        return Int32(-1)
    end
end

# Native ground truth
println("=== Native Julia ===")
println("test_pjl_identifier(): ", test_pjl_identifier())
println("test_pjl_operator(): ", test_pjl_operator())

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
            const exp = $(expected);
            console.log('$(func_name): ' + r + (r === exp ? ' CORRECT' : ' WRONG (expected ' + exp + ')'));
        } catch(e) {
            console.log('$(func_name): FAIL — ' + e.message.substring(0, 100));
            const stack = e.stack || '';
            const lines = stack.split('\\n').filter(l => l.includes('wasm'));
            if (lines.length > 0) console.log('  at: ' + lines[0].trim());
        }
    })();
    """
    tmpf = tempname() * ".js"
    write(tmpf, node_test)
    return strip(read(`node $tmpf`, String))
end

for (name, func, expected) in [
    ("test_pjl_identifier", test_pjl_identifier, 1),
    ("test_pjl_operator", test_pjl_operator, 1),
]
    println("\n=== Compiling $name ===")
    try
        bytes = compile(func, ())
        println("$name: $(length(bytes)) bytes")
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("$nfuncs functions, VALIDATES")
        wasm_file = "WasmTarget.jl/browser/$(name).wasm"
        write(wasm_file, bytes)
        println(run_node_test(wasm_file, name, expected))
    catch e
        println("$name: ERROR — ", sprint(showerror, e))
    end
end
