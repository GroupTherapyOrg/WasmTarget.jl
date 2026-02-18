using WasmTarget, Core.Compiler

# Compile tmerge_types_slow and examine the WAT context around the problematic instruction
println("=== Compiling tmerge_types_slow ===")
bytes = compile(Core.Compiler.tmerge_types_slow, (Type, Type))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, "\n")

# Print 30 lines before and 5 after local.set 649
println("\n--- Context around local.set 649 (30 lines before, 5 after) ---")
for (i, line) in enumerate(lines)
    if occursin("local.set 649", line)
        for j in max(1, i-30):min(length(lines), i+5)
            marker = j == i ? ">>>" : "   "
            println("$marker [$j] $(lines[j])")
        end
    end
end

# Also check: what is local 632 used for? Print all its uses
println("\n--- All uses of local.get 632 ---")
for (i, line) in enumerate(lines)
    if occursin("local.get 632", line)
        println("  [$i] $(lines[i])")
        if i+1 <= length(lines)
            println("  [$(i+1)] $(lines[i+1])")
        end
    end
end

# And local.set 632
println("\n--- All local.set 632 ---")
for (i, line) in enumerate(lines)
    if occursin("local.set 632", line)
        println("  [$i] $(lines[i])")
        # Print a few lines before to see what's being stored
        for j in max(1, i-3):i-1
            println("  [$j] $(lines[j])")
        end
    end
end

# What type is local 649 and local 632?
# Parse func header
func_line = ""
for line in lines
    if occursin("(func (;1;)", line) || occursin("(func \$func_", line)
        func_line = line
        break
    end
end
if !isempty(func_line) && length(func_line) > 200
    println("\n--- Func header (first 200 chars) ---")
    println(func_line[1:min(200, length(func_line))])
    println("...")
end
