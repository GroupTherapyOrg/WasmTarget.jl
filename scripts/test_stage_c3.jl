#!/usr/bin/env julia
# PURE-324: Test calling _parse#75 directly (same as parsestmt but simpler wrapper)
# Goal: isolate whether the crash is in _parse#75 itself or the extra tree-building functions

using WasmTarget
using JuliaSyntax

# Stage C3: Call _parse directly with statement rule, like parsestmt does
# but WITHOUT tree-building (returns raw parse result)
function stage_c3(s::String)
    # This is close to what parsestmt does internally but without Type{Expr}
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    # Returns the stream (externref)
    return nothing
end

# Stage C4: Same call path as parsestmt but minimal
function stage_c4(s::String)
    # Mimic parsestmt's internal _parse call
    JuliaSyntax._parse(
        :statement,    # rule
        false,         # include_trivia
        Expr,          # return type
        s,             # text
        1              # index
    )
end

println("=== Stage C3: parse! returning nothing ===")
bytes = compile(stage_c3, (String,))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
run(`wasm-tools validate --features=gc $tmpf`)
nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
println("C3: $nfuncs funcs, $(length(bytes)) bytes")
# Write and test
cp(tmpf, joinpath(@__DIR__, "..", "browser", "test_c3.wasm"), force=true)
node_test = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_c3.wasm"))');
const mod = await rt.load(w, 'stage_c3');
const s = await rt.jsToWasmString('1');
try { const r = mod.exports.stage_c3(s); console.log('C3 PASS: ' + r); }
catch(e) { console.log('C3 FAIL: ' + e.message); console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n')); }
"""
f_test = tempname() * ".mjs"
write(f_test, node_test)
run(`node $f_test`)

println("\n=== Stage C4: _parse with Type{Expr} ===")
try
    bytes4 = compile(stage_c4, (String,))
    tmpf4 = tempname() * ".wasm"
    write(tmpf4, bytes4)
    run(`wasm-tools validate --features=gc $tmpf4`)
    nfuncs4 = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf4 | grep -c '(func'"`, String)))
    println("C4: $nfuncs4 funcs, $(length(bytes4)) bytes")
    cp(tmpf4, joinpath(@__DIR__, "..", "browser", "test_c4.wasm"), force=true)
    node_test4 = """
import fs from 'fs';
const rc = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "wasmtarget-runtime.js"))', 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync('$(joinpath(@__DIR__, "..", "browser", "test_c4.wasm"))');
const mod = await rt.load(w, 'stage_c4');
const s = await rt.jsToWasmString('1');
try { const r = mod.exports.stage_c4(s); console.log('C4 PASS: ' + r); }
catch(e) { console.log('C4 FAIL: ' + e.message); console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).map(l=>'  '+l.trim()).join('\\n')); }
"""
    f_test4 = tempname() * ".mjs"
    write(f_test4, node_test4)
    run(`node $f_test4`)
catch e
    println("C4 compilation error: $e")
end
