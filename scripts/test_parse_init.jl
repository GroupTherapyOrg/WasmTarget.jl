using WasmTarget
using JuliaSyntax

# Test 1: output length BEFORE parse (should be 1 — just the TOMBSTONE sentinel)
function test_output_before(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    return Int32(length(stream.output))
end

# Test 2: output length AFTER parse with rule=:statement
function test_output_after(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(length(stream.output))
end

# Test 3: output length AFTER parse with rule=:all
function test_output_after_all(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:all)
    return Int32(length(stream.output))
end

println("=== Native Julia Ground Truth ===")
for s in ["1", "hello", "1+2"]
    println("\"$s\": before=$(test_output_before(s)) after_stmt=$(test_output_after(s)) after_all=$(test_output_after_all(s))")
end

println("\n=== Compiling ===")
for (name, fn) in [("test_output_before", test_output_before),
                    ("test_output_after", test_output_after),
                    ("test_output_after_all", test_output_after_all)]
    println("\n$name:")
    try
        bytes = WasmTarget.compile(fn, (String,))
        write("WasmTarget.jl/browser/$(name).wasm", bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        val = read(`wasm-tools validate $tmpf`, String)
        nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
        println("  $(length(bytes)) bytes, $nfuncs funcs, validates=$(isempty(val) ? "YES" : val)")
    catch e
        println("  ERROR: ", sprint(showerror, e)[1:min(300, end)])
    end
end
