# typeinf_wasm.jl — Unified entry point for typeinf with Julia reimplementations
#
# This file loads all typeinf components in the correct order:
#   1. ccall_stubs.jl — Phase A: SKIP stubs for timing/debug ccalls
#   2. subtype.jl — Phase 2d: wasm_subtype + wasm_type_intersection
#   3. matching.jl — Phase 2d: wasm_matching_methods (depends on subtype.jl)
#   4. dict_method_table.jl — DictMethodTable, WasmInterpreter, overrides
#   5. ccall_replacements.jl — Phase B-D: remaining ccall replacements
#
# After loading, set _WASM_USE_REIMPL[] = true to use Julia reimplementations
# instead of pre-computed Dict lookups for type intersection and method matching.
#
# Usage:
#   julia +1.12 --project=. -e '
#     include("src/typeinf/typeinf_wasm.jl")
#     println("Typeinf with reimplementations loaded OK")'

# Load Phase A stubs first (SKIP list for timing/debug ccalls)
include(joinpath(@__DIR__, "ccall_stubs.jl"))

# Load Phase 2d reimplementations (subtype → intersection → matching)
include(joinpath(@__DIR__, "subtype.jl"))
include(joinpath(@__DIR__, "matching.jl"))

# Load DictMethodTable + overrides (uses wasm_type_intersection/wasm_matching_methods
# when _WASM_USE_REIMPL is true)
include(joinpath(@__DIR__, "dict_method_table.jl"))

# Load Phase B-D ccall replacements
include(joinpath(@__DIR__, "ccall_replacements.jl"))

println("typeinf_wasm.jl loaded — reimplementation mode available")
println("  Set _WASM_USE_REIMPL[] = true to use Julia reimplementations")
println("  wasm_subtype: ", @isdefined(wasm_subtype) ? "loaded" : "MISSING")
println("  wasm_type_intersection: ", @isdefined(wasm_type_intersection) ? "loaded" : "MISSING")
println("  wasm_matching_methods: ", @isdefined(wasm_matching_methods) ? "loaded" : "MISSING")
