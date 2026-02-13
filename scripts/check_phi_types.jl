using JuliaSyntax

# Get code_typed for #parse!#73 with Symbol as the rule type
func = getfield(JuliaSyntax, Symbol("#parse!#73"))
sig = Tuple{Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream}
ci = Base.code_typed(func, sig; optimize=true)
if length(ci) > 0
    ir = ci[1][1]
    println("Total statements: ", length(ir.code))
    println()

    # Print ALL statements to see full control flow
    for (i, stmt) in enumerate(ir.code)
        t = ir.ssavaluetypes[i]
        println("SSA $i [$(t)]: $(stmt)")
    end

    println("\n--- Return type: $(ci[1][2]) ---")
end
