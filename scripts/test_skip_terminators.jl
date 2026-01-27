#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using WasmTarget: compile_multi

parser_skip_fn = getfield(WasmTarget, Symbol("parser_skip_terminators!"))
parser_advance_fn = getfield(WasmTarget, Symbol("parser_advance!"))

bytes = compile_multi([
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_list_get, (WasmTarget.TokenList, Int32)),
    (WasmTarget.parser_current, (WasmTarget.Parser,)),
    (WasmTarget.parser_current_type, (WasmTarget.Parser,)),
    (parser_advance_fn, (WasmTarget.Parser,)),
    (parser_skip_fn, (WasmTarget.Parser,)),
])

println("Compiled $(length(bytes)) bytes")

tempfile = "/tmp/partial_test.wasm"
write(tempfile, bytes)

run(`wasm-tools print $tempfile`)
