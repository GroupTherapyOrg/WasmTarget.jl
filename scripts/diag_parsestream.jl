#!/usr/bin/env julia
# PURE-6023 Agent 43: Diagnostic — isolate ParseStream trap in fresh compile
# Test each step of the _wasm_eval_arith dependency chain individually

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Stage 0: Just make a byte vec and return its length (baseline)
function diag_len(v::Vector{UInt8})::Int64
    return Int64(length(v))
end

# Stage 1: Create ParseStream from bytes
function diag_ps_create(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    return Int64(1)  # survived
end

# Stage 2: Create ParseStream + parse
function diag_ps_parse(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    JuliaSyntax.parse!(ps; rule=:statement)
    return Int64(2)  # survived
end

# Stage 3: Create + parse + cursor
function diag_ps_cursor(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    JuliaSyntax.parse!(ps; rule=:statement)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    return Int64(3)  # survived
end

# Stage 4: Full _wasm_eval_arith (should match old module)
# Already included from eval_julia.jl

sbv = getfield(Main, Symbol("set_byte_vec!"))

funcs = [
    (diag_len, (Vector{UInt8},)),
    (diag_ps_create, (Vector{UInt8},)),
    (diag_ps_parse, (Vector{UInt8},)),
    (diag_ps_cursor, (Vector{UInt8},)),
    (_wasm_eval_arith, (Vector{UInt8},)),
    (make_byte_vec, (Int32,)),
    (sbv, (Vector{UInt8}, Int32, Int32)),
]

println("Compiling diagnostic ParseStream module...")
t = time()
bytes = WasmTarget.compile_multi(funcs)
dt = time() - t

outpath = "/tmp/diag_parsestream.wasm"
write(outpath, bytes)
nfuncs = count("(func", read(pipeline(`wasm-tools print $outpath`), String))
println("  Funcs: $nfuncs")
println("  Size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
println("  Time: $(round(dt, digits=1))s")

errbuf = IOBuffer()
local validate_ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $outpath`, stderr=errbuf, stdout=devnull))
    validate_ok = true
catch; end
println("  Validate: $(validate_ok ? "PASS" : "FAIL")")
if !validate_ok
    println("  $(String(take!(errbuf)))")
end
