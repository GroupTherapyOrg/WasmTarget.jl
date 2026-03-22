# trace_validation_errors.jl — CG-003b: Root-cause type mismatch patterns
#
# RESEARCH ONLY: For each failing function, compile individually,
# dump WAT, and extract context around the failing byte offset.
#
# Run: julia +1.12 --project=. test/selfhost/trace_validation_errors.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_module_from_ir_frozen, compile_module_from_ir_frozen_no_dict,
                  to_bytes, to_bytes_no_dict,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  FrozenCompilationState, WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  copy_wasm_module, copy_type_registry

println("=" ^ 70)
println("CG-003b: Root-cause type mismatch patterns")
println("=" ^ 70)

# Functions that fail validation (from CG-003a)
failing_functions = [
    (compile_module_from_ir_frozen, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen", false, "(ref null \$type) vs (ref null \$type) @ 0x3b08"),
    (copy_wasm_module, (WasmModule,), "copy_wasm_module", false, "i32 vs structref @ 0xed4"),
    (WasmTarget.register_struct_type!, (WasmModule, TypeRegistry, Type), "register_struct_type!", false, "anyref vs (ref null \$type) @ 0x3841"),
    (WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!", false, "i32 vs (ref null \$type) @ 0x97f"),
    (WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement", true, "i32 vs (ref null \$type) @ 0x58b5"),
    (WasmTarget.compile_call, (Expr, Int64, CompilationContext), "compile_call", true, "i32 vs i64 @ 0x8b78"),
    (WasmTarget.compile_invoke, (Expr, Int64, CompilationContext), "compile_invoke", true, "i32 vs i64 @ 0x60aa"),
    (WasmTarget.compile_value, (Any, CompilationContext), "compile_value", true, "eqref vs anyref @ 0x28f8"),
    (WasmTarget.compile_new, (Expr, Int64, CompilationContext), "compile_new", true, "anyref vs (ref null \$type) @ 0x2e72"),
    (WasmTarget.compile_foreigncall, (Expr, Int64, CompilationContext), "compile_foreigncall", true, "(ref null \$type) vs (ref \$type) @ 0x3a93"),
    (WasmTarget._compile_call_symbol, (Any, Vector{UInt8}, CompilationContext), "_compile_call_symbol", false, "nothing on stack @ 0x129f"),
    (WasmTarget._compile_invoke_print, (Symbol, Any, CompilationContext), "_compile_invoke_print", false, "anyref vs f64 @ 0x4fef"),
]

tmpdir = mktempdir()

for (f, atypes, name, opt_false, error_desc) in failing_functions
    println("\n" * "─" ^ 70)
    println("Function: $name")
    println("Error: $error_desc")
    println("─" ^ 70)

    # Compile
    ci, rt = Base.code_typed(f, atypes; optimize=!opt_false)[1]
    entry = (ci, rt, atypes, name, f)
    mod = compile_module_from_ir([entry])
    bytes = to_bytes(mod)

    wasm_path = joinpath(tmpdir, "$(name).wasm")
    wat_path = joinpath(tmpdir, "$(name).wat")
    write(wasm_path, bytes)

    # Get validation error with full detail
    err_file = joinpath(tmpdir, "err.txt")
    run(pipeline(ignorestatus(`wasm-tools validate --features=gc $wasm_path`), stdout=devnull, stderr=err_file))
    err_msg = strip(read(err_file, String))
    println("  Validation error: $err_msg")

    # Convert to WAT and extract context around failing offset
    try
        wat_content = read(`wasm-tools print --skeleton $wasm_path`, String)
        write(wat_path, wat_content)

        # Parse the offset from the error
        offset_match = match(r"offset 0x([0-9a-f]+)", err_msg)
        if offset_match !== nothing
            offset = parse(Int, offset_match.captures[1], base=16)
            println("  Failing offset: 0x$(string(offset, base=16)) ($offset)")
            println("  Module size: $(length(bytes)) bytes")

            # Find the instruction at/near this offset using wasm-tools dump
            dump_output = read(`wasm-tools dump $wasm_path`, String)

            # Find lines near the offset
            lines = split(dump_output, '\n')
            target_lines = String[]
            for (li, line) in enumerate(lines)
                m = match(r"^\s*(0x[0-9a-f]+)\s*\|", line)
                if m !== nothing
                    line_offset = parse(Int, m.captures[1], base=16)
                    if abs(line_offset - offset) <= 32  # within 32 bytes
                        push!(target_lines, line)
                    end
                end
            end

            if !isempty(target_lines)
                println("\n  Dump around offset 0x$(string(offset, base=16)):")
                for line in target_lines
                    # Mark the exact offset line
                    if occursin("0x$(string(offset, base=16))", line) || occursin("0x$(lpad(string(offset, base=16), 4, '0'))", line)
                        println("  >>> $line")
                    else
                        println("      $line")
                    end
                end
            end

            # Also find what WAT instruction is nearby
            wat_lines = split(wat_content, '\n')
            # WAT doesn't have offsets directly, but let's look at func body
            println("\n  WAT snippet (first func body, lines around error context):")
            in_func = false
            func_lines = 0
            printed = 0
            for (li, line) in enumerate(wat_lines)
                if occursin("(func", line)
                    in_func = true
                    func_lines = 0
                end
                if in_func
                    func_lines += 1
                    # Print first 15 lines of the func body to see local declarations
                    if func_lines <= 15 && printed < 30
                        println("    L$li: $line")
                        printed += 1
                    end
                end
            end
        end
    catch e
        println("  WAT conversion failed: $e")
    end

    # Print module stats
    println("\n  Stats: $(length(ci.code)) stmts, $(count(s -> s isa Core.GotoIfNot, ci.code)) GotoIfNots, $(length(bytes)) bytes")
    println("  Types in module: $(length(mod.types))")
    println("  Locals in func: $(length(mod.functions[1].locals))")
    println("  Local types: $(mod.functions[1].locals[1:min(10,end)])")
end

rm(tmpdir, recursive=true, force=true)

println("\n" * "=" ^ 70)
println("CG-003b trace complete")
println("=" ^ 70)
