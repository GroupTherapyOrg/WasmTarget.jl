#!/usr/bin/env julia
# PURE-6023 Agent 43: Granular parse diagnostics
# Tests individual substeps to find exact trap location

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Stage A: Create ParseStream (already works)
function diag_a_create_ps(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    return Int64(1)
end

# Stage B: Access the internal textbuf
function diag_b_textbuf(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    buf = JuliaSyntax.unsafe_textbuf(ps)
    return Int64(length(buf))
end

# Stage C: Access the first byte of textbuf
function diag_c_first_byte(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    buf = JuliaSyntax.unsafe_textbuf(ps)
    if length(buf) > 0
        return Int64(buf[1])
    end
    return Int64(-1)
end

# Stage D: Call parse! with rule=:statement
function diag_d_parse(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    JuliaSyntax.parse!(ps; rule=:statement)
    return Int64(2)
end

# Stage E: Create cursor after parse
function diag_e_cursor(v::Vector{UInt8})::Int64
    ps = JuliaSyntax.ParseStream(v)
    JuliaSyntax.parse!(ps; rule=:statement)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    return Int64(3)
end

# Helpers
sbv = getfield(Main, Symbol("set_byte_vec!"))

funcs = [
    (diag_a_create_ps, (Vector{UInt8},)),
    (diag_b_textbuf, (Vector{UInt8},)),
    (diag_c_first_byte, (Vector{UInt8},)),
    (diag_d_parse, (Vector{UInt8},)),
    (diag_e_cursor, (Vector{UInt8},)),
    (make_byte_vec, (Int32,)),
    (sbv, (Vector{UInt8}, Int32, Int32)),
]

println("Compiling parse stages diagnostic module...")
t = time()
bytes = WasmTarget.compile_multi(funcs)
dt = time() - t

outpath = "/tmp/diag_parse_stages.wasm"
write(outpath, bytes)
println("  Size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
println("  Time: $(round(dt, digits=1))s")

# Validate
try
    Base.run(pipeline(`wasm-tools validate --features=gc $outpath`, stderr=devnull, stdout=devnull))
    println("  Validate: PASS")
catch
    println("  Validate: FAIL")
end

# Count functions
nfuncs = count("(func ", read(pipeline(`wasm-tools print $outpath`), String))
println("  Functions: $nfuncs")
