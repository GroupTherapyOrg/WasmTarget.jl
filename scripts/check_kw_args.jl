using JuliaSyntax

# Check argument mapping for #parse!#73
func = getfield(JuliaSyntax, Symbol("#parse!#73"))
sig = Tuple{Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream}
ci = Base.code_typed(func, sig; optimize=false)  # unoptimized to see arg names
if length(ci) > 0
    ir = ci[1][1]
    # Print slot names (argument names)
    println("Slot names: ", ir.slotnames)
    println("Slot types: ", ir.slottypes)
    println()
    # Also print the first few statements
    for (i, stmt) in enumerate(ir.code[1:min(15, end)])
        println("SSA $i [$(ir.ssavaluetypes[i])]: $stmt")
    end
end

println("\n--- Optimized version ---")
ci2 = Base.code_typed(func, sig; optimize=true)
if length(ci2) > 0
    ir2 = ci2[1][1]
    for (i, stmt) in enumerate(ir2.code)
        println("SSA $i [$(ir2.ssavaluetypes[i])]: $stmt")
    end
end
