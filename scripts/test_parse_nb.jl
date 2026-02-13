using WasmTarget
using JuliaSyntax

# Test function: parse! a string and return _next_byte (should be 2 for "1", 6 for "hello")
function test_parse_nb(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream; rule=:statement)
    return Int32(JuliaSyntax._next_byte(stream))
end

# Native Julia ground truth
println("=== Native Julia Ground Truth ===")
println("test_parse_nb(\"1\") = ", test_parse_nb("1"))
println("test_parse_nb(\"hello\") = ", test_parse_nb("hello"))
println("test_parse_nb(\"1+2\") = ", test_parse_nb("1+2"))

println("\n=== Compiling ===")
try
    bytes = WasmTarget.compile(test_parse_nb, (String,))
    println("Compiled: $(length(bytes)) bytes")

    # Count functions
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    nfuncs = Base.parse(Int, strip(read(`bash -c "wasm-tools print $tmpf | grep -c '(func'"`, String)))
    println("Functions: $nfuncs")

    val = read(`wasm-tools validate $tmpf`, String)
    println("Validates: ", isempty(val) ? "YES" : val)

    cp(tmpf, "WasmTarget.jl/browser/test_parse_nb.wasm"; force=true)
    println("Written to browser/test_parse_nb.wasm")
catch e
    println("ERROR: ", e)
    for line in split(sprint(showerror, e, catch_backtrace()), "\n")[1:min(10, end)]
        println("  ", line)
    end
end
