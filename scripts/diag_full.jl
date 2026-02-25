using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

func = WasmTarget.get_nullable_inner_type
arg_types = (Union,)
bytes = WasmTarget.compile_multi([(func, arg_types)])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Full dump with byte offsets
Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=stdout))
println("\n\n=== FULL WAT ===")
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=stdout))
rm(tmpf; force=true)
