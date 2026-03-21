# discover_codegen_closure.jl — Discover transitive closure of compile_module_from_ir_frozen
#
# Run: julia +1.12 --project=. test/selfhost/discover_codegen_closure.jl

using WasmTarget
using WasmTarget: compile_module_from_ir_frozen, compile_module_from_ir_frozen_no_dict,
                  CompilationContext, WasmModule, TypeRegistry, FunctionRegistry,
                  FrozenCompilationState, WasmValType, BasicBlock,
                  compile_const_value, get_concrete_wasm_type,
                  encode_leb128_signed, encode_leb128_unsigned,
                  to_bytes_no_dict, copy_wasm_module, copy_type_registry

function extract_callees(ci::Core.CodeInfo)
    callees = Set{Tuple{Module, Symbol}}()
    for stmt in ci.code
        if stmt isa Expr
            if stmt.head === :call || stmt.head === :invoke
                func_arg = stmt.head === :invoke ? stmt.args[2] : stmt.args[1]
                if func_arg isa GlobalRef
                    m = func_arg.mod
                    nm = func_arg.name
                    if m === WasmTarget || startswith(string(m), "WasmTarget")
                        push!(callees, (m, nm))
                    end
                end
            end
        end
    end
    return callees
end

function try_add!(list, f, types, name; optimize_false=false)
    try
        result = Base.code_typed(f, types; optimize=!optimize_false)
        if !isempty(result)
            ci, rt = result[1]
            n_stmts = length(ci.code)
            n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
            push!(list, (f, types, name, optimize_false))
            opt_str = optimize_false ? "opt=false" : "opt=true"
            println("  ✓ $name: $n_stmts stmts, $n_gin GotoIfNots ($opt_str)")
            return true
        end
    catch e
        println("  ✗ $name: $(sprint(showerror, e)[1:min(80,end)])")
    end
    return false
end

