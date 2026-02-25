using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

fn = eval(Meta.parse("WasmTarget.register_tuple_type!"))
bytes = WasmTarget.compile_multi([(fn, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

watbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
wat = String(take!(watbuf))
lines = split(wat, "\n")

# Find type 72 definition
for line in lines
    if contains(line, "(type (;72;)")
        println("TYPE 72: ", line)
    end
end
println()

# Find global 0 definition
for line in lines
    if contains(line, "(global (;0;)")
        println("GLOBAL 0: ", line)
    end
end
println()

# Find struct.new 72 context
for (i, line) in enumerate(lines)
    if contains(line, "struct.new 72")
        s = max(1, i-8)
        e = min(length(lines), i+5)
        for j in s:e
            marker = j == i ? " <<<" : ""
            println(j, ": ", lines[j], marker)
        end
        println()
    end
end
rm(tmpf; force=true)
