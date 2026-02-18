#!/usr/bin/env julia
# Debug: Add instrumentation to trace egal handler
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

test_egal_return() = begin
    x = wasm_type_intersection(Int64, Number)
    return Int32(x === Int64)
end

# Check what code_typed gives us
ir = code_typed(test_egal_return, ())[1][1]
for (i, stmt) in enumerate(ir.code)
    typ = ir.ssavaluetypes[i]
    println("  %$i = $stmt :: $typ")
end

# Check what Wasm types are assigned
println("\n--- Wasm type analysis ---")
T1 = Union{Type{Int64}, Type{Number}, Type{Union{}}}
T2 = Type{Int64}
println("arg1 type: $T1")
println("  is_ref_type_or_union: $(WasmTarget.is_ref_type_or_union(T1))")
println("  julia_to_wasm_type: $(WasmTarget.julia_to_wasm_type(T1))")
println("arg2 type: $T2")
println("  is_ref_type_or_union: $(WasmTarget.is_ref_type_or_union(T2))")
println("  julia_to_wasm_type: $(WasmTarget.julia_to_wasm_type(T2))")

# Now try a simpler approach: avoid the === problem by modifying the test
# What if we use _subtype_check instead?
println("\n--- Alternative approaches ---")
println("_subtype_check(Int64, Int64) = $(_subtype_check(Int64, Int64))")
println("_subtype_check(Int64, Number) = $(_subtype_check(Int64, Number))")
