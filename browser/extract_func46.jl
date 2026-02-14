#!/usr/bin/env julia
# Extract func 46 from WAT to identify the validation error

f = joinpath(@__DIR__, "parsestmt_new.wasm")
println("Converting to WAT...")
wat = read(`wasm-tools print $f`, String)
println("WAT: $(sizeof(wat)) bytes")

# Find func (;46;)
target = "(func (;46;)"
idx = findfirst(target, wat)
if isnothing(idx)
    println("func 46 not found!")
    exit(1)
end

# Extract a large chunk - func 46 could be thousands of lines
snippet_start = first(idx)
# Find the next func to know where 46 ends
next_func = findfirst("(func (;47;)", wat[snippet_start+100:end])
if !isnothing(next_func)
    snippet_end = snippet_start + 100 + first(next_func) - 2
else
    snippet_end = min(snippet_start + 50000, length(wat))
end

snippet = wat[snippet_start:snippet_end]
lines = split(snippet, '\n')
println("func 46: $(length(lines)) lines")

# Write to file for inspection
watf = joinpath(@__DIR__, "func46.wat")
write(watf, snippet)
println("Written to $watf")

# Search for struct_new patterns that might be the error
for (i, line) in enumerate(lines)
    if occursin("struct.new", line)
        # Print context around it
        start_ctx = max(1, i-3)
        end_ctx = min(length(lines), i+2)
        println("\n--- struct.new at line $i ---")
        for j in start_ctx:end_ctx
            marker = j == i ? ">>>" : "   "
            println("$marker $j: $(lines[j])")
        end
    end
end
