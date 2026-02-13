#!/usr/bin/env julia
# PURE-324 attempt 11: Bisect between Stage C3 (passes) and Stage D (fails)
# Stage C3: parse! + return nothing = 403 funcs — PASSES
# Stage D: parsestmt(Expr, s) = 488 funcs — FAILS with array bounds
# Goal: find which functions between C3 and D cause the crash

using WasmTarget
using JuliaSyntax

function test_stage(name, f, arg_types)
    println("\n=== $name ===")
    try
        bytes = compile(f, arg_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("$name: $nfuncs funcs, $(length(bytes)) bytes, validates")

        # Write wasm for Node test
        wasmfile = joinpath(@__DIR__, "..", "browser", "$(name).wasm")
        cp(tmpf, wasmfile, force=true)

        export_name = string(nameof(f))
        node_test = """
const fs = require('fs');
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
(async () => {
    const rt = new WRT();
    const w = fs.readFileSync('$wasmfile');
    const mod = await rt.load(w, '$export_name');
    const s = await rt.jsToWasmString('1');
    try {
        const r = mod.exports.$export_name(s);
        console.log('$name PASS: result=' + r);
    } catch(e) {
        console.log('$name FAIL: ' + e.message);
        const lines = e.stack.split('\\n');
        for (const l of lines) { if (l.includes('wasm')) console.log('  ' + l.trim()); }
    }
})();
"""
        f_test = tempname() * ".js"
        write(f_test, node_test)
        node_output = read(`node $f_test`, String)
        println(strip(node_output))
        return (nfuncs, true)
    catch e
        println("$name ERROR: $e")
        return (0, false)
    end
end

# Stage C3: parse! + return nothing — KNOWN PASS (403 funcs)
function stage_c3_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return nothing
end

# Stage C3b: parse! + return something minimal (test what parse! returns)
function stage_c3b_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    # Return the number of output tokens (avoids tree building)
    return Int32(length(stream.output))
end

# Stage C4: parse! + Expr conversion without parsestmt wrapper
function stage_c4_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    t = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
    return nothing
end

# Stage D: full parsestmt(Expr, s) — KNOWN FAIL
function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

test_stage("stage_c3", stage_c3_test, (String,))
test_stage("stage_c3b", stage_c3b_test, (String,))
test_stage("stage_c4", stage_c4_test, (String,))
test_stage("stage_d", parse_expr_string, (String,))
