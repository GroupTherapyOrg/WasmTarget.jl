using WasmTarget, JuliaSyntax

# The actual SourceFile#8 function signature:
# (filename, first_line, first_index, ::Type{SourceFile}, code::AbstractString)
# But we can't compile it directly with AbstractString — we need a concrete type.
# The actual call uses SubString{String}.

# Test: compile SourceFile(::SubString{String}) constructor
function test_sf_ss(s::String)
    ss = SubString(s, 1, ncodeunits(s))
    sf = SourceFile(ss)
    return Int32(sf.first_line)
end

println("Compiling test_sf_ss...")
bytes = compile(test_sf_ss, (String,))
println("Compiled: $(length(bytes)) bytes")
f = tempname() * ".wasm"
write(f, bytes)
run(`wasm-tools validate --features=gc $f`)
println("VALIDATES")

write("WasmTarget.jl/browser/test_sf_ss.wasm", bytes)
println("Written to browser/test_sf_ss.wasm")
