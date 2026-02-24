#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget, JuliaSyntax

# Directly test emit_unwrap_union_value
f = getfield(JuliaSyntax, Symbol("adjust_macro_name!"))
arg_types = (Union{Expr, Symbol},)

# Create a mini compilation context to test
mod = WasmTarget.WasmModule()
type_reg = WasmTarget.TypeRegistry()

# Check what julia_to_wasm_type_concrete returns for Symbol
wt_sym = WasmTarget.julia_to_wasm_type_concrete(Symbol, mod, type_reg)
println("Symbol wasm type: ", wt_sym, " isa ConcreteRef: ", wt_sym isa WasmTarget.ConcreteRef)

# Check what needs_tagged_union says for Union{AbstractString, Symbol}
union_type = Union{AbstractString, Symbol}
println("needs_tagged_union(Union{AbstractString,Symbol}): ", WasmTarget.needs_tagged_union(union_type))

# Check get_union_type!
union_info = WasmTarget.get_union_type!(mod, type_reg, union_type)
println("union_info: ", union_info)
println("union_info type_idx: ", union_info.wasm_type_idx)

# Now check the full emit_unwrap_union_value
# Need a compilation context...
# Let's check if the function handles the types correctly
wt_target = WasmTarget.julia_to_wasm_type_concrete(Symbol, mod, type_reg)
println("Target wasm type after context creation: ", wt_target)
println("Is ConcreteRef: ", wt_target isa WasmTarget.ConcreteRef)
if wt_target isa WasmTarget.ConcreteRef
    println("type_idx: ", wt_target.type_idx)
    println("nullable: ", wt_target.nullable)
end
