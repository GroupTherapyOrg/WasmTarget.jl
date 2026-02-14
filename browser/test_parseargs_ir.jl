#!/usr/bin/env julia
using JuliaSyntax

# Get the actual parseargs! function
f = getfield(JuliaSyntax, Symbol("parseargs!"))
println("Function: ", f)
println("Methods: ", methods(f))

# Get IR
sig = (Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, SourceFile, Vector{UInt8}, UInt32)
ir = Base.code_typed(f, sig)[1]
println(ir[1])
