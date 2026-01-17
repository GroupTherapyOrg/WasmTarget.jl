#!/usr/bin/env julia
using WasmTarget

# Test global state access in cross-function calls
println("Testing global state with cross-function calls...")

# Define test functions that use the global output buffer
@noinline function test_write_hello()::Nothing
    WasmTarget.output_buffer_append!("Hello")
    return nothing
end

@noinline function test_write_world()::Nothing
    WasmTarget.output_buffer_append!(" World")
    return nothing
end

@noinline function test_write_both()::Nothing
    test_write_hello()
    test_write_world()
    return nothing
end

@noinline function test_get_result()::String
    return WasmTarget.output_buffer_get()
end

@noinline function test_clear_and_write()::String
    WasmTarget.output_buffer_clear!()
    test_write_hello()
    test_write_world()
    return WasmTarget.output_buffer_get()
end

# Get the function references
append_fn = getfield(WasmTarget, Symbol("output_buffer_append!"))
clear_fn = getfield(WasmTarget, Symbol("output_buffer_clear!"))
get_fn = WasmTarget.output_buffer_get

println("\nTesting Julia behavior first:")
WasmTarget.output_buffer_clear!()
test_write_both()
println("  test_write_both result: \"$(WasmTarget.output_buffer_get())\"")

result = test_clear_and_write()
println("  test_clear_and_write result: \"$result\"")

println("\nTesting compile_multi with cross-function calls:")
funcs = [
    (append_fn, (String,)),
    (clear_fn, ()),
    (get_fn, ()),
    (test_write_hello, ()),
    (test_write_world, ()),
    (test_write_both, ()),
    (test_get_result, ()),
    (test_clear_and_write, ()),
]

try
    wasm = WasmTarget.compile_multi(funcs)
    println("  Compiled $(length(funcs)) functions: $(length(wasm)) bytes ✓")
catch e
    println("  ERROR: $e")
    rethrow(e)
end

println("\nDone!")
