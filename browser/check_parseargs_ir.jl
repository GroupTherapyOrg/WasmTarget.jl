#!/usr/bin/env julia
using JuliaSyntax

f = getfield(JuliaSyntax, Symbol("parseargs!"))
sig = (Expr, LineNumberNode, JuliaSyntax.RedTreeCursor, SourceFile, Vector{UInt8}, UInt32)
ir = Base.code_typed(f, sig)[1][1]

for (i, stmt) in enumerate(ir.code)
    if stmt isa Expr && stmt.head === :call
        func = stmt.args[1]
        if func isa GlobalRef && string(func.name) == "memoryrefset!"
            println("SSA %$i: $(stmt)")
            println("  func = $func")
            println("  func.mod = $(func.mod)")
            println("  func.name = $(func.name)")
            println("  stmt.head = $(stmt.head)")
        end
    end
    # Also check for builtins
    if stmt isa Expr && stmt.head === :foreigncall
        println("SSA %$i: foreigncall $(stmt.args[1])")
    end
end
