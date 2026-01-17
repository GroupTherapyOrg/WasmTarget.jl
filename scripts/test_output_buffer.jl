#!/usr/bin/env julia
using WasmTarget

# Test output buffer compilation
println("Testing output buffer functions compilation...")

# Get the functions using Symbol
append_fn = getfield(WasmTarget, Symbol("output_buffer_append!"))
clear_fn = getfield(WasmTarget, Symbol("output_buffer_clear!"))
set_fn = getfield(WasmTarget, Symbol("output_buffer_set!"))
get_fn = WasmTarget.output_buffer_get

# Test individual compilation
println("\nTesting individual compilation:")
for (name, fn, args) in [
    ("output_buffer_get", get_fn, ()),
    ("output_buffer_append!", append_fn, (String,)),
    ("output_buffer_clear!", clear_fn, ()),
    ("output_buffer_set!", set_fn, (String,)),
]
    try
        wasm = WasmTarget.compile(fn, args)
        println("  $name: $(length(wasm)) bytes ✓")
    catch e
        println("  $name: ERROR - $e")
    end
end

# Test compile_multi with output buffer functions
println("\nTesting compile_multi with output buffer functions:")
funcs = [
    (get_fn, ()),
    (append_fn, (String,)),
    (clear_fn, ()),
    (set_fn, (String,)),
]

try
    wasm = WasmTarget.compile_multi(funcs)
    println("  All 4 functions: $(length(wasm)) bytes ✓")
catch e
    println("  ERROR: $e")
end

println("\nDone!")
