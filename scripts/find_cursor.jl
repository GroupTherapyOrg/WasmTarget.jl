using JuliaSyntax

# Find the method for node_to_expr with cursor argument
ms = methods(JuliaSyntax.node_to_expr)
for m in ms
    println(m)
end
