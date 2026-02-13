#!/usr/bin/env julia
# PURE-324: Final debug — trace exactly why get_function fails for #parse!#73
using WasmTarget
using JuliaSyntax

# Simulate the full flow
function parse_test(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream, rule=:statement)
    return Int32(1)
end

# Step 1: Run discover_dependencies to get the function list
funcs = [(parse_test, (String,))]
function_data = WasmTarget.discover_dependencies(funcs)

println("=== Discovered functions: $(length(function_data)) ===")

# Find #parse!#73 in the list
parse73_entries = filter(function_data) do entry
    f, at, name = entry
    contains(name, "parse!") || contains(name, "#parse")
end
println("\nparse!-related entries:")
for (f, at, name) in parse73_entries
    println("  name=$name")
    println("    f = $f ($(typeof(f)))")
    println("    arg_types = $at")
    println("    objectid(f) = $(objectid(f))")
end

# Step 2: Simulate what compile_invoke does
# The call site uses GlobalRef JuliaSyntax.:(var"#parse!#73")
println("\n=== Simulating compile_invoke lookup ===")
called_func = getfield(JuliaSyntax, Symbol("#parse!#73"))
println("called_func from GlobalRef = $called_func ($(typeof(called_func)))")
println("objectid(called_func) = $(objectid(called_func))")

# Check identity with the discovered function
for (f, at, name) in parse73_entries
    if contains(name, "#parse!#73") || contains(string(typeof(f)), "#parse!#73")
        println("\nComparing with discovered entry '$name':")
        println("  f === called_func? $(f === called_func)")
        println("  objectid(f) == objectid(called_func)? $(objectid(f) == objectid(called_func))")
        println("  typeof(f) == typeof(called_func)? $(typeof(f) == typeof(called_func))")
    end
end

# Step 3: Check what name discover_dependencies uses
println("\n=== Name mapping ===")
# In discover_dependencies, name = string(meth_name) where meth_name = meth.name
# For #parse!#73, meth.name = Symbol("#parse!#73")
# BUT the GlobalRef in compile_invoke might use a different name format

# Check the actual method
m = methods(JuliaSyntax.parse!, (JuliaSyntax.ParseStream,))
println("parse! methods: $m")
ci = Base.code_typed(JuliaSyntax.parse!, (JuliaSyntax.ParseStream,), optimize=true)[1][1]
println("\nIR for parse!(::ParseStream):")
for (i, stmt) in enumerate(ci.code)
    if stmt isa Expr && stmt.head === :invoke
        mi_or_ci = stmt.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end
        func_ref = stmt.args[2]
        println("  SSA $i: invoke")
        println("    func_ref = $func_ref ($(typeof(func_ref)))")
        if mi !== nothing
            println("    mi.def.name = $(mi.def.name)")
            println("    mi.specTypes = $(mi.specTypes)")
            sig = mi.specTypes
            if sig isa DataType && sig <: Tuple
                func_type = sig.parameters[1]
                println("    func_type = $func_type")
                if func_type isa DataType && func_type <: Function
                    inner_func = getfield(mi.def.module, mi.def.name)
                    println("    inner_func = $inner_func ($(typeof(inner_func)))")
                    println("    inner_func === called_func? $(inner_func === called_func)")
                end
            end
        end
    end
end

# Step 4: Check by-ref dictionary structure
println("\n=== Building func registry manually ===")
# Create a simple dict to simulate by_ref
by_ref = Dict{Any, Vector}()
for (f, at, name) in function_data
    if !haskey(by_ref, f)
        by_ref[f] = []
    end
    push!(by_ref[f], (name, at))
end

println("Total entries in by_ref: $(length(by_ref))")
println("called_func in by_ref keys? $(haskey(by_ref, called_func))")

if haskey(by_ref, called_func)
    println("Matching entries:")
    for (name, at) in by_ref[called_func]
        println("  $name: $at")
    end
else
    println("NOT FOUND! Trying to find closest match...")
    # Check all keys for type match
    for (k, entries) in by_ref
        if typeof(k) == typeof(called_func)
            println("  Same type but different identity: $k")
            println("    objectid(k) = $(objectid(k)), objectid(called_func) = $(objectid(called_func))")
            for (name, at) in entries
                println("    $name: $at")
            end
        end
    end
end
