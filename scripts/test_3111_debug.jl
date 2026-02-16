using WasmTarget, Core.Compiler

# Look at the IR for the tmerge function to understand its control flow
# tmerge is a cross-call dependency of record_slot_assign!
# Let's look at a simple tmerge signature

# What exact tmerge method is being compiled as func 2?
# From the export list, func 2 is "tmerge" with type (ref null 52) externref externref) (result externref)
# This is probably Core.Compiler.tmerge(::JLTypeLattice, ::Any, ::Any) -> Any

println("=== tmerge methods ===")
for m in methods(Core.Compiler.tmerge)
    println(m)
end

println("\n=== Code info for tmerge(JLTypeLattice, Any, Any) ===")
ci = code_typed(Core.Compiler.tmerge, (Core.Compiler.JLTypeLattice, Any, Any))
if !isempty(ci)
    code_info = ci[1][1]
    for (i, stmt) in enumerate(code_info.code)
        println("$i: $(typeof(stmt)) - $stmt")
    end
end
