# Pre-compile WASM examples for the documentation live demos.
# Called from make.jl before makedocs().

using WasmTarget

const EXAMPLES_DIR = joinpath(@__DIR__, "src", "assets", "examples")
mkpath(EXAMPLES_DIR)

# -- Helper ------------------------------------------------------------------

function build_example(name::String, f, arg_types::Tuple)
    try
        bytes = compile(f, arg_types)
        path = joinpath(EXAMPLES_DIR, "$name.wasm")
        write(path, bytes)
        println("  Built $name.wasm ($(length(bytes)) bytes)")
    catch e
        @warn "Failed to compile $name" exception = e
    end
end

function build_multi_example(name::String, functions::Vector)
    try
        bytes = compile_multi(functions)
        path = joinpath(EXAMPLES_DIR, "$name.wasm")
        write(path, bytes)
        println("  Built $name.wasm ($(length(bytes)) bytes)")
    catch e
        @warn "Failed to compile $name" exception = e
    end
end

# -- Examples -----------------------------------------------------------------

println("Building WASM examples for docs...")

# Math functions
build_example("sin", sin, (Float64,))
build_example("cos", cos, (Float64,))
build_example("exp", exp, (Float64,))
build_example("log", log, (Float64,))
build_example("sqrt", sqrt, (Float64,))
build_example("abs", abs, (Float64,))

# Simple user functions
add_i32(a::Int32, b::Int32)::Int32 = a + b
build_example("add_i32", add_i32, (Int32, Int32))

mul_f64(a::Float64, b::Float64)::Float64 = a * b
build_example("mul_f64", mul_f64, (Float64, Float64))

function fibonacci(n::Int32)::Int32
    n <= Int32(1) && return n
    a = Int32(0)
    b = Int32(1)
    i = Int32(2)
    while i <= n
        c = a + b
        a = b
        b = c
        i += Int32(1)
    end
    return b
end
build_example("fibonacci", fibonacci, (Int32,))

# Multi-function example
function square(x::Float64)::Float64
    return x * x
end
function cube(x::Float64)::Float64
    return x * square(x)
end
build_multi_example("square_cube", [
    (square, (Float64,)),
    (cube, (Float64,)),
])

println("Done building WASM examples.")
