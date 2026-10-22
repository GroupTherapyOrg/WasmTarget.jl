# WasmTarget: a Julia → WebAssembly (WasmGC) compiler rebuilt from dart2wasm's structure
# (dev/MARCH.md Phase 1). src/ mirrors pkg/dart2wasm/lib and pkg/wasm_builder/lib/src at the commit
# dev/PARITY_MASTER.md pins, file for file, each file loaded by include_dart and each definition
# carrying @parity; src/julia/ holds what Julia forces and dart lacks, each definition carrying
# @quarantine (src/julia/parity.jl). This file defines nothing. Until a dart definition is ported,
# the path through it is a located rejection, never a value.
module WasmTarget

include("julia/parity.jl")
include("julia/construction.jl")
include("julia/reject.jl")
include("julia/subset.jl")
include("julia/nir.jl")
include("julia/entry.jl")

# The load-time checks that need every definition to exist, so the package does not load otherwise:
# the file map, the anchors and the quarantine (src/julia/parity.jl), then no abstract type that is
# neither a registered construction nor a dart abstract class's mirror (A33S1).
construction_check(Val(:include_dart))
construction_check(Val(:parity))
construction_check(Val(:quarantine))
construction_check(Val(:check_no_open_abstract))
construction_check(Val(:ClosedWorld))
construction_check(Val(:NirValue))
construction_check(Val(:NirStmt))

end # module
