#!/usr/bin/env julia
using JuliaLowering

function count_ir()
    CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}
    ir, rt = Base.code_ircode(JuliaLowering._to_lowered_expr, (CT, Int64))[1]

    calls = 0
    invokes = 0
    for stmt in ir.stmts.stmt
        if stmt isa Expr
            if stmt.head === :invoke
                invokes += 1
            elseif stmt.head === :call
                calls += 1
            end
        end
    end
    println("In code_ircode: $invokes invokes, $calls calls")

    # Also check code_typed
    ci, rt2 = code_typed(JuliaLowering._to_lowered_expr, (CT, Int64))[1]
    calls2 = 0
    invokes2 = 0
    for stmt in ci.code
        if stmt isa Expr
            if stmt.head === :invoke
                invokes2 += 1
            elseif stmt.head === :call
                calls2 += 1
            end
        end
    end
    println("In code_typed:  $invokes2 invokes, $calls2 calls")
end
count_ir()
