using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))

# Show statements 273-450 covering the integer parsing path
# Line 447 returns %356 which is the integer result
for i in 273:min(450, length(ci.code))
    stmt = ci.code[i]
    ty = ci.ssavaluetypes[i]
    is_special = stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
                 stmt isa Core.GotoNode || (stmt isa Expr && (stmt.head == :invoke || stmt.head == :foreigncall))
    if is_special
        println(">>> $i: $(ci.code[i]) :: $ty")
    else
        println("    $i: $(ci.code[i]) :: $ty")
    end
end
