using JuliaSyntax

# Get the IR for parse_julia_literal
# Signature: parse_julia_literal(textbuf::Vector{UInt8}, head::SyntaxHead, rng::UnitRange{UInt32})
SH = JuliaSyntax.SyntaxHead
ci, rt = only(Base.code_typed(JuliaSyntax.parse_julia_literal,
    (Vector{UInt8}, SH, UnitRange{UInt32}); optimize=true))

println("Total statements: ", length(ci.code))
println("Return type: ", rt)
println()

# Show ALL invoke calls and return statements
println("=== Key statements (invokes + returns + gotos) ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    ty = ci.ssavaluetypes[i]
    is_special = stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
                 stmt isa Core.GotoNode || (stmt isa Expr && stmt.head == :invoke)
    if is_special
        println(">>> $i: $(ci.code[i]) :: $ty")
    end
end

println("\n=== All return statements with 5-line context ===")
for i in 1:length(ci.code)
    if ci.code[i] isa Core.ReturnNode
        println("--- Return at stmt $i ---")
        for j in max(1,i-5):i
            println("  $j: $(ci.code[j]) :: $(ci.ssavaluetypes[j])")
        end
        println()
    end
end

# Show the first 50 statements to understand the entry logic
println("\n=== First 50 statements ===")
for i in 1:min(50, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end
