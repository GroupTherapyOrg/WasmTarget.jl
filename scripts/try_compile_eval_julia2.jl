# try_compile_eval_julia2.jl — Compile eval_julia_to_bytes, save wasm, analyze errors
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Compiling eval_julia_to_bytes(String) ===")
t0 = time()
bytes = WasmTarget.compile_multi([(eval_julia_to_bytes, (String,))])
elapsed = round(time() - t0, digits=1)
println("Compiled: $(length(bytes)) bytes in $(elapsed)s")

# Save to file
outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
mkpath(dirname(outf))
write(outf, bytes)
println("Saved to: $outf")

# Count functions
wat = read(`wasm-tools print $outf`, String)
n_funcs = count("(func ", wat)
println("Function count: $n_funcs")

# Validate
println("\n=== Validation ===")
try
    run(`wasm-tools validate $outf`)
    println("VALIDATES!")
catch e
    println("Validation failed — getting details...")
end

# Get func 5 name from WAT
println("\n=== Func 5 analysis ===")
lines = split(wat, "\n")
for (i, line) in enumerate(lines)
    if occursin("(func \$", line)
        # Extract function index and name
        m = match(r"\(func \$([^ ]+)", line)
        if m !== nothing
            println("  func: \$$(m[1]) at line $i")
        end
    end
    if i > 200  # Stop after first few functions
        break
    end
end
