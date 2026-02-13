using WasmTarget
using JuliaSyntax

# JuliaSyntax 2.0.0-DEV: ParseStream has `output` (Vector{RawGreenNode}) and `next_byte` (Int)

# Return number of output nodes after parse
function test_output_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(length(stream.output))
end

# Return stream.next_byte (direct field)
function test_stream_nb(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(stream.next_byte)
end

# Return stream.next_byte BEFORE parse (should be 1)
function test_stream_nb_before(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    return Int32(stream.next_byte)
end

println("=== Native Julia Ground Truth (JuliaSyntax $(pkgversion(JuliaSyntax))) ===")
for s in ["1", "hello", "1+2", "x = 1"]
    oc = test_output_count(s)
    nb = test_stream_nb(s)
    nb_before = test_stream_nb_before(s)
    println("\"$s\": output_count=$oc next_byte=$nb nb_before=$nb_before")

    # Also show the output details
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    for (i, o) in enumerate(stream.output)
        println("  [$i] $(o)")
    end
end

println("\n=== Compiling ===")

fns = [
    ("test_output_count", test_output_count),
    ("test_stream_nb", test_stream_nb),
    ("test_stream_nb_before", test_stream_nb_before),
]

for (name, fn) in fns
    println("\n$name:")
    try
        bytes = WasmTarget.compile(fn, (String,))
        write("WasmTarget.jl/browser/$(name).wasm", bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        val = read(`wasm-tools validate $tmpf`, String)
        println("  $(length(bytes)) bytes, validates=$(isempty(val) ? "YES" : val)")
    catch e
        println("  ERROR: ", sprint(showerror, e)[1:min(200, end)])
    end
end
