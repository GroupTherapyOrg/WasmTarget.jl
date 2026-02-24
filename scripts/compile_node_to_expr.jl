#!/usr/bin/env julia
# Compile node_to_expr standalone + test wrapper
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax

# Wrapper: creates ParseStream, parses, calls node_to_expr, returns something testable
function test_node_to_expr(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    source = JuliaSyntax.SourceFile(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    e = JuliaSyntax.node_to_expr(cursor, source, txtbuf, UInt32(0))
    if e === nothing
        return Int32(-3)
    end
    if e isa Expr
        return Int32(length(e.args))
    end
    if e isa Integer
        return Int32(e)
    end
    return Int32(99)
end

# Helper for creating byte vectors from JS
function make_byte_vec(n::Int32)::Vector{UInt8}
    Vector{UInt8}(undef, Int(n))
end
function set_byte_vec!(v::Vector{UInt8}, idx::Int32, val::Int32)::Int32
    v[Int(idx)] = UInt8(val)
    Int32(0)
end

println("Step 0: Verify natively...")
for (code, expected) in [("1", 1), ("42", 42), ("1+1", 3)]
    r = test_node_to_expr(Vector{UInt8}(codeunits(code)))
    println("  test_node_to_expr(\"$code\") = $r (expected $expected) — $(r == expected ? "OK" : "WRONG")")
end

println("\nStep 1: Compile...")
seed = [
    (test_node_to_expr, (Vector{UInt8},)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
]
t0 = time()
wasm_bytes = WasmTarget.compile_multi(seed)
dt = time() - t0
println("  $(length(wasm_bytes)) bytes ($(round(dt, digits=1))s)")

outf = joinpath(@__DIR__, "..", "output", "node_to_expr_test.wasm")
write(outf, wasm_bytes)

println("\nStep 2: Validate...")
errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $outf`, stderr=errbuf))
    ok = true
catch; end
if ok
    println("  VALIDATES ✓")
    pb = IOBuffer()
    Base.run(pipeline(`wasm-tools print $outf`, stdout=pb))
    fc = count(l -> contains(l, "(func "), split(String(take!(pb)), '\n'))
    println("  Functions: $fc")
else
    println("  VALIDATE_ERROR: ", String(take!(errbuf)))
end
