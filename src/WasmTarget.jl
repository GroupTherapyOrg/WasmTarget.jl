# WasmTarget: a Julia → WebAssembly (WasmGC) compiler rebuilt from dart2wasm's structure
# (dev/MARCH.md Phase 1). src/ mirrors pkg/dart2wasm/lib and pkg/wasm_builder/lib/src at the commit
# dev/PARITY_MASTER.md pins, file for file; src/julia/ holds what Julia forces and dart lacks, each
# definition naming its Julia necessity. Until a dart definition is ported, the path through it is a
# located rejection, never a value.
module WasmTarget

include("julia/construction.jl")
include("julia/reject.jl")
include("julia/entry.jl")

# Every abstract type defined above is a registered construction or a dart abstract class's mirror
# (A33S1); checked last, when every definition exists, so the package does not load otherwise.
construction_check(::Val{:check_no_open_abstract})::Int = check_no_open_abstract(@__MODULE__)
construction_check(Val(:check_no_open_abstract))

end # module
