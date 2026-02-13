using WasmTarget
using JuliaSyntax

# Return byte_span of the last output node (useful to identify what it is)
function test_last_byte_span(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(stream.output[end].byte_span)
end

# Return byte_span of the 2nd-to-last output node
function test_penultimate_byte_span(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    if length(stream.output) >= 2
        return Int32(stream.output[end-1].byte_span)
    end
    return Int32(-1)
end

# Return node_span_or_orig_kind of last node
function test_last_orig_kind(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(stream.output[end].node_span_or_orig_kind)
end

println("=== Native Julia Ground Truth ===")
for s in ["1", "hello", "1+2"]
    lbs = test_last_byte_span(s)
    pbs = test_penultimate_byte_span(s)
    lok = test_last_orig_kind(s)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    oc = length(stream.output)
    println("\"$s\": last_byte_span=$lbs penultimate_byte_span=$pbs last_orig_kind=$lok output_count=$oc")
end

println("\n=== Compiling ===")
for (name, fn) in [
    ("test_last_byte_span", test_last_byte_span),
    ("test_penultimate_byte_span", test_penultimate_byte_span),
    ("test_last_orig_kind", test_last_orig_kind),
]
    print("$name: ")
    try
        bytes = WasmTarget.compile(fn, (String,))
        write("WasmTarget.jl/browser/$(name).wasm", bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        val = read(`wasm-tools validate $tmpf`, String)
        println("$(length(bytes)) bytes, validates=$(isempty(val) ? "YES" : val)")
    catch e
        println("ERROR: ", sprint(showerror, e)[1:min(200, end)])
    end
end
