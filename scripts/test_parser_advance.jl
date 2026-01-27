#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using WasmTarget: compile_multi

parser_advance_fn = getfield(WasmTarget, Symbol("parser_advance!"))

bytes = compile_multi([
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_list_new, (Int32,)),
    (WasmTarget.token_list_get, (WasmTarget.TokenList, Int32)),
    (WasmTarget.parser_current, (WasmTarget.Parser,)),
    (parser_advance_fn, (WasmTarget.Parser,)),
])

println("Compiled $(length(bytes)) bytes")

tempfile = tempname() * ".wasm"
write(tempfile, bytes)

# Print WASM
run(`wasm-tools print $tempfile`)

# Validate
result = read(`node -e "
    const fs = require('fs');
    const wasm = fs.readFileSync('$tempfile');
    WebAssembly.compile(wasm).then(() => {
        console.log('PASSED');
    }).catch(e => {
        console.log('FAILED:', e.message);
    });
"`, String)
println(result)
