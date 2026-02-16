using WasmTarget, Core.Compiler

# Compile tmerge_3 (ConditionalsLattice variant) directly
# This is func 11 in record_slot_assign module

# First, let's see which tmerge variant is tmerge_3
# Looking at the exports: tmerge_3 = tmerge with ConditionalsLattice

println("Checking if tmerge with ConditionalsLattice compiles and validates on its own...")
bytes = compile(Core.Compiler.tmerge, (Core.Compiler.ConditionalsLattice, Any, Any))
f = tempname() * ".wasm"
write(f, bytes)
println("Compiled: $(length(bytes)) bytes to $f")
result = read(pipeline(`wasm-tools validate --features=gc $f`, stderr=stdout), String)
if isempty(result)
    println("VALIDATES")
else
    lines = split(strip(result), "\n")
    for l in lines[1:min(5, length(lines))]
        println(l)
    end
end
