using WasmTarget

# SourceFile-like pattern: iterate string, build line_starts vector
function find_newlines(s::String)
    ss = SubString(s, 1, ncodeunits(s))
    line_starts = Int[1]
    for i in eachindex(ss)
        ss[i] == '\n' && push!(line_starts, i + 1)
    end
    return Int32(length(line_starts))
end

bytes = compile(find_newlines, (String,))
println("find_newlines compiled: $(length(bytes)) bytes")
f = tempname() * ".wasm"
write(f, bytes)
run(`wasm-tools validate --features=gc $f`)
println("VALIDATES")

write("WasmTarget.jl/browser/test_find_newlines.wasm", bytes)
println("Written to browser/test_find_newlines.wasm")
