#!/usr/bin/env julia
# PURE-603: Diagnose cross-call unreachable for parametric types
using JuliaLowering

CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}
ci, rt = code_typed(JuliaLowering._to_lowered_expr, (CT, Int64))[1]

# Categorize the GlobalRef :call expressions (NOT :invoke)
categories = Dict{String,Int}()
details = Dict{String,Vector{String}}()

for (i, stmt) in enumerate(ci.code)
    if stmt isa Expr && stmt.head === :call && length(stmt.args) >= 1
        f = stmt.args[1]
        if f isa GlobalRef
            is_core = (f.mod === Core)
            is_base = (f.mod === Base)
            if !is_core && !is_base
                key = "$(f.mod).$(f.name)"
                categories[key] = get(categories, key, 0) + 1

                # Get arg types
                arg_types = []
                for a in stmt.args[2:end]
                    if a isa Core.SSAValue
                        push!(arg_types, string(ci.ssavaluetypes[a.id]))
                    elseif a isa Core.Argument
                        push!(arg_types, string(ci.slottypes[a.n]))
                    elseif a isa QuoteNode
                        push!(arg_types, "QuoteNode($(a.value))")
                    else
                        push!(arg_types, string(typeof(a)))
                    end
                end
                detail = "stmt $i: $(join(arg_types, ", "))"
                if !haskey(details, key)
                    details[key] = String[]
                end
                push!(details[key], detail)
            end
        end
    end
end

println("=== GlobalRef :call expressions (NOT :invoke) ===")
println("These are the ones that become CROSS-CALL UNREACHABLE\n")

for (k, v) in sort(collect(categories), by=x->-x[2])
    println("  $(v)x  $k")
    # Show first 3 examples
    for d in details[k][1:min(3, length(details[k]))]
        println("       $d")
    end
end

println("\nTotal unique functions: $(length(categories))")
println("Total calls: $(sum(values(categories)))")

# Now check: are these functions actually callable?
println("\n=== Can we resolve these methods? ===")
for (k, _) in sort(collect(categories), by=x->-x[2])
    parts = split(k, ".")
    mod_name = parts[1]
    func_name = parts[2]
    println("\n--- $k ---")
    # Try to find the actual function
    try
        mod = if mod_name == "JuliaLowering"
            JuliaLowering
        elseif mod_name == "JuliaSyntax"
            JuliaSyntax
        else
            nothing
        end
        if mod !== nothing
            f = getfield(mod, Symbol(func_name))
            println("  Found: $f ($(typeof(f)))")
            println("  Methods: $(length(methods(f)))")
        end
    catch e
        println("  ERROR: $e")
    end
end