function main()
    println("=" ^ 70)
    println("Discovering transitive closure of compile_module_from_ir_frozen")
    println("=" ^ 70)

    # BFS from compile_module_from_ir_frozen to find WasmTarget callees
    println("\n--- BFS: WasmTarget-internal callees of compile_module_from_ir_frozen ---")
    seeds = [
        (compile_module_from_ir_frozen, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen"),
        (to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict"),
    ]
    visited = Set{String}()
    for (f, types, name) in seeds
        key = "$name($(join(types, ", ")))"
        push!(visited, key)
        try
            ci, _ = Base.code_typed(f, types; optimize=false)[1]
            n_stmts = length(ci.code)
            n_gin = count(s -> s isa Core.GotoIfNot, ci.code)
            callees = extract_callees(ci)
            println("  $name: $n_stmts stmts, $n_gin GotoIfNots, $(length(callees)) WasmTarget callees")
            for (cm, cn) in sort(collect(callees), by=x->string(x[2]))
                println("      → $cm.$cn")
            end
        catch e
            println("  FAIL: $name — $e")
        end
    end

    # ═══════════════════════════════════════════════════════════════════════
    # Enumerate known codegen function closure
    # ═══════════════════════════════════════════════════════════════════════

    known_functions = Tuple{Any, Tuple, String, Bool}[]

    println("\n--- Level 0: Entry points ---")
    try_add!(known_functions, compile_module_from_ir_frozen, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen"; optimize_false=true)
    try_add!(known_functions, compile_module_from_ir_frozen_no_dict, (Vector, FrozenCompilationState), "compile_module_from_ir_frozen_no_dict"; optimize_false=true)
    try_add!(known_functions, to_bytes_no_dict, (WasmModule,), "to_bytes_no_dict"; optimize_false=true)

    println("\n--- Level 1: Direct callees ---")
    try_add!(known_functions, copy_wasm_module, (WasmModule,), "copy_wasm_module")
    try_add!(known_functions, copy_type_registry, (TypeRegistry,), "copy_type_registry")
    try_add!(known_functions, WasmTarget.register_struct_type!, (WasmModule, TypeRegistry, Type), "register_struct_type!")
    try_add!(known_functions, get_concrete_wasm_type, (Type, WasmModule, TypeRegistry), "get_concrete_wasm_type")
    try_add!(known_functions, WasmTarget.needs_anyref_boxing, (Type,), "needs_anyref_boxing")
    try_add!(known_functions, compile_const_value, (Int64, WasmModule, TypeRegistry), "compile_const_value_i64")
    try_add!(known_functions, compile_const_value, (Int32, WasmModule, TypeRegistry), "compile_const_value_i32")
    try_add!(known_functions, compile_const_value, (Float64, WasmModule, TypeRegistry), "compile_const_value_f64")
    try_add!(known_functions, compile_const_value, (Bool, WasmModule, TypeRegistry), "compile_const_value_bool")
    try_add!(known_functions, encode_leb128_unsigned, (UInt32,), "encode_leb128_unsigned")
    try_add!(known_functions, encode_leb128_signed, (Int32,), "encode_leb128_signed_i32")
    try_add!(known_functions, encode_leb128_signed, (Int64,), "encode_leb128_signed_i64")
    try_add!(known_functions, WasmTarget.populate_type_constant_globals!, (WasmModule, TypeRegistry), "populate_type_constant_globals!")

    # Try add_function!, add_export!, etc with their actual signatures
    for fname in [:add_function!, :add_export!, :add_global_ref!, :_lookup_module_global,
                  :register_function!, :add_type!]
        if isdefined(WasmTarget, fname)
            f = getfield(WasmTarget, fname)
            for m in methods(f)
                sig_params = m.sig.parameters[2:end]
                types = Tuple{sig_params...}
                try_add!(known_functions, f, types, string(fname))
                break
            end
        end
    end

    println("\n--- Level 2: Code generation core ---")
    try_add!(known_functions, WasmTarget.generate_body, (CompilationContext,), "generate_body"; optimize_false=true)
    try_add!(known_functions, WasmTarget.generate_structured, (CompilationContext, Vector{BasicBlock}), "generate_structured"; optimize_false=true)
    try_add!(known_functions, WasmTarget.generate_block_code, (CompilationContext, BasicBlock), "generate_block_code"; optimize_false=true)
    try_add!(known_functions, WasmTarget.analyze_blocks, (Vector{Any},), "analyze_blocks")

    println("\n--- Level 3: Statement compilation ---")
    try_add!(known_functions, WasmTarget.compile_statement, (Expr, Int64, CompilationContext), "compile_statement_expr"; optimize_false=true)
    try_add!(known_functions, WasmTarget.compile_statement, (Core.ReturnNode, Int64, CompilationContext), "compile_statement_return"; optimize_false=true)
    try_add!(known_functions, WasmTarget.compile_statement, (Core.GotoNode, Int64, CompilationContext), "compile_statement_goto")
    try_add!(known_functions, WasmTarget.compile_statement, (Core.GotoIfNot, Int64, CompilationContext), "compile_statement_gotoifnot")
    try_add!(known_functions, WasmTarget.compile_statement, (Core.PhiNode, Int64, CompilationContext), "compile_statement_phi")
    try_add!(known_functions, WasmTarget.compile_statement, (Any, Int64, CompilationContext), "compile_statement_any"; optimize_false=true)

    println("\n--- Level 4: Call/invoke dispatchers + handlers ---")
    try_add!(known_functions, WasmTarget.compile_call, (Expr, Int64, CompilationContext), "compile_call"; optimize_false=true)
    try_add!(known_functions, WasmTarget.compile_invoke, (Expr, Int64, CompilationContext), "compile_invoke"; optimize_false=true)

    # Extracted handlers
    for handler_name in [:_compile_call_checked_mul, :_compile_call_flipsign, :_compile_call_egaleq,
                         :_compile_call_fpext, :_compile_call_isa, :_compile_call_symbol,
                         :_compile_invoke_str_hash, :_compile_invoke_str_find,
                         :_compile_invoke_str_contains, :_compile_invoke_str_startswith,
                         :_compile_invoke_str_endswith, :_compile_invoke_str_uppercase,
                         :_compile_invoke_str_lowercase, :_compile_invoke_str_trim,
                         :_compile_invoke_print]
        if isdefined(WasmTarget, handler_name)
            f = getfield(WasmTarget, handler_name)
            for m in methods(f)
                sig_params = m.sig.parameters[2:end]
                types = Tuple{sig_params...}
                try_add!(known_functions, f, types, string(handler_name); optimize_false=true)
                break
            end
        else
            println("  ? $handler_name not defined")
        end
    end

    println("\n--- Level 5: Value compilation + helpers ---")
    try_add!(known_functions, WasmTarget.compile_value, (Any, CompilationContext), "compile_value"; optimize_false=true)
    if isdefined(WasmTarget, :compile_new)
        try_add!(known_functions, WasmTarget.compile_new, (Expr, Int64, CompilationContext), "compile_new"; optimize_false=true)
    end
    if isdefined(WasmTarget, :compile_foreigncall)
        try_add!(known_functions, WasmTarget.compile_foreigncall, (Expr, Int64, CompilationContext), "compile_foreigncall"; optimize_false=true)
    end

    # Various helpers
    for helper_name in [:infer_value_type, :allocate_local!, :julia_to_wasm_type,
                        :get_array_type!, :get_string_array_type!, :register_tuple_type!,
                        :is_struct_type, :is_closure_type, :emit_numeric_to_externref!,
                        :get_numeric_box_type!, :get_nothing_box_type!, :get_base_struct_type!]
        if isdefined(WasmTarget, helper_name)
            f = getfield(WasmTarget, helper_name)
            for m in methods(f)
                sig_params = m.sig.parameters[2:end]
                types = Tuple{sig_params...}
                try
                    try_add!(known_functions, f, types, string(helper_name))
                catch
                end
                break
            end
        end
    end

    println("\n--- Level 6: Bytecode post-processing ---")
    try_add!(known_functions, WasmTarget.fix_broken_select_instructions, (Vector{UInt8},), "fix_broken_select_instructions")
    try_add!(known_functions, WasmTarget.fix_consecutive_local_sets, (Vector{UInt8},), "fix_consecutive_local_sets")
    try_add!(known_functions, WasmTarget.strip_excess_after_function_end, (Vector{UInt8},), "strip_excess_after_function_end")
    try_add!(known_functions, WasmTarget.fix_array_len_wrap, (Vector{UInt8},), "fix_array_len_wrap")
    try_add!(known_functions, WasmTarget.fix_i32_wrap_after_i32_ops, (Vector{UInt8},), "fix_i32_wrap_after_i32_ops")
    try_add!(known_functions, WasmTarget.fix_i64_local_in_i32_ops, (Vector{UInt8}, Vector{WasmValType}), "fix_i64_local_in_i32_ops")
    try_add!(known_functions, WasmTarget.fix_local_get_set_type_mismatch, (Vector{UInt8}, Vector{WasmValType}), "fix_local_get_set_type_mismatch")
    try_add!(known_functions, WasmTarget.fix_numeric_to_ref_local_stores, (Vector{UInt8}, Vector{WasmValType}, Int64), "fix_numeric_to_ref_local_stores")

    # Byte extraction
    try_add!(known_functions, WasmTarget.wasm_bytes_length, (Vector{UInt8},), "wasm_bytes_length")
    try_add!(known_functions, WasmTarget.wasm_bytes_get, (Vector{UInt8}, Int32), "wasm_bytes_get")

    println("\n" * "=" ^ 70)
    println("SUMMARY")
    println("=" ^ 70)
    println("  Total functions: $(length(known_functions))")
    println("  With optimize=false: $(count(x -> x[4], known_functions))")
    println("  With optimize=true: $(count(x -> !x[4], known_functions))")

    total_gin = 0
    for (f, types, name, opt_false) in known_functions
        try
            ci, _ = Base.code_typed(f, types; optimize=!opt_false)[1]
            total_gin += count(s -> s isa Core.GotoIfNot, ci.code)
        catch
        end
    end
    println("  Total GotoIfNots: $total_gin")
    println("=" ^ 70)

    return known_functions
end

main()
