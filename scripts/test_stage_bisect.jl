#!/usr/bin/env julia
# PURE-324: Binary search between Stage C (404 funcs, PASS) and Stage D (488 funcs, FAIL)
# Goal: find which additional function(s) cause the crash

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

        # Write wasm and test in Node
        wasmfile = joinpath(@__DIR__, "..", "browser", "test_$name.wasm")
        cp(tmpf, wasmfile, force=true)

        export_name = string(nameof(f))
        node_test = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$wasmfile');
const mod = await rt.load(w, '$export_name');
const s = await rt.jsToWasmString('1');
try {
    const r = mod.exports.$export_name(s);
    console.log('$name PASS: result=' + r);
} catch(e) {
    console.log('$name FAIL: ' + e.message);
    console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n'));
}
"""
        f_test = tempname() * ".mjs"
        write(f_test, node_test)
        run(`node $f_test`)
        return (nfuncs, true)
    catch e
        println("$name ERROR: $e")
        return (0, false)
    end
end

# Stage C: parse! only — KNOWN PASS
function stage_c(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
end

# Stage C2: parse! + build_tree — intermediate
function stage_c2(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    t = JuliaSyntax.build_tree(JuliaSyntax.GreenNode, stream)
    return t
end

# Stage D: full parsestmt(Expr, s) — KNOWN FAIL
function stage_d(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

test_stage("stage_c", stage_c, (String,))
test_stage("stage_c2", stage_c2, (String,))
test_stage("stage_d", stage_d, (String,))
