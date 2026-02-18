#!/usr/bin/env julia
# Debug script v2: Compile eval_julia_to_bytes to WASM, get exact validation error,
# then extract and analyze the failing function

using WasmTarget
using JuliaSyntax

println("=" ^ 80)
println("PURE-6005: Debug — Compile eval_julia, analyze validation error")
println("=" ^ 80)

# Include eval_julia
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# ═══════════════════════════════════════════════════════════════════════════
# Compile eval_julia_to_bytes to WASM
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Compiling eval_julia_to_bytes ---")
bytes = compile_multi([(eval_julia_to_bytes, (String,))])
println("  compile_multi SUCCESS: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get function/export counts via wasm-tools dump
println("  (skipping function count to save time)")

# Validate and capture error
println("\n--- Validation ---")
valerr = try
    readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`)
catch
    ""
end
if isempty(valerr)
    println("  VALIDATES ✓ — Bug is no longer reproducible!")
    rm(tmpf, force=true)
    exit(0)
end
println("  Validation error: $valerr")

# ═══════════════════════════════════════════════════════════════════════════
# Dump WAT and find the failing function
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Extracting failing function from WAT ---")
wat_file = tempname() * ".wat"
run(`wasm-tools print $tmpf -o $wat_file`)

# Parse error to find function index
# Expected format: "func 17 failed to validate" or "func[17]"
m = match(r"func[\s\[]+(\d+)", valerr)
if m === nothing
    println("  Could not parse function index from error: $valerr")
    println("  WAT at: $wat_file")
    rm(tmpf, force=true)
    exit(1)
end
failing_idx = parse(Int, m.captures[1])
println("  Failing function index: $failing_idx")

# Read WAT and extract the failing function
wat_text = read(wat_file, String)
lines = split(wat_text, "\n")

# Find the Nth function (0-indexed)
func_count = -1  # Start at -1 so first func found is 0
func_start = 0
func_end = 0
depth = 0
in_func = false

for (line_num, line) in enumerate(lines)
    if !in_func && occursin(r"^\s+\(func ", line)
        func_count += 1
        if func_count == failing_idx
            func_start = line_num
            in_func = true
            depth = count("(", line) - count(")", line)
        end
    elseif in_func
        depth += count("(", line) - count(")", line)
        if depth <= 0
            func_end = line_num
            break
        end
    end
end

if func_start > 0 && func_end > 0
    println("  Function spans lines $func_start-$func_end ($(func_end - func_start + 1) lines)")
    func_text = join(lines[func_start:func_end], "\n")

    # Save to file
    func_file = tempname() * "_func$(failing_idx).wat"
    write(func_file, func_text)
    println("  Function WAT saved to: $func_file")

    # Print the function (truncated if very long)
    func_lines = lines[func_start:func_end]
    if length(func_lines) > 100
        println("\n  First 50 lines:")
        for l in func_lines[1:50]
            println("  $l")
        end
        println("  ... ($(length(func_lines) - 100) lines omitted) ...")
        println("  Last 50 lines:")
        for l in func_lines[end-49:end]
            println("  $l")
        end
    else
        println("\n  Full function:")
        for l in func_lines
            println("  $l")
        end
    end

    # Look for the specific pattern: values on stack at end of block
    # Count block/end/loop structure
    block_depth = 0
    max_depth = 0
    for l in func_lines
        stripped = strip(l)
        if startswith(stripped, "block") || startswith(stripped, "loop") || startswith(stripped, "if")
            block_depth += 1
            max_depth = max(max_depth, block_depth)
        elseif stripped == "end"
            block_depth -= 1
        end
    end
    println("\n  Max block nesting: $max_depth")
    println("  Final block depth: $block_depth (should be 0)")
else
    println("  Could not find function $failing_idx in WAT")
end

# ═══════════════════════════════════════════════════════════════════════════
# Also compile parse-only and extract the same-named function for comparison
# ═══════════════════════════════════════════════════════════════════════════
println("\n--- Compiling parse-only for comparison ---")
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)
bytes_parse = compile_multi([(parse_expr_string, (String,))])
tmpf_parse = tempname() * ".wasm"
write(tmpf_parse, bytes_parse)

# Validate parse-only
valerr_parse = try
    readchomp(`bash -c "wasm-tools validate --features=gc $tmpf_parse 2>&1 || true"`)
catch; "" end
if isempty(valerr_parse)
    println("  Parse-only VALIDATES ✓")
else
    println("  Parse-only validation error: $valerr_parse")
end

rm(tmpf, force=true)
rm(tmpf_parse, force=true)
println("\nWAT file: $wat_file")
println("=" ^ 80)
