using WasmTarget
using JuliaSyntax

# Check what WasmTarget's codegen sees for #parse!#73
func = getfield(JuliaSyntax, Symbol("#parse!#73"))
sig = Tuple{Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream}

# Get code_typed the same way WasmTarget does
ci = Base.code_typed(func, sig; optimize=true)
ir = ci[1][1]
ret_type = ci[1][2]

println("Function: #parse!#73")
println("Signature: $sig")
println("Return type: $ret_type")
println()

# What does WasmTarget think the arg types are?
# WasmTarget uses Base.code_typed and then reads the arg types from the signature
# Argument mapping:
# _1 = the function itself (skipped in regular functions)
# _2 = first real arg (rule::Symbol)
# _3 = second real arg (parse! function value - but it's typeof so gets optimized out?)
# _4 = third real arg (stream::ParseStream)

# Check: In optimized IR, what is Core.Argument(2)?
# It should be the `rule` Symbol
for (i, stmt) in enumerate(ir.code)
    s = string(stmt)
    if occursin("Argument(", s) || occursin("_2", s) || occursin("_4", s)
        println("SSA $i: $stmt")
    end
end

println()

# Also check: what does the compile function actually get for arg_types?
# WasmTarget.compile_multi would be what parsestmt uses
# Let's check what parse_expr_string compiles to
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)
println("=== parse_expr_string compilation ===")
ci2 = Base.code_typed(parse_expr_string, (String,); optimize=true)
ir2 = ci2[1][1]
println("Statements: ", length(ir2.code))
# Find the call to #parse!#73
for (i, stmt) in enumerate(ir2.code)
    s = string(stmt)
    if occursin("parse!", s) || occursin("#73", s) || occursin("statement", s) || occursin(":all", s)
        println("SSA $i: $stmt")
    end
end
