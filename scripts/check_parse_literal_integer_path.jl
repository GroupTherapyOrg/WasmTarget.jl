using JuliaSyntax

# Get the IR for parse_julia_literal - focus on Integer path
SH = JuliaSyntax.SyntaxHead
ci, rt = only(Base.code_typed(JuliaSyntax.parse_julia_literal,
    (Vector{UInt8}, SH, UnitRange{UInt32}); optimize=true))

println("Total statements: ", length(ci.code))
println("Return type: ", rt)

# The Integer return is at stmt 516: return parse_int_literal(%512)
# %512 is a phi node from string construction
# Let's trace the path that leads to the Integer check

println("\n=== Statements 351-520 (number/string construction → Integer check) ===")
for i in 351:min(520, length(ci.code))
    stmt = ci.code[i]
    ty = ci.ssavaluetypes[i]
    is_special = stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
                 stmt isa Core.GotoNode || (stmt isa Expr && stmt.head == :invoke)
    if is_special
        println(">>> $i: $(ci.code[i]) :: $ty")
    else
        println("    $i: $(ci.code[i]) :: $ty")
    end
end

# Also show the string construction leading up to %512
println("\n=== Statements 441-516 (string from bytes → parse_int_literal) ===")
for i in 441:516
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end

# The first check at line 1 is kind === K"Float", then K"Float32", K"Char", ...
# What kind check leads to the Integer path?
# Let's trace the kind checks sequence
println("\n=== Kind check sequence ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Expr && stmt.head == :(===) && length(stmt.args) >= 2
        println("  $i: $(stmt) :: $(ci.ssavaluetypes[i])")
    elseif stmt isa Expr && stmt.head == :call && length(stmt.args) >= 2
        s = string(stmt)
        if occursin("===", s)
            println("  $i: $(stmt) :: $(ci.ssavaluetypes[i])")
        end
    end
    # Also check for Core.ifelse or === patterns
    ty = ci.ssavaluetypes[i]
    s = string(stmt)
    if occursin("K\"", s) || occursin("===", s)
        println("  $i: $stmt :: $ty")
    end
end
