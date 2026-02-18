using WasmTarget, Core.Compiler

# Compile tmerge_types_slow standalone and look at the WAT more carefully
println("=== Compiling tmerge_types_slow ===")
bytes = compile(Core.Compiler.tmerge_types_slow, (Type, Type))
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Validate
println("\n--- Validating ---")
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("VALIDATES OK!")
catch e
    println("Validation failed: $e")
end

# Get WAT and find the problematic local.get 632 → local.set 649
println("\n--- Searching for local.get 632 → local.set 649 pattern ---")
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, "\n")

for (i, line) in enumerate(lines)
    # Look for local.set 649
    if occursin("local.set 649", line) || occursin("local.set \$l649", line)
        println("Line $i: $line")
        # Print context around it
        for j in max(1, i-10):min(length(lines), i+3)
            println("  [$j] $(lines[j])")
        end
        println()
    end
end

# Also look for the func header and params/locals count
println("\n--- Func 1 header ---")
for (i, line) in enumerate(lines)
    if occursin("(func ", line) && i < 10
        println("Line $i: $line")
    end
end

# Count how many "local.get 632" there are
count632 = count(l -> occursin("local.get 632", l) || occursin("local.get \$l632", l), lines)
count649 = count(l -> occursin("local.set 649", l) || occursin("local.set \$l649", l), lines)
println("\nlocal.get 632 count: $count632")
println("local.set 649 count: $count649")
