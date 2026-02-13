#!/usr/bin/env julia
# PURE-324: Compare Stage C (404 funcs, PASS) vs Stage D (488 funcs, FAIL)
# Goal: find what type/func index shifts cause the array bounds crash

using WasmTarget
using JuliaSyntax

# Stage C: parse!() chain — passes at runtime
function parse_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
end

# Stage D: full parsestmt — crashes at runtime
function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

println("=== Compiling Stage C ===")
bytes_c = compile(parse_test, (String,))
f_c = tempname() * ".wasm"
write(f_c, bytes_c)
run(`wasm-tools validate --features=gc $f_c`)
nfuncs_c = Base.parse(Int, strip(read(`bash -c "wasm-tools print $f_c | grep -c '(func'"`, String)))
println("Stage C: $nfuncs_c funcs, $(length(bytes_c)) bytes, validates")

# Count types in Stage C
ntypes_c = Base.parse(Int, strip(read(`bash -c "wasm-tools print $f_c | grep -c '(type '"`, String)))
println("Stage C: $ntypes_c types")

println("\n=== Compiling Stage D ===")
bytes_d = compile(parse_expr_string, (String,))
f_d = tempname() * ".wasm"
write(f_d, bytes_d)
run(`wasm-tools validate --features=gc $f_d`)
nfuncs_d = Base.parse(Int, strip(read(`bash -c "wasm-tools print $f_d | grep -c '(func'"`, String)))
println("Stage D: $nfuncs_d funcs, $(length(bytes_d)) bytes, validates")

ntypes_d = Base.parse(Int, strip(read(`bash -c "wasm-tools print $f_d | grep -c '(type '"`, String)))
println("Stage D: $ntypes_d types")

println("\nDifference: $(nfuncs_d - nfuncs_c) extra funcs, $(ntypes_d - ntypes_c) extra types")

# Write Stage D for testing
cp(f_d, joinpath(@__DIR__, "..", "browser", "parsestmt.wasm"), force=true)

# Write Stage C for comparison testing
cp(f_c, joinpath(@__DIR__, "..", "browser", "parsestmt_stagec.wasm"), force=true)

# Test Stage C
node_test_c = """
import fs from 'fs';
import path from 'path';
const d = '$(joinpath(@__DIR__, "..", "browser"))';
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync(path.join(d, 'parsestmt_stagec.wasm'));
const mod = await rt.load(w, 'parse_test');
const s = await rt.jsToWasmString('1');
try { const r = mod.exports.parse_test(s); console.log('Stage C PASS: ' + r); }
catch(e) { console.log('Stage C FAIL: ' + e.message); console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).join('\\n')); }
"""
f_test_c = tempname() * ".mjs"
write(f_test_c, node_test_c)
println("\n=== Testing Stage C ===")
run(`node $f_test_c`)

# Test Stage D
node_test_d = """
import fs from 'fs';
import path from 'path';
const d = '$(joinpath(@__DIR__, "..", "browser"))';
const rc = fs.readFileSync(path.join(d, 'wasmtarget-runtime.js'), 'utf-8');
const WRT = new Function(rc + '\\nreturn WasmTargetRuntime;')();
const rt = new WRT();
const w = fs.readFileSync(path.join(d, 'parsestmt.wasm'));
const mod = await rt.load(w, 'parsestmt');
const s = await rt.jsToWasmString('1');
try { const r = mod.exports.parse_expr_string(s); console.log('Stage D PASS: ' + r); }
catch(e) { console.log('Stage D FAIL: ' + e.message); console.log(e.stack.split('\\n').filter(l=>l.includes('wasm')).join('\\n')); }
"""
f_test_d = tempname() * ".mjs"
write(f_test_d, node_test_d)
println("\n=== Testing Stage D ===")
run(`node $f_test_d`)

# Compare array type at index 1 between stages
println("\n=== Array type 1 comparison ===")
println("Stage C array types:")
run(`bash -c "wasm-tools print $f_c | grep -n 'array' | head -10"`)
println("Stage D array types:")
run(`bash -c "wasm-tools print $f_d | grep -n 'array' | head -10"`)
