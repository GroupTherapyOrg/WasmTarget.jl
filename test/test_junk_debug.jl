using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "utils.jl"))

# Test: compile a function that does what parse_stmts does
# but returns the count of bumps in the junk loop
function test_junk_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    ps = JuliaSyntax.ParseState(stream)

    # parse_Nary (same as parse_stmts does)
    mark = JuliaSyntax.position(ps)
    do_emit = JuliaSyntax.parse_Nary(ps, JuliaSyntax.parse_public, (JuliaSyntax.K";",), (JuliaSyntax.K"NewlineWs",))

    # Count junk loop iterations
    count = Int32(0)
    while JuliaSyntax.peek(ps) ∉ JuliaSyntax.KSet"EndMarker NewlineWs"
        JuliaSyntax.bump(ps)
        count += Int32(1)
    end
    return count
end

# Native ground truth
println("Native: test_junk_count(\"1\") = ", test_junk_count("1"))
println("Native: test_junk_count(\"a\") = ", test_junk_count("a"))
println("Native: test_junk_count(\"1+1\") = ", test_junk_count("1+1"))

# Compile
println("\nCompiling test_junk_count...")
bytes = compile(test_junk_count, (String,))
println("Compiled: ", length(bytes), " bytes")

# Validate
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
v = run(`wasm-tools validate --features=gc $tmpf`)
println("VALIDATES: ", v)

# Count functions
nfunc = read(`wasm-tools print $tmpf`, String)
func_count = count("(func ", nfunc)
println("Functions: ", func_count)
