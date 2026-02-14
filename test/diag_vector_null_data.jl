#!/usr/bin/env julia
# Diagnostic: Does Vector{UInt8} construction produce null data array?
# PURE-325 agent 32 — investigating null data in Vector{UInt8}

using WasmTarget

println("=== DIAGNOSTIC: Vector construction and data access ===\n")

# Test 1: Create Vector{UInt8} and access element
function test_vec_construction()
    f1 = function()
        v = Vector{UInt8}(undef, 128)
        return v
    end

    print("Test 1 - Vector{UInt8}(undef, 128): ")
    try
        bytes = compile(f1, ())
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        println(validates ? "VALIDATES ($(length(bytes)) bytes)" : "FAILS VALIDATION")
        # Check WAT for ref.null in vector construction
        wat = read(`wasm-tools print $tmpf`, String)
        if occursin("ref.null", wat) && occursin("struct.new", wat)
            println("  ⚠ WARNING: Contains ref.null + struct.new pattern (potential null data)")
            # Count ref.null occurrences
            n = count("ref.null", wat)
            println("  ref.null count: $n")
        end
        open(tmpf * ".wat", "w") do io write(io, wat) end
        println("  WAT: $(tmpf).wat")
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end

    # Test 2: Vector{UInt8} access - index into it
    f2 = function(idx::Int)
        v = Vector{UInt8}(undef, 16)
        return v[idx]
    end

    print("Test 2 - Vector{UInt8}(undef, 16)[idx]: ")
    try
        bytes = compile(f2, (Int,))
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        println(validates ? "VALIDATES ($(length(bytes)) bytes)" : "FAILS VALIDATION")
        if !validates
            err = read(pipeline(`wasm-tools validate $tmpf`), String)
            println("  Error: $err")
        end
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end

    # Test 3: Struct with Vector{UInt8} field
    f3 = function()
        v = Vector{UInt8}(undef, 128)
        return length(v)
    end

    print("Test 3 - length(Vector{UInt8}(undef, 128)): ")
    try
        bytes = compile(f3, ())
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        println(validates ? "VALIDATES ($(length(bytes)) bytes)" : "FAILS VALIDATION")
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end

    # Test 4: Copy pattern (like _growbeg! which copies elements)
    f4 = function()
        old = Vector{UInt8}(undef, 16)
        new_v = Vector{UInt8}(undef, 32)
        return length(new_v)
    end

    print("Test 4 - Two vectors: ")
    try
        bytes = compile(f4, ())
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        println(validates ? "VALIDATES ($(length(bytes)) bytes)" : "FAILS VALIDATION")
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end

    # Test 5: What does the Wasm IR look like for this?
    # Compile using compile() and print SSA info
    println("\n--- Checking SSA types for Vector{UInt8} construction ---")
    f5 = function()
        v = Vector{UInt8}(undef, 10)
        return v
    end
    try
        ci = code_typed(f5, ())[1]
        println("IR:")
        println(ci[1])
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end
end

test_vec_construction()
