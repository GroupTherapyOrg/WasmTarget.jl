using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.parseargs!,
    (Expr, LineNumberNode, RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("Total statements: ", length(ci.code))
println("Return type: ", rt)
println()

# Find key patterns: invoke, PhiNode, GotoIfNot, ReturnNode
for i in 1:length(ci.code)
    stmt = ci.code[i]
    ty = ci.ssavaluetypes[i]
    # Print everything but mark special ones
    is_special = stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
                 stmt isa Core.GotoNode || (stmt isa Expr && stmt.head == :invoke)
    if is_special
        println(">>> $i: $(ci.code[i]) :: $ty")
    else
        println("    $i: $(ci.code[i]) :: $ty")
    end
end
