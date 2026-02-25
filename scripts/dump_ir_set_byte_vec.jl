using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== set_byte_vec! IR (optimize=false) ===")
ci = Base.code_typed(set_byte_vec!, (Vector{UInt8}, Int32, Int32); optimize=false)[1][1]
for (i, stmt) in enumerate(ci.code)
    println("  $i: $(repr(stmt))  :: $(ci.ssavaluetypes[i])")
end

println("\n=== set_byte_vec! IR (optimize=true) ===")
ci2 = Base.code_typed(set_byte_vec!, (Vector{UInt8}, Int32, Int32))[1][1]
for (i, stmt) in enumerate(ci2.code)
    println("  $i: $(repr(stmt))  :: $(ci2.ssavaluetypes[i])")
end
