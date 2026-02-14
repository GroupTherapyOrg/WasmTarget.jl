using WasmTarget, JuliaSyntax

function diag_output_len(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return Int32(length(stream.output))
end

# Check return type
ci, rt = get_typed_ir(diag_output_len, (String,))
println("get_typed_ir return_type: ", rt)
