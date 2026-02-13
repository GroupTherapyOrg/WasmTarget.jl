using WasmTarget
using JuliaSyntax

function test_output_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(length(stream.output))
end

println("=== Discovering dependencies ===")

# Use the internal discover_dependencies function
entry = [(test_output_count, (String,), "test_output_count")]
deps = WasmTarget.discover_dependencies(entry)
println("Total functions: $(length(deps))")

# Print function names with indices (func_0 is the import Math.pow)
# So func_1 = first real function
for (i, dep) in enumerate(deps)
    f, arg_types, name = dep
    println("  func_$i: $name — $arg_types")
end
