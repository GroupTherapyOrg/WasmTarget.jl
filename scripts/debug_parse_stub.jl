#!/usr/bin/env julia
# PURE-324: Debug why #parse!#73 is stubbed
# Understanding: compile_invoke emits call for cross-func if target_info != nothing
# But #parse!#73 is stubbed, meaning get_function() returns nothing for it
# Why? Let's check what's in the func_registry

using WasmTarget
using JuliaSyntax

# The function that triggers the stub
function parse_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return Int32(1)
end

# Get the IR to see how parse! is invoked
ci = Base.code_typed(parse_test, (String,), optimize=true)[1][1]
println("=== IR for parse_test ===")
for (i, stmt) in enumerate(ci.code)
    if stmt isa Expr && stmt.head === :invoke
        mi_or_ci = stmt.args[1]
        func_ref = stmt.args[2]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end
        fname = if func_ref isa GlobalRef
            string(func_ref.name)
        elseif mi isa Core.MethodInstance && mi.def isa Method
            string(mi.def.name)
        else
            string(func_ref)
        end
        if contains(fname, "parse")
            println("  SSA $i: invoke $fname")
            println("    func_ref = $func_ref ($(typeof(func_ref)))")
            if mi !== nothing
                println("    mi.specTypes = $(mi.specTypes)")
                println("    mi.def.name = $(mi.def.name)")
            end
            println("    args = $(stmt.args[3:end])")
        end
    end
end

# Now let's look at how the method is registered
# The key question: what func object and arg_types does get_function need to match?
println("\n=== Method analysis ===")
m = methods(JuliaSyntax.parse!)
println("Methods of parse!: $(length(m))")
for method in m
    println("  $(method.sig)")
end

# Check the specific kwarg inner function
println("\n=== #parse!#73 info ===")
try
    # The inner method has a specific structure
    ci2 = Base.code_typed(JuliaSyntax.parse!, (JuliaSyntax.ParseStream,), optimize=true)[1][1]
    println("IR for parse!(::ParseStream):")
    for (i, stmt) in enumerate(ci2.code)
        println("  SSA $i: $stmt ($(typeof(stmt)))")
    end
catch e
    println("Could not get code_typed for parse!: $e")
end
