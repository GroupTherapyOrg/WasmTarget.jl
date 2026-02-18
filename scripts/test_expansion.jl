#!/usr/bin/env julia
# PURE-4165: Test expression expansion functions
# Tests all new pipeline functions individually

using WasmTarget

# Math functions
pipeline_sin(x::Float64)::Float64 = sin(x)
pipeline_cos(x::Float64)::Float64 = cos(x)
pipeline_sqrt(x::Float64)::Float64 = sqrt(x)
pipeline_exp(x::Float64)::Float64 = exp(x)
pipeline_log(x::Float64)::Float64 = log(x)

# Test math functions compile individually
println("=== Testing math functions ===")

math_funcs = [
    ("pipeline_sin", pipeline_sin, (Float64,)),
    ("pipeline_cos", pipeline_cos, (Float64,)),
    ("pipeline_sqrt", pipeline_sqrt, (Float64,)),
    ("pipeline_exp", pipeline_exp, (Float64,)),
    ("pipeline_log", pipeline_log, (Float64,)),
]

for (name, f, argtypes) in math_funcs
    print("  $name → ")
    try
        bytes = compile_multi([(f, argtypes)])
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        try
            run(`wasm-tools validate --features=gc $tmpf`)
            println("VALIDATES ($(length(bytes)) bytes)")
        catch
            println("VALIDATE_ERROR")
        end
        rm(tmpf, force=true)
    catch e
        println("COMPILE_ERROR: $(first(sprint(showerror, e), 100))")
    end
end

# Test sin + cos together
println("\n=== Testing sin+cos together ===")
bytes = compile_multi([(pipeline_sin, (Float64,)), (pipeline_cos, (Float64,))])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  sin+cos VALIDATES ($(length(bytes)) bytes)")
catch
    println("  sin+cos VALIDATE_ERROR")
end

# Test all math together
println("\n=== Testing all math together ===")
bytes_all = compile_multi([(pipeline_sin, (Float64,)), (pipeline_cos, (Float64,)),
    (pipeline_sqrt, (Float64,)), (pipeline_exp, (Float64,)), (pipeline_log, (Float64,))])
tmpf_all = tempname() * ".wasm"
write(tmpf_all, bytes_all)
try
    run(`wasm-tools validate --features=gc $tmpf_all`)
    println("  all math VALIDATES ($(length(bytes_all)) bytes)")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf_all 2>&1 || true"`) catch; "" end
    println("  all math VALIDATE_ERROR: $(first(valerr, 200))")
end

# Node.js test
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
if NODE_CMD !== nothing
    println("\n=== Node.js tests (individual compile) ===")
    for (name, f, argtypes) in math_funcs
        try
            single_bytes = compile_multi([(f, argtypes)])
            if name == "pipeline_sin"
                actual = run_wasm(single_bytes, "pipeline_sin", 0.0)
                println("  sin(0.0) = $actual (expected 0.0)")
            elseif name == "pipeline_cos"
                actual = run_wasm(single_bytes, "pipeline_cos", 0.0)
                println("  cos(0.0) = $actual (expected 1.0)")
            elseif name == "pipeline_sqrt"
                actual = run_wasm(single_bytes, "pipeline_sqrt", 4.0)
                println("  sqrt(4.0) = $actual (expected 2.0)")
            elseif name == "pipeline_exp"
                actual = run_wasm(single_bytes, "pipeline_exp", 0.0)
                println("  exp(0.0) = $actual (expected 1.0)")
            elseif name == "pipeline_log"
                actual = run_wasm(single_bytes, "pipeline_log", 1.0)
                println("  log(1.0) = $actual (expected 0.0)")
            end
        catch e
            println("  $name ERROR: $(first(sprint(showerror, e), 100))")
        end
    end
end

rm(tmpf, force=true)
rm(tmpf_all, force=true)
println("\nDone.")
