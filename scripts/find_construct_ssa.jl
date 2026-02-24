using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

# Discover all functions
seed = [(eval_julia_to_bytes, (String,))]
all_funcs = WasmTarget.discover_dependencies(seed)

# Find construct_ssa!
for (f, at, name) in all_funcs
    if contains(name, "construct_ssa")
        println("Found: $name")
        println("  func: $f")
        println("  arg_types: $at")
    end
end
