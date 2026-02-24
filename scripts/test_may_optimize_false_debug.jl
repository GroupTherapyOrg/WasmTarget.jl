# Debug: examine WASM output from may_optimize=false (PURE-6024)
using JuliaSyntax
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

println("=== Generating WASM for 1+1 with may_optimize=false ===")
wasm_bytes = Base.invokelatest(eval_julia_to_bytes, "1+1")
println("WASM bytes: $(length(wasm_bytes)) bytes")

# Save for inspection
tmpwasm = "/tmp/test_add_unopt.wasm"
write(tmpwasm, wasm_bytes)
println("Saved to $tmpwasm")

# Validate
validate_result = read(`wasm-tools validate $tmpwasm`, String)
println("Validation: PASS")

# Print WAT
wat = read(`wasm-tools print $tmpwasm`, String)
println("=== WAT ===")
println(wat)

# Also dump the CodeInfo for comparison
world = Base.get_world_counter()
sig = Tuple{typeof(Base.:+), Int64, Int64}
interp = build_wasm_interpreter([sig]; world=world)
native_mt = Core.Compiler.InternalMethodTable(world)
lkup = Core.Compiler.findall(sig, native_mt; limit=3)
mi = Core.Compiler.specialize_method(first(lkup.matches))

_WASM_USE_REIMPL[] = true
_WASM_CODE_CACHE[] = interp.code_info_cache
local inf_frame
try
    inf_frame = Core.Compiler.typeinf_frame(interp, mi, false)
finally
    _WASM_USE_REIMPL[] = false
    _WASM_CODE_CACHE[] = nothing
end

ci = inf_frame.result.src
println("\n=== CodeInfo ===")
println(ci)
println("\n=== Statement details ===")
for (i, stmt) in enumerate(ci.code)
    println("  %$i = $(repr(stmt))")
    println("       type=$(ci.ssavaluetypes[i])")
end
