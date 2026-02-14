using WasmTarget
using JuliaSyntax

# Test if parse! causes Union{} return type
function test_with_parse(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return Int32(length(stream.output))
end

_, rt = only(Base.code_typed(test_with_parse, (String,); optimize=true))
println("with_parse rettype: $rt")

# Check the IR
ci, _ = only(Base.code_typed(test_with_parse, (String,); optimize=true))
for (i, stmt) in enumerate(ci.code)
    t = ci.ssavaluetypes[i]
    println("  $i: $stmt :: $t")
end
