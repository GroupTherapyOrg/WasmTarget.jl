#!/usr/bin/env julia
# Debug float_to_string local type mismatch

using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using WasmTarget: compile_multi, get_string_array_type!, ConcreteRef, I32

# Test just float_to_string to isolate the issue
println("Testing float_to_string compilation...")

test_funcs = [
    (WasmTarget.digit_to_str, (Int32,)),
    (WasmTarget.int_to_string, (Int32,)),
    (WasmTarget.float_to_string, (Float32,)),
]

try
    wasm = compile_multi(test_funcs)
    println("Compilation succeeded: $(length(wasm)) bytes")

    # Write to temp file
    write("/tmp/test_float.wasm", wasm)
    println("Wrote to /tmp/test_float.wasm")

    # Run wasm-tools validate
    result = run(pipeline(`wasm-tools validate /tmp/test_float.wasm`, stderr=stderr, stdout=stdout), wait=false)
    wait(result)
    if result.exitcode == 0
        println("WASM validation: PASSED")
    else
        println("WASM validation: FAILED")
    end
catch e
    println("Compilation failed: $e")
    rethrow(e)
end
