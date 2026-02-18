#!/usr/bin/env julia
# Debug script: Compare WAT for failing function between parse-only and full modules
#
# Goal: Find EXACTLY what changes when more types are registered,
# causing "values remaining on stack at end of block" in validate_tokens/release_positions

using WasmTarget
using JuliaSyntax

println("=" ^ 80)
println("PURE-6005: Debug validation error — WAT comparison")
println("=" ^ 80)

# ═══════════════════════════════════════════════════════════════════════════
# Module A: Parse-only (VALIDATES)
# ═══════════════════════════════════════════════════════════════════════════
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

println("\n--- Module A: Parse-only ---")
bytes_a = compile_multi([(parse_expr_string, (String,))])
println("  compile_multi SUCCESS: $(length(bytes_a)) bytes")

tmpf_a = tempname() * "_parse_only.wasm"
write(tmpf_a, bytes_a)

# Validate
try
    run(`wasm-tools validate --features=gc $tmpf_a`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf_a 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 400))")
end

# Dump WAT
wat_a = tempname() * "_parse_only.wat"
run(`wasm-tools print $tmpf_a -o $wat_a`)
println("  WAT dumped to: $wat_a")

# Count functions
nfuncs_a = try
    out = read(pipeline(`wasm-tools print $tmpf_a`, `grep -c "(func "`), String)
    parse(Int, strip(out))
catch; -1 end
println("  Functions: $nfuncs_a")

# ═══════════════════════════════════════════════════════════════════════════
# Module B: Parse + code_typed stub (FAILS)
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Module B: Parse + code_typed stub ---")

# A simple function that uses code_typed — even a stub changes type registrations
function code_typed_stub(x::Int64)::Int64
    return x + 1
end

bytes_b = compile_multi([
    (parse_expr_string, (String,)),
    (code_typed_stub, (Int64,)),
])
println("  compile_multi SUCCESS: $(length(bytes_b)) bytes")

tmpf_b = tempname() * "_parse_plus_stub.wasm"
write(tmpf_b, bytes_b)

# Validate
try
    run(`wasm-tools validate --features=gc $tmpf_b`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf_b 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 400))")
end

# Dump WAT
wat_b = tempname() * "_parse_plus_stub.wat"
run(`wasm-tools print $tmpf_b -o $wat_b`)
println("  WAT dumped to: $wat_b")

nfuncs_b = try
    out = read(pipeline(`wasm-tools print $tmpf_b`, `grep -c "(func "`), String)
    parse(Int, strip(out))
catch; -1 end
println("  Functions: $nfuncs_b")

# ═══════════════════════════════════════════════════════════════════════════
# Analysis: Find the failing function and compare
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Analysis ---")

# Read both WAT files
wat_a_text = read(wat_a, String)
wat_b_text = read(wat_b, String)

# Extract function names from WAT (look for (func $name patterns)
func_names_a = [m.match for m in eachmatch(r"\(func \$[^\s\)]+", wat_a_text)]
func_names_b = [m.match for m in eachmatch(r"\(func \$[^\s\)]+", wat_b_text)]
println("  Module A functions: $(length(func_names_a))")
println("  Module B functions: $(length(func_names_b))")

# Find functions in B that aren't in A
new_funcs = setdiff(Set(func_names_b), Set(func_names_a))
println("  New functions in B: $(length(new_funcs))")
for f in new_funcs
    println("    $f")
end

# Now let's look at which functions changed
# Extract each function body for comparison
function extract_functions(wat_text)
    funcs = Dict{String, String}()
    # Split by function boundaries
    # Each function starts with (func $ and ends at the matching closing paren
    lines = split(wat_text, "\n")
    current_func = nothing
    current_lines = String[]
    depth = 0

    for line in lines
        if current_func === nothing
            m = match(r"\(func (\$[^\s\)]+)", line)
            if m !== nothing
                current_func = m.captures[1]
                current_lines = [line]
                depth = count("(", line) - count(")", line)
            end
        else
            push!(current_lines, line)
            depth += count("(", line) - count(")", line)
            if depth <= 0
                funcs[current_func] = join(current_lines, "\n")
                current_func = nothing
                current_lines = String[]
                depth = 0
            end
        end
    end

    return funcs
end

funcs_a = extract_functions(wat_a_text)
funcs_b = extract_functions(wat_b_text)

println("\n  Functions that CHANGED between A and B:")
changed_count = 0
for name in sort(collect(keys(funcs_a)))
    if haskey(funcs_b, name) && funcs_a[name] != funcs_b[name]
        changed_count += 1
        body_a = funcs_a[name]
        body_b = funcs_b[name]
        lines_a = split(body_a, "\n")
        lines_b = split(body_b, "\n")

        # Find first difference
        first_diff = 0
        for j in 1:min(length(lines_a), length(lines_b))
            if lines_a[j] != lines_b[j]
                first_diff = j
                break
            end
        end

        println("\n    $name ($(length(lines_a)) vs $(length(lines_b)) lines, first diff at line $first_diff)")

        # Show a few lines around the first difference
        if first_diff > 0
            start = max(1, first_diff - 2)
            stop_a = min(length(lines_a), first_diff + 5)
            stop_b = min(length(lines_b), first_diff + 5)
            println("      Module A (lines $start-$stop_a):")
            for j in start:stop_a
                println("        $(lines_a[j])")
            end
            println("      Module B (lines $start-$stop_b):")
            for j in start:stop_b
                println("        $(lines_b[j])")
            end
        end
    end
end
println("\n  Total changed functions: $changed_count")

# Look specifically for validate_tokens and release_positions
for target in ["\$validate_tokens", "\$release_positions"]
    if haskey(funcs_a, target) && haskey(funcs_b, target)
        println("\n  DETAILED DIFF for $target:")
        lines_a = split(funcs_a[target], "\n")
        lines_b = split(funcs_b[target], "\n")

        # Write individual function WATs for detailed comparison
        func_wat_a = tempname() * "_$(replace(target, "\$" => ""))_a.wat"
        func_wat_b = tempname() * "_$(replace(target, "\$" => ""))_b.wat"
        write(func_wat_a, funcs_a[target])
        write(func_wat_b, funcs_b[target])
        println("    Module A: $func_wat_a")
        println("    Module B: $func_wat_b")

        # Count differences
        ndiffs = 0
        for j in 1:min(length(lines_a), length(lines_b))
            if lines_a[j] != lines_b[j]
                ndiffs += 1
            end
        end
        ndiffs += abs(length(lines_a) - length(lines_b))
        println("    Total differing lines: $ndiffs")
    elseif haskey(funcs_a, target)
        println("\n  $target exists in A but NOT in B")
    elseif haskey(funcs_b, target)
        println("\n  $target exists in B but NOT in A")
    end
end

# Cleanup
rm(tmpf_a, force=true)
rm(tmpf_b, force=true)

println("\n" * "=" ^ 80)
println("ANALYSIS COMPLETE — check the diff output above")
println("WAT files preserved at:")
println("  Module A: $wat_a")
println("  Module B: $wat_b")
println("=" ^ 80)
