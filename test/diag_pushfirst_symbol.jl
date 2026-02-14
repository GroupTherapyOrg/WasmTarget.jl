#!/usr/bin/env julia
# Diagnostic: Does pushfirst! preserve Symbol values in Vector{Any}?
# PURE-325 agent 32 — investigating null externref in args array

using WasmTarget

println("=== DIAGNOSTIC: pushfirst! Symbol into Vector{Any} ===\n")

# Test 1: Create Expr, pushfirst! a Symbol, read it back
function test_pushfirst_symbol()
    # Simplest possible test: create Expr(:call), pushfirst! :a, return args[1]
    f1 = function(s::Symbol)
        e = Expr(s)
        pushfirst!(e.args, :hello)
        return e.args[1]
    end

    print("Test 1 - pushfirst! Symbol literal: ")
    try
        bytes = compile(f1, (Symbol,))
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        println(validates ? "VALIDATES ($(length(bytes)) bytes)" : "FAILS VALIDATION")
        if !validates
            err = read(pipeline(`wasm-tools validate $tmpf`), String)
            println("  Error: $err")
        end
        # Try to dump WAT for analysis
        wat = read(`wasm-tools print $tmpf`, String)
        open(tmpf * ".wat", "w") do io write(io, wat) end
        println("  WAT: $(tmpf).wat")
    catch e
        println("ERROR: $(sprint(showerror, e)[1:min(200, end)])")
    end

    # Test 2: pushfirst! with variable Symbol (argument)
    f2 = function(head::Symbol, val::Symbol)
        e = Expr(head)
        pushfirst!(e.args, val)
        return e.args[1]
    end

    print("Test 2 - pushfirst! Symbol arg: ")
    try
        bytes = compile(f2, (Symbol, Symbol))
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

    # Test 3: What about push! instead of pushfirst!?
    f3 = function(head::Symbol, val::Symbol)
        e = Expr(head)
        push!(e.args, val)
        return e.args[1]
    end

    print("Test 3 - push! Symbol arg: ")
    try
        bytes = compile(f3, (Symbol, Symbol))
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

    # Test 4: Direct array set — skip Vector wrapper
    f4 = function(arr::Vector{Any}, val::Symbol)
        arr[1] = val
        return arr[1]
    end

    print("Test 4 - Direct setindex! Symbol: ")
    try
        bytes = compile(f4, (Vector{Any}, Symbol))
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

    # Test 5: length(Expr(:call).args) after pushfirst!
    f5 = function(head::Symbol, val::Symbol)
        e = Expr(head)
        pushfirst!(e.args, val)
        return length(e.args)
    end

    print("Test 5 - length after pushfirst!: ")
    try
        bytes = compile(f5, (Symbol, Symbol))
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

    # Test 6: The exact "a+b" flow: fixup_Expr_child call
    # fixup_Expr_child returns its input for non-Expr values
    # isa(arg, Expr) || return arg
    f6 = function(s::Symbol)
        # Mimic: isa(s, Expr) || return s
        if isa(s, Expr)
            return s
        end
        return s
    end

    print("Test 6 - isa(Symbol, Expr) branch: ")
    try
        bytes = compile(f6, (Symbol,))
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
end

test_pushfirst_symbol()
