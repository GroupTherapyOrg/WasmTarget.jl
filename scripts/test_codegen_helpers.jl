#!/usr/bin/env julia
# test_codegen_helpers.jl — PURE-6025
#
# Test individual WasmTarget codegen helper functions for VALIDATES.
# These are the 74 WasmTarget functions in the codegen delta.
# Skip compile_module_from_ir (stack overflows) and test the rest individually.
#
# For each function: compile individually → VALIDATES / COMPILE_ERROR / VALIDATE_ERROR

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using Dates

println("=== PURE-6025: Test codegen helper functions ===")
println("Started: $(Dates.now())")
flush(stdout)

# List of WasmTarget codegen functions to test individually.
# These are from the delta analysis. We SKIP compile_module_from_ir (stack overflows).
# For each: (function, (arg_types...))

# We need to construct test instances for the types used
# TypeRegistry, WasmModule, etc. are available from WasmTarget

# Simple helper functions first (take basic types, no complex codegen dispatch)
test_functions = [
    # Type registry functions
    ("WasmModule()", () -> WasmTarget.WasmModule, ()),
    ("TypeRegistry()", () -> WasmTarget.TypeRegistry, ()),
    ("FuncType", () -> WasmTarget.FuncType, (Vector{WasmTarget.NumType}, Vector{WasmTarget.NumType})),

    # to_bytes
    ("to_bytes", () -> WasmTarget.to_bytes, (WasmTarget.WasmModule,)),

    # Type functions
    ("get_concrete_wasm_type", () -> WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("get_string_array_type!", () -> WasmTarget.get_string_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry)),
    ("get_numeric_box_type!", () -> WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType)),
    ("register_struct_type!", () -> WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_union_type!", () -> WasmTarget.register_union_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)),
    ("register_vector_type!", () -> WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("register_tuple_type!", () -> WasmTarget.register_tuple_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}})),
    ("register_closure_type!", () -> WasmTarget.register_closure_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType)),
    ("register_int128_type!", () -> WasmTarget.register_int128_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("register_matrix_type!", () -> WasmTarget.register_matrix_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("get_array_type!", () -> WasmTarget.get_array_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type)),
    ("is_self_referential_type", () -> WasmTarget.is_self_referential_type, (DataType,)),
    ("resolve_union_type", () -> WasmTarget.resolve_union_type, (Union,)),
    ("get_nullable_inner_type", () -> WasmTarget.get_nullable_inner_type, (Union,)),

    # Module operations
    ("add_type! FuncType", () -> WasmTarget.add_type!, (WasmTarget.WasmModule, WasmTarget.FuncType)),
    ("add_type! StructType", () -> WasmTarget.add_type!, (WasmTarget.WasmModule, WasmTarget.StructType)),
    ("add_function!", () -> WasmTarget.add_function!, (WasmTarget.WasmModule, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{WasmTarget.WasmValType}, Vector{UInt8})),
    ("types_equal", () -> WasmTarget.types_equal, (WasmTarget.FuncType, WasmTarget.FuncType)),
    ("populate_type_constant_globals!", () -> WasmTarget.populate_type_constant_globals!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry)),

    # Encoding helpers
    ("encode_block_type", () -> WasmTarget.encode_block_type, (WasmTarget.ConcreteRef,)),
    ("write_u32! Int64", () -> WasmTarget.write_u32!, (WasmTarget.WasmWriter, Int64)),
    ("write_u32! UInt32", () -> WasmTarget.write_u32!, (WasmTarget.WasmWriter, UInt32)),

    # Analysis functions (don't depend on full codegen)
    ("analyze_blocks", () -> WasmTarget.analyze_blocks, (Vector{Any},)),
    ("find_try_regions", () -> WasmTarget.find_try_regions, (Vector{Any},)),
    ("find_common_wasm_type", () -> WasmTarget.find_common_wasm_type, (Vector{Any},)),

    # Validator functions
    ("validate_pop! NumType", () -> WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, WasmTarget.NumType)),
    ("validate_pop! ConcreteRef", () -> WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, WasmTarget.ConcreteRef)),
    ("validate_pop! RefType", () -> WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, WasmTarget.RefType)),
    ("validate_pop! UInt8", () -> WasmTarget.validate_pop!, (WasmTarget.WasmStackValidator, UInt8)),
    ("validate_pop_any!", () -> WasmTarget.validate_pop_any!, (WasmTarget.WasmStackValidator,)),
    ("validate_instruction!", () -> WasmTarget.validate_instruction!, (WasmTarget.WasmStackValidator, UInt8, Nothing)),
    ("validate_emitted_bytes!", () -> WasmTarget.validate_emitted_bytes!, (WasmTarget.CompilationContext, Vector{UInt8}, Int64)),
    ("fix_broken_select_instructions", () -> WasmTarget.fix_broken_select_instructions, (Vector{UInt8},)),
]

println("Testing $(length(test_functions)) WasmTarget functions individually...")
println()
flush(stdout)

validates = String[]
validate_errors = Tuple{String, String}[]
compile_errors = Tuple{String, String}[]

for (i, (name, func_getter, arg_types)) in enumerate(test_functions)
    print("  [$i/$(length(test_functions))] $name — ")
    flush(stdout)

    local func
    try
        func = func_getter()
    catch e
        push!(compile_errors, (name, "getter failed: $(sprint(showerror, e)[1:min(100,end)])"))
        println("GETTER_ERROR")
        flush(stdout)
        continue
    end

    # Try to compile
    local wasm_bytes
    try
        wasm_bytes = WasmTarget.compile_multi([(func, arg_types)])
    catch e
        msg = sprint(showerror, e)
        if contains(msg, "StackOverflow") || contains(msg, "stack overflow")
            push!(compile_errors, (name, "STACK_OVERFLOW"))
            println("STACK_OVERFLOW ✗")
        else
            push!(compile_errors, (name, msg[1:min(200, end)]))
            println("COMPILE_ERROR: $(msg[1:min(80, end)])")
        end
        flush(stdout)
        continue
    end

    # Validate
    tmpf = tempname() * ".wasm"
    write(tmpf, wasm_bytes)
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end

    if ok
        # Count functions
        print_buf = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools print $tmpf`, stdout=print_buf))
            wasm_text = String(take!(print_buf))
            func_count = count(l -> contains(l, "(func "), split(wasm_text, '\n'))
            push!(validates, name)
            println("VALIDATES ✓ ($func_count funcs, $(length(wasm_bytes)) bytes)")
        catch
            push!(validates, name)
            println("VALIDATES ✓ ($(length(wasm_bytes)) bytes)")
        end
    else
        err_msg = String(take!(errbuf))
        first_line = split(err_msg, '\n')[1]
        push!(validate_errors, (name, first_line))
        println("VALIDATE_ERROR: $first_line")
    end
    rm(tmpf; force=true)
    flush(stdout)
end

println()
println("=== RESULTS ===")
println("  VALIDATES: $(length(validates))/$(length(test_functions))")
println("  VALIDATE_ERROR: $(length(validate_errors))/$(length(test_functions))")
println("  COMPILE_ERROR: $(length(compile_errors))/$(length(test_functions))")
println()

if !isempty(validate_errors)
    println("VALIDATE_ERRORS:")
    for (name, err) in validate_errors
        println("  ✗ $name — $err")
    end
    println()
end

if !isempty(compile_errors)
    println("COMPILE_ERRORS:")
    for (name, err) in compile_errors
        println("  ✗ $name — $err")
    end
    println()
end

println("Done: $(Dates.now())")
flush(stdout)
