# compile_eval_julia.jl — Compile eval_julia pipeline + diagnostics to WASM
#
# Uses eval_julia_to_bytes_vec(Vector{UInt8}) as primary seed (avoids
# String→Vector{UInt8} copyto_unaliased! stub from eval_julia_to_bytes(String)).
# Also includes diagnostic test functions and helpers.
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Result extraction helpers (defined here for WASM export)
function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

# Collect all eval_julia_test_* and helper functions
seed = Tuple{Any, Tuple}[
    (eval_julia_to_bytes_vec, (Vector{UInt8},)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
]
# Add all diagnostic test functions (take Vector{UInt8})
for name in names(Main; all=true)
    s = string(name)
    if startswith(s, "eval_julia_test_")
        fn = getfield(Main, name)
        if applicable(fn, UInt8[0x31, 0x2b, 0x31])
            push!(seed, (fn, (Vector{UInt8},)))
        end
    end
end

println("Compiling $(length(seed)) seed functions...")
t0 = time()
bytes = WasmTarget.compile_multi(seed)
elapsed = round(time() - t0, digits=1)
println("Compiled: $(length(bytes)) bytes in $(elapsed)s")

outf = joinpath(@__DIR__, "..", "output", "eval_julia.wasm")
mkpath(dirname(outf))
write(outf, bytes)
println("Saved to: $outf")
