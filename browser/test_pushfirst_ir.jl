#!/usr/bin/env julia
# Look at IR for pushfirst! pattern from parseargs!

function test_pf(args::Vector{Any}, val::Any)
    pushfirst!(args, val)
    return args
end

ir = Base.code_typed(test_pf, (Vector{Any}, Any))[1]
println(ir[1])
println("\n---")

# Also look at how pushfirst! itself compiles
ir2 = Base.code_typed(pushfirst!, (Vector{Any}, Any))[1]
println(ir2[1])
