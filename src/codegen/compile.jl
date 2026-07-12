# ============================================================================
# Main Compilation Entry Point
# ============================================================================

"""The one Julia-signature → physical Wasm-signature derivation."""
function function_wasm_signature(arg_types, return_type, global_args,
                                 mod::WasmModule, type_registry::TypeRegistry)
    pts = WasmValType[]
    for (j, T) in enumerate(arg_types)
        j in global_args && continue
        push!(pts, T isa Union && needs_anyref_boxing(T) ? AnyRef :
                   get_concrete_wasm_type(T, mod, type_registry))
    end
    rts = (return_type === Nothing || return_type === Union{}) ? WasmValType[] :
          WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]
    return pts, rts
end

"""
    compile_function(f, arg_types, func_name) -> WasmModule

Compile a Julia function to a WebAssembly module.
"""
function compile_function(f, arg_types::Tuple, func_name::String; optimize_ir::Bool=true)::WasmModule
    # Use compile_module for single functions too, enabling auto-discovery of dependencies
    # This ensures that cross-function calls work correctly
    return compile_module([(f, arg_types, func_name)]; optimize_ir=optimize_ir)
end

"""
Check if a function is a WasmTarget intrinsic that needs special code generation.
Returns true if the function should be generated as an intrinsic instead of compiling Julia IR.
"""
function is_intrinsic_function(f)::Bool
    # Only functions can be intrinsics, not types (constructors)
    if !(f isa Function)
        return false
    end
    fname = nameof(f)
    return f === Base.rethrow ||
           fname in [:str_char, :str_getchar, :str_len, :str_charlen, :str_eq, :str_new,
                     :str_setchar!, :str_concat, :str_substr]
end

"""
Generate intrinsic function body for WasmTarget runtime functions.
These functions have special WASM implementations that differ from their Julia fallbacks.
Returns the function body bytes, or nothing if not an intrinsic.
"""
function generate_intrinsic_body(f, arg_types::Tuple, mod::WasmModule, type_registry::TypeRegistry;
                                 return_type::Union{Type, Nothing}=nothing)::Union{Tuple{Vector{UInt8}, Vector{WasmValType}}, Nothing}
    # Only functions can have intrinsic bodies
    if !(f isa Function)
        return nothing
    end
    fname = nameof(f)
    # tag-run: the builder declares its params (the same julia→wasm mapping the
    # emitted function will carry) so the tracker reads truth for every local.get
    local _ib_params = WasmValType[get_concrete_wasm_type(T, mod, type_registry) for T in arg_types]
    local _ib_results = (return_type === nothing || return_type === Nothing || return_type === Union{}) ?
                        WasmValType[] : WasmValType[get_concrete_wasm_type(return_type, mod, type_registry)]
    b = InstrBuilder(_ib_params, _ib_results; func_name="generate_intrinsic_body", mod=mod)
    extra_locals = WasmValType[]

    if f === Base.rethrow
        ensure_exception_tag!(mod)
        global_get!(b, ensure_exception_global!(mod), AnyRef)
        ref_null!(b, ExternRef)
        throw_!(b, 0; inputs=WasmValType[AnyRef, ExternRef])
        end_block!(b)
        return (builder_code(b), extra_locals)
    end

    # Get string array type for string operations
    str_type_idx = get_string_array_type!(mod, type_registry)
    # parity(M9): params are the CLASSED string — every string push reads through
    # to the DATA array (dart: methods read the class's array field).
    # parity(M9): string-returning bodies publish the CLASSED string. The caller-visible
    # result type is $JlString; the array is saved through a dedicated extra local.
    function _wrap_result_str!(bb, scratch_idx)
        builder_set_local_type!(bb, Int(scratch_idx), ConcreteRef(UInt32(str_type_idx), true))
        local_set!(bb, scratch_idx)
        i32_const!(bb, Int64(ensure_type_id!(type_registry, String)))
        i32_const!(bb, 0)
        local_get!(bb, scratch_idx)
        i32_const!(bb, -1)
        struct_new!(bb, get_string_struct_type!(mod, type_registry),
                    WasmValType[I32, I32, ConcreteRef(UInt32(str_type_idx), true), I32])
    end
    _str0!(bb) = (local_get!(bb, 0);
                  struct_get!(bb, UInt32(get_string_struct_type!(mod, type_registry)), UInt32(2),
                              ConcreteRef(UInt32(str_type_idx), true)))

    if fname === :str_char
        # str_char(s::String, i::Int32)::Int32
        # Gets character at 1-based index
        # local 0 = string (array ref)
        # local 1 = index (i32)
        _str0!(b)          # string DATA
        local_get!(b, 1)  # index
        # Subtract 1 for 0-based indexing
        i32_const!(b, 1)
        num!(b, Opcode.I32_SUB)
        # array.get_u (packed i8 → i32)
        array_get!(b, str_type_idx, I32; signed=false)
        end_block!(b)
        return (builder_code(b), extra_locals)

    elseif fname === :str_getchar
        # str_getchar(s::String, i::Int32)::Int32
        # Decode UTF-8 character at 1-based byte index → Unicode codepoint as i32
        # local 0 = string (array ref)
        # local 1 = index (i32, 1-based)
        # extra locals: local 2 = b0 (first byte), local 3 = idx0 (0-based index)
        push!(extra_locals, I32)  # local 2: b0
        push!(extra_locals, I32)  # local 3: idx0

        # idx0 = i - 1 (convert 1-based to 0-based)
        local_get!(b, 1)  # i
        i32_const!(b, 1)
        num!(b, Opcode.I32_SUB)
        local_set!(b, 3)  # idx0

        # b0 = s[idx0] (array.get_u)
        _str0!(b)          # string DATA
        local_get!(b, 3)  # idx0
        array_get!(b, str_type_idx, I32; signed=false)
        local_set!(b, 2)  # b0

        # if b0 < 0x80: return b0 (ASCII)
        # else if b0 < 0xE0: 2-byte
        # else if b0 < 0xF0: 3-byte
        # else: 4-byte
        local_get!(b, 2)  # b0
        i32_const!(b, Int32(0x80))
        num!(b, Opcode.I32_LT_U)
        if_!(b, UInt8(I32))  # result type i32

        # === ASCII: return b0 ===
        local_get!(b, 2)  # b0

        else_!(b)

        # Check if 2-byte (b0 < 0xE0)
        local_get!(b, 2)  # b0
        i32_const!(b, Int32(0xE0))
        num!(b, Opcode.I32_LT_U)
        if_!(b, UInt8(I32))

        # === 2-byte: ((b0 & 0x1F) << 6) | (s[idx0+1] & 0x3F) ===
        local_get!(b, 2)  # b0
        i32_const!(b, 0x1F)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x06)
        num!(b, Opcode.I32_SHL)
        # s[idx0+1] & 0x3F
        _str0!(b)          # string DATA
        local_get!(b, 3)  # idx0
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        num!(b, Opcode.I32_OR)

        else_!(b)

        # Check if 3-byte (b0 < 0xF0)
        local_get!(b, 2)  # b0
        i32_const!(b, Int32(0xF0))
        num!(b, Opcode.I32_LT_U)
        if_!(b, UInt8(I32))

        # === 3-byte: ((b0 & 0x0F) << 12) | ((s[idx0+1] & 0x3F) << 6) | (s[idx0+2] & 0x3F) ===
        local_get!(b, 2)  # b0
        i32_const!(b, 0x0F)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x0C)  # 12
        num!(b, Opcode.I32_SHL)
        # (s[idx0+1] & 0x3F) << 6
        _str0!(b)
        local_get!(b, 3)
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x06)
        num!(b, Opcode.I32_SHL)
        num!(b, Opcode.I32_OR)
        # s[idx0+2] & 0x3F
        _str0!(b)
        local_get!(b, 3)
        i32_const!(b, 2)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        num!(b, Opcode.I32_OR)

        else_!(b)

        # === 4-byte: ((b0 & 0x07) << 18) | ((s[idx0+1] & 0x3F) << 12) | ((s[idx0+2] & 0x3F) << 6) | (s[idx0+3] & 0x3F) ===
        local_get!(b, 2)  # b0
        i32_const!(b, 0x07)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x12)  # 18
        num!(b, Opcode.I32_SHL)
        # (s[idx0+1] & 0x3F) << 12
        _str0!(b)
        local_get!(b, 3)
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x0C)  # 12
        num!(b, Opcode.I32_SHL)
        num!(b, Opcode.I32_OR)
        # (s[idx0+2] & 0x3F) << 6
        _str0!(b)
        local_get!(b, 3)
        i32_const!(b, 2)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        i32_const!(b, 0x06)
        num!(b, Opcode.I32_SHL)
        num!(b, Opcode.I32_OR)
        # s[idx0+3] & 0x3F
        _str0!(b)
        local_get!(b, 3)
        i32_const!(b, 3)
        num!(b, Opcode.I32_ADD)
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, 0x3F)
        num!(b, Opcode.I32_AND)
        num!(b, Opcode.I32_OR)

        end_block!(b)  # end 3-byte if/else (4-byte)
        end_block!(b)  # end 2-byte if/else (3/4-byte)
        end_block!(b)  # end ASCII if/else (multi-byte)

        end_block!(b)  # end function
        return (builder_code(b), extra_locals)

    elseif fname === :str_len
        # str_len(s::String)::Int32
        # Returns byte length of string (ncodeunits)
        # local 0 = string (array ref)
        _str0!(b)          # string DATA
        # array.len
        array_len!(b)
        end_block!(b)
        return (builder_code(b), extra_locals)

    elseif fname === :str_charlen
        # str_charlen(s::String)::Int32
        # Count UTF-8 codepoints by counting non-continuation bytes
        # A byte is a continuation byte if (byte & 0xC0) == 0x80
        # local 0 = string (array ref)
        # local 1 = i (loop counter), local 2 = count, local 3 = len
        push!(extra_locals, I32)  # local 1: i
        push!(extra_locals, I32)  # local 2: count
        push!(extra_locals, I32)  # local 3: len

        # len = array.len(s)
        _str0!(b)
        array_len!(b)
        local_set!(b, 3)  # len

        # i = 0, count = 0 (already zero-initialized)

        # block $exit (result i32)
        block!(b, UInt8(I32))

        # loop $loop (void)
        loop!(b)

        # if i >= len: break with count
        local_get!(b, 1)  # i
        local_get!(b, 3)  # len
        num!(b, Opcode.I32_GE_U)
        if_!(b)
        local_get!(b, 2)  # count
        br!(b, 2)  # br $exit
        end_block!(b)

        # byte = s[i]; if (byte & 0xC0) != 0x80: count++
        _str0!(b)          # string DATA
        local_get!(b, 1)  # i
        array_get!(b, str_type_idx, I32; signed=false)
        i32_const!(b, Int32(0xC0))
        num!(b, Opcode.I32_AND)
        i32_const!(b, Int32(0x80))
        num!(b, Opcode.I32_NE)
        if_!(b)
        # count++
        local_get!(b, 2)
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        local_set!(b, 2)
        end_block!(b)

        # i++
        local_get!(b, 1)
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        local_set!(b, 1)

        # continue loop
        br!(b, 0)

        end_block!(b)  # end loop
        unreachable!(b)  # structural trap (dart-legit dead path)
        end_block!(b)  # end block

        end_block!(b)  # end function
        return (builder_code(b), extra_locals)

    elseif fname === :str_eq
        # str_eq(a::String, b::String)::Bool
        # Element-by-element comparison (not ref.eq identity check)
        # local 0 = a (array ref), local 1 = b (array ref), local 2 = i (loop counter)
        push!(extra_locals, I32)  # local 2: loop counter i

        # Compare lengths first: if a.len != b.len, return false
        local_get!(b, 0)  # a
        array_len!(b)
        local_get!(b, 1)  # b
        array_len!(b)
        num!(b, Opcode.I32_NE)
        if_!(b, UInt8(I32))  # result type i32
        # Lengths differ → return 0 (false)
        i32_const!(b, 0)
        else_!(b)

        # Lengths equal — loop to compare elements
        # i = 0
        i32_const!(b, 0)
        local_set!(b, 2)  # i = 0

        # block $exit (result i32) — for early return of false
        block!(b, UInt8(I32))  # result type i32

        # loop $loop (void)
        loop!(b)  # void block type

        # if i >= a.len → break out with true (all matched)
        local_get!(b, 2)  # i
        local_get!(b, 0)  # a
        array_len!(b)
        num!(b, Opcode.I32_GE_U)
        if_!(b)  # void
        # Done — push 1 (true) and break out of block
        i32_const!(b, 1)
        br!(b, 2)  # br $exit (block depth 2: if=0, loop=1, block=2)
        end_block!(b)  # end if

        # Compare a[i] vs b[i] (array.get_u for packed i8)
        local_get!(b, 0)  # a
        local_get!(b, 2)  # i
        array_get!(b, str_type_idx, I32; signed=false)
        local_get!(b, 1)  # b
        local_get!(b, 2)  # i
        array_get!(b, str_type_idx, I32; signed=false)
        num!(b, Opcode.I32_NE)
        if_!(b)  # void
        # Mismatch — push 0 (false) and break out of block
        i32_const!(b, 0)
        br!(b, 2)  # br $exit (block depth 2: if=0, loop=1, block=2)
        end_block!(b)  # end if

        # i++
        local_get!(b, 2)  # i
        i32_const!(b, 1)
        num!(b, Opcode.I32_ADD)
        local_set!(b, 2)  # i = i + 1

        # br $loop (continue)
        br!(b, 0)  # br to loop (depth 0 from here)
        end_block!(b)  # end loop
        unreachable!(b)  # all loop paths branch — unreachable  # structural trap (dart-legit dead path)
        end_block!(b)  # end block

        end_block!(b)  # end if/else (lengths equal)
        end_block!(b)  # end function
        return (builder_code(b), extra_locals)

    elseif fname === :str_new
        # str_new(len::Int32)::String
        # Create new string array of given length
        local_get!(b, 0)  # length
        array_new_default!(b, str_type_idx)
        push!(extra_locals, ConcreteRef(UInt32(str_type_idx), true))
        _wrap_result_str!(b, 1 + length(extra_locals) - 1)   # 1 param
        end_block!(b)
        return (builder_code(b), extra_locals)

    elseif fname === :str_setchar!
        # str_setchar!(s::String, i::Int32, c::Int32)::Nothing
        # Sets character at 1-based index
        _str0!(b)          # string DATA
        local_get!(b, 1)  # index
        # Subtract 1 for 0-based indexing
        i32_const!(b, 1)
        num!(b, Opcode.I32_SUB)
        local_get!(b, 2)  # char
        # array.set
        array_set!(b, str_type_idx, I32)
        end_block!(b)
        return (builder_code(b), extra_locals)

    elseif fname === :str_concat
        # str_concat(a::String, b::String)::String
        # Concatenate two UTF-8 byte arrays into a new array
        # local 0 = a (array ref), local 1 = b (array ref)
        # extra locals: local 2 = len_a, local 3 = result (array ref)
        # parity(M9): params are CLASSED strings — unwrap once into array locals
        push!(extra_locals, ConcreteRef(UInt32(str_type_idx), true))  # a data
        push!(extra_locals, ConcreteRef(UInt32(str_type_idx), true))  # b data
        _a_data = 2 + length(extra_locals) - 2
        _b_data = 2 + length(extra_locals) - 1
        builder_set_local_type!(b, _a_data, extra_locals[end - 1])
        builder_set_local_type!(b, _b_data, extra_locals[end])
        _str0!(b); local_set!(b, _a_data)
        local_get!(b, 1)
        struct_get!(b, UInt32(get_string_struct_type!(mod, type_registry)), UInt32(2),
                    ConcreteRef(UInt32(str_type_idx), true))
        local_set!(b, _b_data)
        push!(extra_locals, I32)  # len_a
        str_ref_type = ConcreteRef(str_type_idx, true)
        push!(extra_locals, str_ref_type)  # local 3: result array ref
        builder_set_local_type!(b, 4, I32)
        builder_set_local_type!(b, 5, str_ref_type)

        # len_a = array.len(a)
        local_get!(b, _a_data)  # a data
        array_len!(b)
        local_set!(b, 4)  # len_a

        # result = array.new_default(len_a + array.len(b))
        local_get!(b, 4)  # len_a
        local_get!(b, _b_data)  # b data
        array_len!(b)
        num!(b, Opcode.I32_ADD)
        array_new_default!(b, str_type_idx)
        local_set!(b, 5)  # result

        # array.copy(result, 0, a, 0, len_a)
        local_get!(b, 5)  # dst: result
        i32_const!(b, 0)  # dst_offset: 0
        local_get!(b, _a_data)  # src: a data
        i32_const!(b, 0)  # src_offset: 0
        local_get!(b, 4)  # len: len_a
        array_copy!(b, str_type_idx, str_type_idx)  # dst type, src type

        # array.copy(result, len_a, b, 0, array.len(b))
        local_get!(b, 5)  # dst: result
        local_get!(b, 4)  # dst_offset: len_a
        local_get!(b, _b_data)  # src: b data
        i32_const!(b, 0)  # src_offset: 0
        local_get!(b, _b_data)  # b data
        array_len!(b)  # len: array.len(b)
        array_copy!(b, str_type_idx, str_type_idx)  # dst type, src type

        # return result
        local_get!(b, 5)  # result
        push!(extra_locals, ConcreteRef(UInt32(str_type_idx), true))
        _wrap_result_str!(b, 2 + length(extra_locals) - 1)   # 2 params
        end_block!(b)
        return (builder_code(b), extra_locals)

    elseif fname === :str_substr
        # WBUILD-8001: str_substr intrinsic body not implemented.
        # The inline version at call sites properly implements this using
        # array.new + array.copy. This path is only hit when str_substr is
        # called as a standalone function (not inlined at call site).
        unreachable!(b)  # structural trap (dart-legit dead path)
        end_block!(b)
        return (builder_code(b), extra_locals)
    end

    return nothing
end

"""
    compile_module(functions::Vector) -> WasmModule

Compile multiple Julia functions into a single WebAssembly module.

Each element of `functions` should be a tuple of (function, arg_types) or
(function, arg_types, name). If name is omitted, the function's name is used.

# Example
```julia
mod = compile_module([
    (add, (Int32, Int32)),
    (sub, (Int32, Int32)),
    (mul, (Int32, Int32), "multiply"),
])
```

Functions can call each other within the module.
"""
function _compile_closed_world_plan(functions::Vector;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false
                        )
    # This private entry receives only a complete plan produced by
    # `trim_compile_plan`. It never discovers or silently adds functions.
    # Create WasmInterpreter with overlay method table (GPUCompiler pattern).
    # Must be created here (after user functions exist) so world age is current.
    interp = get_wasm_interpreter()

    # Filter out any discovered functions that are import stubs
    # (import stubs are registered in func_registry at their import indices, not compiled)
    if !isempty(import_stubs)
        import_stub_funcs = Set{Any}(entry[1] for entry in import_stubs)
        functions = filter(entry -> !(entry isa Tuple && entry[1] in import_stub_funcs), functions)
    end

    # Create shared module and registries (or use existing module)
    if existing_module !== nothing
        mod = existing_module
    else
        # SOUNDNESS: reset all per-module task-local caches BEFORE building a fresh
        # module. These are cleared on the success path at end-of-module (below), but
        # NOT in a finally — so a PRIOR compile that threw before reaching the clears
        # leaks a stale type/func index into this fresh module. The PI pipeline compiles
        # many cells in one task with many throwing compiles, so the stale
        # `_CHAR_ARRAY_TYPE_IDX` (i16-char-array index) got baked into this module's
        # `utf8_to_js` helper as `array.new_default <stale>`, where that slot is now the
        # `fromCharCodeArray` *func* type → "expected array type at index N, found (func …)".
        # Clearing at the start of every fresh-module build makes each compile leak-proof.
        clear_io_imports!()
        clear_rng_globals!()
        clear_perf_now!()
        clear_char_array_type!()
        clear_utf8_to_js_func!()
        mod = WasmModule()
    end
    type_registry = TypeRegistry()
    func_registry = FunctionRegistry()

    # PURE-9026: Create base struct type FIRST — all other structs will be subtypes
    get_base_struct_type!(mod, type_registry)

    # Pre-register import stubs at their import indices in func_registry.
    # This enables compiled functions to call imports via cross-function call resolution.
    for entry in import_stubs
        func_ref, name, arg_types, wasm_idx, return_type = entry
        register_function!(func_registry, name, func_ref, arg_types, UInt32(wasm_idx), return_type)
    end

    # PURE-325: Pre-register numeric box types for all common numeric Wasm types.
    # These are needed when functions with ExternRef return types (heterogeneous Unions)
    # need to return numeric values. Pre-registering avoids compilation order issues
    # where the caller's isa() check is compiled before the callee's box type exists.
    for nt in (I32, I64, F32, F64)
        get_numeric_box_type!(mod, type_registry, nt)
    end
    # PURE-9028: Pre-register BoxedNothing type
    get_nothing_box_type!(mod, type_registry)

    # Normalize input: ensure each entry is (func, arg_types, name)
    normalized = []
    for entry in functions
        if length(entry) == 2
            f, arg_types = entry
            name = string(nameof(f))
            push!(normalized, (f, arg_types, name))
        else
            push!(normalized, entry)
        end
    end

    # PURE-9040/9041: Scan all functions for println/print/show usage and add IO imports if needed
    needs_io = false
    for (f, arg_types, fname) in normalized
        try
            ci, _ = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)
            for stmt in ci.code
                if stmt isa Expr && (stmt.head === :invoke || stmt.head === :call)
                    func_arg = stmt.head === :invoke ? stmt.args[2] : stmt.args[1]
                    if func_arg isa GlobalRef && (func_arg.name === :println || func_arg.name === :print || func_arg.name === :show)
                        needs_io = true
                        break
                    end
                end
            end
        catch
            # If IR fails, skip — the main compilation loop will handle errors
        end
        needs_io && break
    end
    if needs_io
        io_imports = add_io_imports!(mod, type_registry)
        set_io_imports!(io_imports)
    else
        clear_io_imports!()
    end

    # PURE-9043: Scan for jl_get_current_task (rand() usage) and add RNG globals if needed
    needs_rng = false
    for (f, arg_types, fname) in normalized
        try
            ci, _ = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)
            for stmt in ci.code
                if stmt isa Expr && stmt.head === :foreigncall
                    fc_name_sym = extract_foreigncall_name(stmt.args[1])
                    if fc_name_sym === :jl_get_current_task
                        needs_rng = true
                        break
                    end
                end
            end
        catch
        end
        needs_rng && break
    end
    if needs_rng
        ensure_rng_globals!(mod)
    else
        clear_rng_globals!()
    end

    # Track all required globals across all functions
    required_globals = Dict{Int, Tuple{WasmValType, Type}}()  # global_idx -> (wasm_type, julia_elem_type)

    # First pass: register types, detect WasmGlobals, and reserve function slots
    # We need to know all function indices before compiling bodies
    function_data = []  # Store (f, arg_types, name, code_info, return_type, global_args) for each function

    for (f, arg_types, name) in normalized
        # Check if this is a closure (function with captured variables)
        # march16: a TYPE-KEYED entry (f IS the closure DataType — capturing
        # closures have no instance) resolves IR by ftype, and the closure type
        # is f itself, not typeof(f).
        local _type_keyed_closure = f isa DataType && is_closure_type(f)
        closure_type = _type_keyed_closure ? f : typeof(f)
        is_closure = is_closure_type(closure_type)

        # Get typed IR using the ORIGINAL arg_types (without closure type prepend).
        # Base.code_typed already knows the first slot is typeof(f) for closures.
        # (type-keyed closures resolve via the TRIM_IR_CACHE hit — trimcollect
        # cached their pair under (T, arg_types); a miss errors loudly.)
        code_info, return_type = get_typed_ir(f, arg_types; optimize=optimize_ir, interp=interp)

        if is_closure
            # Prepend the closure type to arg_types for type registration and WASM codegen
            arg_types = (closure_type, arg_types...)
        end

        # Detect WasmGlobal arguments
        global_args = Set{Int}()
        for (i, T) in enumerate(arg_types)
            if T <: WasmGlobal
                push!(global_args, i)
                elem_type = global_eltype(T)
                wasm_type = julia_to_wasm_type(elem_type)
                global_idx = global_index(T)
                required_globals[global_idx] = (wasm_type, elem_type)
            end
        end

        # Register types used in parameters (skip WasmGlobal)
        for (i, T) in enumerate(arg_types)
            if i in global_args
                continue
            end
            if is_closure_type(T)
                register_closure_type!(mod, type_registry, T)
            elseif T === Symbol
                # Symbol is represented as a string (byte array), not a struct
                get_string_struct_type!(mod, type_registry)
            elseif is_struct_type(T)
                register_struct_type!(mod, type_registry, T)
            elseif T <: Vector
                # Vector (1-D only — matrices use register_matrix_type! below)
                register_vector_type!(mod, type_registry, T)
            elseif T <: AbstractVector && T isa DataType
                # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
                register_struct_type!(mod, type_registry, T)
            elseif T <: AbstractArray
                # Multi-dimensional arrays (Matrix, etc.) - register as struct
                register_matrix_type!(mod, type_registry, T)
            elseif T === String
                get_string_struct_type!(mod, type_registry)
            end
        end

        # Register return type
        if is_closure_type(return_type)
            register_closure_type!(mod, type_registry, return_type)
        elseif return_type === Symbol
            # Symbol is represented as a string (byte array), not a struct
            get_string_struct_type!(mod, type_registry)
        elseif is_struct_type(return_type)
            register_struct_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: Vector
            # Vector (1-D only — matrices use register_matrix_type! below)
            register_vector_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: AbstractVector && return_type isa DataType
            # Other AbstractVector types (SubArray, UnitRange, etc.) - register as regular struct
            register_struct_type!(mod, type_registry, return_type)
        elseif return_type !== Union{} && return_type <: AbstractArray
            # Multi-dimensional arrays (Matrix, etc.) - register as struct
            register_matrix_type!(mod, type_registry, return_type)
        elseif return_type === String
            get_string_struct_type!(mod, type_registry)
        end

        push!(function_data, (f, arg_types, name, code_info, return_type, global_args, is_closure))
    end

    # Add all required globals to the module
    for global_idx in sort(collect(keys(required_globals)))
        wasm_type, elem_type = required_globals[global_idx]
        while length(mod.globals) <= global_idx
            add_global!(mod, wasm_type, true, zero(elem_type))
        end
    end

    # Exception objects synthesized by lowering must join the closed component
    # before DFS class IDs freeze; late registration makes catch-side `isa`
    # structurally unable to classify an otherwise real payload.
    for _exn_T in (ErrorException, ArgumentError, OverflowError, DivideError,
                   StackOverflowError, OutOfMemoryError, BoundsError, TypeError,
                   DomainError, InexactError, KeyError, MethodError,
                   AssertionError, UndefVarError)
        register_struct_type!(mod, type_registry, _exn_T)
    end

    # JIB-IR001: Pre-register Core IR types for self-hosting dispatch
    if register_ir_types
        register_core_ir_types!(mod, type_registry)
    end

    # PURE-9063: Create $JlType hierarchy types FIRST (march5 reorder: the closed-world
    # collector below registers structs whose DataType-typed fields must resolve to
    # $JlDataType — pre-hierarchy registration resolved them to a stale struct type,
    # which the Any-only patch pass below can't fix)
    create_jl_type_hierarchy!(mod, type_registry)

    # census F2 (march5): CLOSE THE TYPE UNIVERSE BEFORE NUMBERING — dart numbers the
    # whole component ONCE, before codegen (class_info.dart:583-690). Walk every
    # function's typed IR and COLLECT every reachable concrete struct / union member
    # so the DFS below numbers the closed world (real [low, high] ranges for isa/
    # typeassert). Collection ONLY — no struct registration: eagerly registering
    # changed field-resolution ORDER and produced duplicate layouts (caught by
    # WasmMakie's E-001); numbering needs no wasm struct to exist, and a type
    # registered lazily later receives its pre-assigned id via ensure_type_id!.
    _reachable = _collect_reachable_ir_types(function_data)

    # PURE-9025: Assign DFS type IDs (the closed world = registered + reachable)
    assign_type_ids!(type_registry; extra_concrete_types=_reachable)

    # PURE-9028: Create BoxedNothing singleton global (after type IDs assigned)
    get_nothing_global!(mod, type_registry)

    # PURE-9064: Patch struct types registered before JlType hierarchy existed.
    # Any-typed fields were mapped to ExternRef (since jl_type_idx was nothing).
    # Now that the hierarchy exists, patch them to AnyRef.
    patch_any_fields_for_jltype_hierarchy!(mod, type_registry)

    # PURE-9063: Create DataType globals for ALL types with DFS IDs + type lookup table
    ensure_all_type_globals!(mod, type_registry)
    create_type_lookup_table!(mod, type_registry)

    # PURE-9065: Pre-create string hash helper function if any function uses memhash.
    # This must happen BEFORE function index assignment, because adding functions during
    # body compilation would shift indices and break cross-function calls.
    needs_string_hash = false
    for (_, _, _, code_info, _, _, _) in function_data
        if code_info !== nothing
            for stmt in code_info.code
                if stmt isa Expr && stmt.head === :foreigncall && length(stmt.args) >= 1
                    fc_sym = extract_foreigncall_name(stmt.args[1])
                    if fc_sym === :memhash
                        needs_string_hash = true
                        break
                    end
                end
                # Julia 1.13: hash_bytes replaces memhash foreigncall
                if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 2
                    callee = stmt.args[2]
                    callee_name = callee isa GlobalRef ? callee.name : nothing
                    if callee_name === :hash_bytes
                        needs_string_hash = true
                        break
                    end
                end
            end
        end
        needs_string_hash && break
    end
    if needs_string_hash
        get_or_create_string_hash_func!(mod, type_registry)
    end

    # Pre-create the shared utf8proc property table/helper before function-index
    # assignment. Both category and character width read the same packed byte.
    needs_unicode_properties = false
    for (_, _, _, code_info, _, _, _) in function_data
        code_info === nothing && continue
        for stmt in code_info.code
            if stmt isa Expr && stmt.head === :foreigncall && !isempty(stmt.args)
                fc_sym = extract_foreigncall_name(stmt.args[1])
                if fc_sym in (:utf8proc_category, :utf8proc_charwidth,
                              :jl_id_start_char, :jl_id_char)
                    needs_unicode_properties = true
                    break
                end
            end
        end
        needs_unicode_properties && break
    end
    needs_unicode_properties && get_or_create_unicode_property_func!(mod, type_registry)

    # march7 LAZY constants: collect long (>64B) String/Symbol literals and pre-create
    # their init functions NOW — the same index-freeze constraint (functions cannot be
    # added during body compilation without shifting indices). dart constants.dart:454.
    for (_, _, _, code_info, _, _, _) in function_data
        code_info === nothing && continue
        for stmt in code_info.code
            for lit in (stmt isa Expr ? stmt.args : (stmt,))
                v = lit isa QuoteNode ? lit.value : lit
                if v isa String && ncodeunits(v) > 64
                    get_or_create_lazy_string!(mod, type_registry, v)
                elseif v isa Symbol && ncodeunits(String(v)) > 64
                    get_or_create_lazy_string!(mod, type_registry, String(v))
                end
            end
        end
    end

    # Calculate function indices (accounting for imports + pre-created helper functions)
    # Functions are added in order, so index = n_imports + n_existing + position - 1
    n_imports = length(mod.imports)
    # fullstrict PRE-DECLARED SIGNATURES: the one derivation both the placeholder
    # (registration) and the body fill use — the builder's call! deriver then reads
    # TRUTH for every function from the moment indices exist (the 19 empty-sig call
    # sites + all cross-calls stop guessing; declare-then-define, like an assembler).
    n_existing = length(mod.functions)  # PURE-9065: includes pre-created helper functions
    # T1.1 step 2: discovery-added dynamic-dispatch candidates (beyond the base
    # collection) register as is_candidate=true → visible to the call-site typeId
    # switch (by_ref) but invisible to get_function cross-call resolution.
    _disp_cands = _TRIM_DISPATCH_CANDIDATES[]
    for (i, (f, arg_types, name, _, return_type, global_args, _)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)
        register_function!(func_registry, name, f, arg_types, func_idx, return_type;
                           is_candidate = (!isempty(_disp_cands) && (f, arg_types) in _disp_cands))
        # fullstrict: the PLACEHOLDER carries the true signature from birth
        local _pp, _rr = function_wasm_signature(arg_types, return_type, global_args,
                                                  mod, type_registry)
        local _ft_idx = add_type!(mod, FuncType(WasmValType[p for p in _pp], WasmValType[r for r in _rr]))
        push!(mod.functions, WasmFunction(UInt32(_ft_idx), WasmValType[], UInt8[Opcode.UNREACHABLE, Opcode.END]))
    end

    # march16: THE CLOSURE VTABLE PRE-PASS (the index-freeze rule: nothing
    # may add functions during body compilation). Trampolines + vtable globals for
    # every type-keyed userland closure are created NOW; their bodies' FINAL indices
    # are computable deterministically (bodies start after the K trampolines).
    local _cvp = Tuple{Int, DataType, Bool}[] # (function_data position, callable type, takes context)
    for (i, (f, _, _, _, _, _, _)) in enumerate(function_data)
        if f isa DataType && is_closure_type(f)
            push!(_cvp, (i, f, true))
        elseif f isa Function && typeof(f) in _ENROLLED_CALLABLE_TYPES[]
            push!(_cvp, (i, typeof(f), false))
        end
    end
    if !isempty(_cvp)
        for (_slot, (_i, _T, _takes_context)) in enumerate(_cvp)
            local _entry = function_data[_i]
            local _ats, _rt = _entry[2], _entry[5]
            # fullstrict reorder: the placeholders occupy the body indices ALREADY —
            # the standard formula reads them; trampolines append after.
            local _body_idx = UInt32(n_imports + n_existing + _i - 1)
            local _bps = WasmValType[get_concrete_wasm_type(T2, mod, type_registry) for T2 in _ats]
            local _brs = (_rt === Nothing || _rt === Union{}) ? WasmValType[] :
                         WasmValType[get_concrete_wasm_type(_rt, mod, type_registry)]
            ensure_closure_vtable!(mod, type_registry, _T, _body_idx, _bps, _brs;
                                   body_return_type=_rt, takes_context=_takes_context)
        end
    end



    # PURE-9060: Build dispatch tables for megamorphic functions (>8 specializations)
    # Phase 1: metadata (signatures, globals, tables) — needed by emit_dispatch_call! during body compilation
    dispatch_registry = build_dispatch_tables(func_registry, type_registry)

    if !isempty(dispatch_registry.tables)
        emit_dispatch_metadata!(mod, type_registry, dispatch_registry)
        # parity(M8.2): pack single-axis selectors into the ONE dart table
        pack_dispatch_selectors!(mod, dispatch_registry, type_registry)
    end

    # Track export names to avoid duplicates (WASM requires unique export names)
    export_name_counts = Dict{String, Int}()

    # Second pass: compile function bodies
    for (i, (f, arg_types, name, code_info, return_type, global_args, is_closure)) in enumerate(function_data)
        func_idx = UInt32(n_imports + n_existing + i - 1)
        # Check if this is an intrinsic function that needs special code generation
        intrinsic_body = is_intrinsic_function(f) ? generate_intrinsic_body(f, arg_types, mod, type_registry; return_type=return_type) : nothing

        local body::Vector{UInt8}
        local locals::Vector{WasmValType}

        # PURE-9060: Check if this function is a dispatch caller (calls a megamorphic function
        # with abstract args). If so, generate a direct dispatch body instead of the normal body.
        dispatch_dt = nothing
        if code_info !== nothing && type_registry.base_struct_idx !== nothing &&
           !isempty(dispatch_registry.tables)
            dispatch_dt = find_dispatch_call(code_info, dispatch_registry)
        end

        if intrinsic_body !== nothing
            # Use the intrinsic body directly
            body, locals = intrinsic_body
        elseif dispatch_dt !== nothing
            # PURE-9060: Generate dispatch-only body (probe + call_indirect + return)
            n_params = sum(j -> !(j in global_args) ? 1 : 0, 1:length(arg_types); init=0)
            if haskey(dispatch_registry.selector_offset, dispatch_dt.func_ref)
                # parity(M8.2): the dart virtual call — classId + offset + call_indirect
                body, locals = generate_selector_caller_body(
                    dispatch_dt, dispatch_registry, n_params, type_registry.base_struct_idx;
                    caller_return_type=return_type, mod=mod, type_registry=type_registry)
            else
                body, locals = generate_dispatch_caller_body(
                    dispatch_dt, n_params, type_registry.base_struct_idx, type_registry)
            end
        else
            # Generate function body from Julia IR
            ctx = CompilationContext(code_info, arg_types, return_type, mod, type_registry;
                                    func_registry=func_registry, func_idx=func_idx, func_ref=f,
                                    global_args=global_args, is_compiled_closure=is_closure)
            body = generate_body(ctx)
            locals = ctx.locals
        end

        # fullstrict: FILL the pre-declared placeholder (same signature derivation)
        param_types, result_types = function_wasm_signature(arg_types, return_type, global_args,
                                                             mod, type_registry)
        local _slot = Int(func_idx) - n_imports + 1
        local _ft_idx2 = add_type!(mod, FuncType(WasmValType[p for p in param_types], WasmValType[r for r in result_types]))
        mod.functions[_slot] = WasmFunction(UInt32(_ft_idx2), WasmValType[l for l in locals], body)
        actual_idx = func_idx

        # Export the function with a unique name
        export_name = name
        count = get(export_name_counts, name, 0)
        if count > 0
            export_name = "$(name)_$(count)"
        end
        export_name_counts[name] = count + 1
        add_codegen_export!(mod, export_name, 0, actual_idx)
    end

    # PURE-9060 Phase 2: Add wrapper functions AFTER all actual functions are compiled.
    # This ensures entry.target_idx values (from func_registry) point to correct indices.
    if !isempty(dispatch_registry.tables)
        emit_dispatch_wrappers!(mod, type_registry, dispatch_registry)
    end

    # PURE-9062 Phase 2: Add overlay wrapper functions

    # PURE-4149: Populate DataType/TypeName fields for type constant globals.
    # This creates a start function that patches .name, .super, .parameters, .wrapper.
    populate_type_constant_globals!(mod, type_registry)
    finalize_module_initializers!(mod, type_registry)

    # PURE-9040/9042/9043: Clear module-level state after compilation
    clear_io_imports!()
    clear_rng_globals!()
    clear_perf_now!()
    clear_char_array_type!()
    clear_utf8_to_js_func!()

    if return_registries
        return (mod, type_registry, func_registry, dispatch_registry)
    end
    return mod
end

"""
    compile_module_from_ir(ir_entries::Vector)::WasmModule

Compile pre-computed typed CodeInfo entries to a WasmModule, bypassing Base.code_typed().
Each entry is (code_info::CodeInfo, return_type::Type, arg_types::Tuple, name::String).
Optionally a 5th element func_ref can be provided for cross-function call resolution.

This is the entry point for the eval_julia pipeline where type inference has already been run.
Unlike `compile_module`, this adapter starts from caller-supplied typed IR rather than
running inference, then enters the same closed-world module compiler.
"""
struct _PrecomputedIRKey
    id::Int
end

function compile_module_from_ir(ir_entries::Vector)::WasmModule
    functions = Any[]
    cache = IdDict{Any, Tuple{Core.CodeInfo, Any}}()
    for (i, entry) in enumerate(ir_entries)
        length(entry) >= 4 || throw(ArgumentError(
            "IR entry $i must be (CodeInfo, return_type, arg_types, name[, func_ref])"))
        code_info, return_type, arg_types, name = entry[1], entry[2], entry[3], entry[4]
        code_info isa Core.CodeInfo || throw(ArgumentError("IR entry $i does not contain Core.CodeInfo"))
        arg_types isa Tuple || throw(ArgumentError("IR entry $i arg_types must be a Tuple"))
        key = length(entry) >= 5 && entry[5] !== nothing ? entry[5] : _PrecomputedIRKey(i)
        push!(functions, (key, arg_types, String(name)))
        cache[(key, arg_types)] = (code_info, return_type)
    end

    previous = TRIM_IR_CACHE[]
    TRIM_IR_CACHE[] = cache
    try
        return _compile_closed_world_plan(functions)
    finally
        TRIM_IR_CACHE[] = previous
    end
end

# ============================================================================
# GlobalRef Pre-Resolution — Self-hosting support
# ============================================================================

"""
    collect_globalrefs(code_info::Core.CodeInfo) -> Set{GlobalRef}

Walk a CodeInfo and collect all unique GlobalRef values from statements
and expression arguments. Used at build time to discover all module-level
references that need to be pre-resolved for self-hosting.
"""
function collect_globalrefs(code_info::Core.CodeInfo)
    refs = Set{GlobalRef}()
    for stmt in code_info.code
        _scan_globalrefs!(refs, stmt)
    end
    return refs
end

function _scan_globalrefs!(refs::Set{GlobalRef}, val)
    if val isa GlobalRef
        push!(refs, val)
    elseif val isa Expr
        for arg in val.args
            _scan_globalrefs!(refs, arg)
        end
    end
end

"""
    resolve_globalrefs(refs::Set{GlobalRef}) -> Dict{GlobalRef, Any}

Resolve each GlobalRef to its build-time value using getfield.
Unresolvable refs are skipped (they may be forward declarations, etc).
"""
function resolve_globalrefs(refs::Set{GlobalRef})
    resolved = Dict{GlobalRef, Any}()
    for ref in refs
        try
            resolved[ref] = getfield(ref.mod, ref.name)
        catch
            # Skip unresolvable refs
        end
    end
    return resolved
end

"""
    collect_and_resolve_all_globalrefs(ir_entries::Vector) -> Dict{GlobalRef, Any}

Collect and resolve ALL GlobalRefs across multiple IR entries at build time.
This is the main entry point for Phase 1 self-hosting: eliminates all
getfield(Module, Symbol) calls from the CodeInfo before it's sent to the browser.
"""
function collect_and_resolve_all_globalrefs(ir_entries::Vector)
    all_refs = Set{GlobalRef}()
    for entry in ir_entries
        code_info = entry[1]  # First element is CodeInfo
        union!(all_refs, collect_globalrefs(code_info))
    end
    return resolve_globalrefs(all_refs)
end

"""
    substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any}) -> Core.CodeInfo

Create a copy of CodeInfo with all GlobalRef values replaced by their
pre-resolved values. After substitution, the CodeInfo contains no
module-level references and can be compiled without access to Julia modules.
"""
function substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any})
    new_ci = copy(code_info)
    new_code = Any[]
    for stmt in new_ci.code
        push!(new_code, _substitute_globalref(stmt, resolved))
    end
    new_ci.code = new_code
    return new_ci
end

function _substitute_globalref(val, resolved::Dict{GlobalRef, Any})
    if val isa GlobalRef
        return get(resolved, val, val)
    elseif val isa Expr
        new_args = Any[_substitute_globalref(arg, resolved) for arg in val.args]
        return Expr(val.head, new_args...)
    end
    return val
end

"""
    preprocess_ir_entries(ir_entries::Vector) -> Vector

Pre-resolve all GlobalRefs in IR entries. Returns new entries with substituted
CodeInfo that contain no module-level references. This is the build-time
preprocessing step for self-hosted compilation.
"""
function preprocess_ir_entries(ir_entries::Vector)
    resolved = collect_and_resolve_all_globalrefs(ir_entries)
    result = []
    for (code_info, return_type, arg_types, name) in ir_entries
        sub_ci = substitute_globalrefs(code_info, resolved)
        push!(result, (sub_ci, return_type, arg_types, name))
    end
    return result
end

# ============================================================================
# Browser byte-vector accessors. These are ordinary Julia functions compiled through
# the canonical closed-world pipeline when an embedder requests them; they are not
# a compiler or serializer path.
wasm_bytes_length(v::Vector{UInt8})::Int32 = Int32(length(v))
wasm_bytes_get(v::Vector{UInt8}, i::Int32)::Int32 = Int32(v[i])

# ============================================================================
# CodeInfo Transport — Phase 1 self-hosting (PHASE-1-009)
# ============================================================================
# Serialize CodeInfo + metadata to JSON for server→browser transport.
# The browser deserializes and passes to compile_module_from_ir to produce WASM.
#
# Flow: server code_typed → preprocess_ir_entries → serialize → HTTP →
#       browser deserialize → compile_module_from_ir → to_bytes → execute

import JSON

"""
    serialize_ir_value(val) -> Any

Serialize a single IR value (Expr arg, PhiNode value, etc.) to a JSON-safe Dict.
"""
function serialize_ir_value(val)
    if val isa Core.SSAValue
        return Dict("_t" => "ssa", "id" => val.id)
    elseif val isa Core.Argument
        return Dict("_t" => "arg", "n" => val.n)
    elseif val isa Core.SlotNumber
        return Dict("_t" => "slot", "id" => val.id)
    elseif val isa Core.IntrinsicFunction
        return Dict("_t" => "intrinsic", "name" => string(nameof(val)))
    elseif val isa GlobalRef
        return Dict("_t" => "globalref", "mod" => string(val.mod), "name" => string(val.name))
    elseif val isa QuoteNode
        return Dict("_t" => "quote", "value" => serialize_ir_value(val.value))
    elseif val isa Symbol
        return Dict("_t" => "symbol", "name" => string(val))
    elseif val isa Bool
        # Bool before Int because Bool <: Integer
        return Dict("_t" => "lit", "jt" => "Bool", "v" => val)
    elseif val isa Int64
        return Dict("_t" => "lit", "jt" => "Int64", "v" => val)
    elseif val isa Int32
        return Dict("_t" => "lit", "jt" => "Int32", "v" => Int64(val))
    elseif val isa UInt64
        return Dict("_t" => "lit", "jt" => "UInt64", "v" => Int64(val))
    elseif val isa UInt32
        return Dict("_t" => "lit", "jt" => "UInt32", "v" => Int64(val))
    elseif val isa Float64
        return Dict("_t" => "lit", "jt" => "Float64", "v" => val)
    elseif val isa Float32
        return Dict("_t" => "lit", "jt" => "Float32", "v" => Float64(val))
    elseif val === nothing
        return Dict("_t" => "nothing")
    elseif val isa Type
        return Dict("_t" => "type", "name" => serialize_type_name(val))
    elseif val isa Expr
        return serialize_ir_stmt(val)
    elseif val isa Core.Builtin
        return Dict("_t" => "builtin", "name" => string(nameof(val)))
    elseif val isa Function
        mod = parentmodule(val)
        return Dict("_t" => "function", "name" => string(nameof(val)), "mod" => string(mod))
    elseif val isa Core.MethodInstance
        sig = val.specTypes
        func_name = string(sig.parameters[1].instance)
        arg_types = [serialize_type_name(p) for p in sig.parameters[2:end]]
        return Dict("_t" => "method_instance", "func" => func_name, "sig" => arg_types)
    elseif isdefined(Core, :CodeInstance) && val isa Core.CodeInstance
        mi = val.def
        sig = mi.specTypes
        func_name = string(sig.parameters[1].instance)
        arg_types = [serialize_type_name(p) for p in sig.parameters[2:end]]
        return Dict("_t" => "code_instance", "func" => func_name, "sig" => arg_types)
    else
        return Dict("_t" => "opaque", "repr" => repr(val), "jt" => string(typeof(val)))
    end
end

"""
    serialize_ir_stmt(stmt) -> Any

Serialize a single IR statement to a JSON-safe structure.
"""
function serialize_ir_stmt(stmt)
    if stmt isa Expr
        return Dict("_t" => "expr", "head" => string(stmt.head),
                     "args" => [serialize_ir_value(a) for a in stmt.args])
    elseif stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            return Dict("_t" => "return", "val" => serialize_ir_value(stmt.val))
        else
            return Dict("_t" => "return")
        end
    elseif stmt isa Core.GotoNode
        return Dict("_t" => "goto", "label" => stmt.label)
    elseif stmt isa Core.GotoIfNot
        return Dict("_t" => "gotoifnot", "cond" => serialize_ir_value(stmt.cond),
                     "dest" => stmt.dest)
    elseif stmt isa Core.PhiNode
        vals = []
        for i in 1:length(stmt.values)
            if isassigned(stmt.values, i)
                push!(vals, serialize_ir_value(stmt.values[i]))
            else
                push!(vals, Dict("_t" => "undef"))
            end
        end
        return Dict("_t" => "phi", "edges" => Int64.(stmt.edges), "values" => vals)
    elseif stmt isa Core.PiNode
        return Dict("_t" => "pi", "val" => serialize_ir_value(stmt.val),
                     "typ" => serialize_type_name(stmt.typ))
    elseif stmt isa Core.NewvarNode
        return Dict("_t" => "newvar", "slot" => stmt.slot.id)
    elseif stmt isa GlobalRef
        # PHASE-2-INT-001: GlobalRef appears as standalone stmt in lowered IR
        return Dict("_t" => "globalref_stmt", "mod" => string(stmt.mod), "name" => string(stmt.name))
    elseif stmt isa Core.SlotNumber
        # PHASE-2-INT-001: SlotNumber appears as standalone stmt in lowered IR
        return Dict("_t" => "slot", "id" => stmt.id)
    elseif stmt === nothing
        return Dict("_t" => "nothing")
    else
        return Dict("_t" => "opaque", "repr" => repr(stmt), "jt" => string(typeof(stmt)))
    end
end

"""
    serialize_type_name(T) -> String

Convert a Julia type to a string representation for JSON transport.
"""
function serialize_type_name(T)
    T === Int64 && return "Int64"
    T === Int32 && return "Int32"
    T === UInt64 && return "UInt64"
    T === UInt32 && return "UInt32"
    T === Float64 && return "Float64"
    T === Float32 && return "Float32"
    T === Bool && return "Bool"
    T === Nothing && return "Nothing"
    T === String && return "String"
    T === Symbol && return "Symbol"
    T === Any && return "Any"
    T === Union{} && return "Union{}"
    return string(T)
end

"""
    serialize_ssa_type(t) -> Any

Serialize an SSA value type or slot type entry (may be Type or Core.Const).
"""
function serialize_ssa_type(t)
    if t isa Core.Const
        val = t.val
        if val isa Core.IntrinsicFunction
            return Dict("_t" => "const", "val" => Dict("_t" => "intrinsic", "name" => string(nameof(val))),
                         "jt" => "Core.IntrinsicFunction")
        elseif val isa Core.Builtin
            return Dict("_t" => "const", "val" => Dict("_t" => "builtin", "name" => string(nameof(val))),
                         "jt" => "Core.Builtin")
        elseif val isa Function
            # User-defined functions: store just the type (codegen only needs the type)
            return serialize_type_name(typeof(val))
        else
            return Dict("_t" => "const", "val" => serialize_ir_value(val),
                         "jt" => serialize_type_name(typeof(val)))
        end
    elseif t isa Type
        return serialize_type_name(t)
    else
        return Dict("_t" => "opaque_type", "repr" => repr(t))
    end
end

"""
    serialize_ir_entries(ir_entries::Vector) -> String

Serialize preprocessed IR entries to a JSON string for transport.
Each entry is (code_info, return_type, arg_types, func_name).

Call preprocess_ir_entries FIRST to resolve GlobalRefs before serialization.
"""
function serialize_ir_entries(ir_entries::Vector)::String
    entries = []
    for (code_info, return_type, arg_types, name) in ir_entries
        entry = Dict(
            "name" => name,
            "arg_types" => [serialize_type_name(T) for T in arg_types],
            "return_type" => serialize_type_name(return_type),
            "code" => [serialize_ir_stmt(stmt) for stmt in code_info.code],
            # PHASE-2-INT-001: Handle lowered IR where ssavaluetypes is an Int (count)
            "ssavaluetypes" => code_info.ssavaluetypes isa Integer ?
                code_info.ssavaluetypes :
                [serialize_ssa_type(t) for t in code_info.ssavaluetypes],
            "slottypes" => code_info.slottypes !== nothing ?
                [serialize_ssa_type(t) for t in code_info.slottypes] : nothing,
            "slotnames" => [string(s) for s in code_info.slotnames],
            "ssaflags" => Int64.(code_info.ssaflags),
            "slotflags" => Int64.(code_info.slotflags),
        )
        push!(entries, entry)
    end
    return JSON.json(Dict("version" => 1, "entries" => entries))
end

# ---- Deserialization ----

const _TYPE_MAP = Dict{String, Type}(
    "Int64" => Int64, "Int32" => Int32, "UInt64" => UInt64, "UInt32" => UInt32,
    "Float64" => Float64, "Float32" => Float32, "Bool" => Bool,
    "Nothing" => Nothing, "String" => String, "Symbol" => Symbol,
    "Any" => Any, "Union{}" => Union{},
)

"""
    deserialize_type_name(s::AbstractString) -> Type

Reconstruct a Julia type from its serialized string name.
"""
function deserialize_type_name(s::AbstractString)::Type
    haskey(_TYPE_MAP, s) && return _TYPE_MAP[s]
    try
        return Core.eval(Main, Meta.parse(s))
    catch
        return Any
    end
end

"""
    deserialize_ir_value(d) -> Any

Reconstruct a Julia IR value from its JSON representation.
"""
function deserialize_ir_value(d)
    d isa Bool && return d
    d isa AbstractString && return d
    d isa Number && return d
    !isa(d, Dict) && return d

    tag = get(d, "_t", "")
    if tag == "ssa"
        return Core.SSAValue(d["id"])
    elseif tag == "arg"
        return Core.Argument(d["n"])
    elseif tag == "intrinsic"
        return getfield(Core.Intrinsics, Symbol(d["name"]))
    elseif tag == "builtin"
        return getfield(Core, Symbol(d["name"]))
    elseif tag == "function"
        mod_str = get(d, "mod", "Main")
        mod = mod_str == "Core" ? Core : mod_str == "Base" ? Base : Main
        name = Symbol(d["name"])
        try
            return getfield(mod, name)
        catch
            # Fallback: try Base then Main
            for m in (Base, Main)
                try return getfield(m, name) catch end
            end
            return GlobalRef(mod, name)
        end
    elseif tag == "globalref"
        mod = d["mod"] == "Core" ? Core : d["mod"] == "Base" ? Base : Main
        return GlobalRef(mod, Symbol(d["name"]))
    elseif tag == "quote"
        return QuoteNode(deserialize_ir_value(d["value"]))
    elseif tag == "symbol"
        return Symbol(d["name"])
    elseif tag == "lit"
        jt = d["jt"]
        v = d["v"]
        jt == "Int64" && return Int64(v)
        jt == "Int32" && return Int32(v)
        jt == "UInt64" && return UInt64(v)
        jt == "UInt32" && return UInt32(v)
        jt == "Float64" && return Float64(v)
        jt == "Float32" && return Float32(v)
        jt == "Bool" && return Bool(v)
        return v
    elseif tag == "nothing"
        return nothing
    elseif tag == "type"
        return deserialize_type_name(d["name"])
    elseif tag == "expr"
        return deserialize_ir_stmt(d)
    elseif tag == "slot"
        return Core.SlotNumber(d["id"])
    elseif tag == "method_instance" || tag == "code_instance"
        # Reconstruct MethodInstance from function name + arg types
        func_name = d["func"]
        arg_types = Tuple(deserialize_type_name.(d["sig"]))
        try
            func = Core.eval(Main, Meta.parse(func_name))
            sig = Tuple{typeof(func), arg_types...}
            mi = Base.method_instances(func, arg_types)[1]
            if tag == "code_instance" && isdefined(Core, :CodeInstance)
                # For CodeInstance, wrap the MI
                ci_typed = Base.code_typed(func, arg_types)[1]
                # Just return the MI — the codegen handles both MI and CI
                return mi
            end
            return mi
        catch
            # If we can't reconstruct the MI, return nothing — codegen will handle
            return nothing
        end
    elseif tag == "undef"
        return nothing
    else
        error("Unknown IR value tag: $tag")
    end
end

"""
    deserialize_ir_stmt(d::Dict) -> Any

Reconstruct a Julia IR statement from its JSON representation.
"""
function deserialize_ir_stmt(d::Dict)
    tag = d["_t"]
    if tag == "expr"
        head = Symbol(d["head"])
        args = Any[deserialize_ir_value(a) for a in d["args"]]
        return Expr(head, args...)
    elseif tag == "return"
        if haskey(d, "val")
            return Core.ReturnNode(deserialize_ir_value(d["val"]))
        else
            return Core.ReturnNode()
        end
    elseif tag == "goto"
        return Core.GotoNode(d["label"])
    elseif tag == "gotoifnot"
        return Core.GotoIfNot(deserialize_ir_value(d["cond"]), d["dest"])
    elseif tag == "phi"
        edges = Int32.(d["edges"])
        vals = Any[deserialize_ir_value(v) for v in d["values"]]
        return Core.PhiNode(edges, vals)
    elseif tag == "pi"
        return Core.PiNode(deserialize_ir_value(d["val"]),
                           deserialize_type_name(d["typ"]))
    elseif tag == "newvar"
        return Core.NewvarNode(Core.SlotNumber(d["slot"]))
    elseif tag == "globalref_stmt"
        # PHASE-2-INT-001: GlobalRef as standalone stmt (lowered IR)
        mod = d["mod"] == "Core" ? Core : d["mod"] == "Base" ? Base : Main
        return GlobalRef(mod, Symbol(d["name"]))
    elseif tag == "slot"
        # PHASE-2-INT-001: SlotNumber as standalone stmt (lowered IR)
        return Core.SlotNumber(d["id"])
    elseif tag == "nothing"
        return nothing
    else
        error("Unknown IR statement tag: $tag")
    end
end

"""
    deserialize_ssa_type(d) -> Any

Reconstruct an SSA/slot type entry from its JSON representation.
"""
function deserialize_ssa_type(d)
    if d isa AbstractString
        return deserialize_type_name(d)
    elseif d isa Dict
        tag = get(d, "_t", "")
        if tag == "const"
            val = deserialize_ir_value(d["val"])
            return Core.Const(val)
        end
    end
    return Any
end

"""
    _make_template_codeinfo() -> Core.CodeInfo

Get a template CodeInfo that can be copied and modified for deserialization.
"""
function _make_template_codeinfo()
    _noop() = nothing
    ci, _ = Base.code_typed(_noop, (); optimize=true)[1]
    return ci
end

"""
    deserialize_ir_entries(json_str::String) -> Vector{Tuple}

Deserialize a JSON string back to IR entries for compile_module_from_ir.
Returns Vector of (CodeInfo, return_type, arg_types, name) tuples.
"""
function deserialize_ir_entries(json_str::String)
    data = JSON.parse(json_str)
    version = get(data, "version", 0)
    version == 1 || error("Unsupported CodeInfo transport version: $version")

    template = _make_template_codeinfo()
    result = []

    for entry in data["entries"]
        ci = copy(template)
        ci.code = Any[deserialize_ir_stmt(s) for s in entry["code"]]
        # PHASE-2-INT-001: Handle lowered IR where ssavaluetypes is an Int (count)
        if entry["ssavaluetypes"] isa Integer
            ci.ssavaluetypes = entry["ssavaluetypes"]
        else
            ci.ssavaluetypes = Any[deserialize_ssa_type(t) for t in entry["ssavaluetypes"]]
        end
        if entry["slottypes"] !== nothing
            ci.slottypes = Any[deserialize_ssa_type(t) for t in entry["slottypes"]]
        end
        ci.slotnames = Symbol[Symbol(s) for s in entry["slotnames"]]
        ci.ssaflags = UInt32.(entry["ssaflags"])
        ci.slotflags = UInt8.(entry["slotflags"])

        return_type = deserialize_type_name(entry["return_type"])
        arg_types = Tuple(deserialize_type_name.(entry["arg_types"]))
        name = entry["name"]

        push!(result, (ci, return_type, arg_types, name))
    end

    return result
end

# The sole module pipeline: collect one closed world, install its paired typed-IR
# cache for the duration of codegen, then compile that immutable plan. Public
# entry points may normalize inputs, but none may bypass this collector.
function _compile_module_trim(functions::Vector; kwargs...)
    normalized = Any[]
    for entry in functions
        if length(entry) == 2
            f, arg_types = entry
            push!(normalized, (f, arg_types, string(nameof(f))))
        else
            push!(normalized, entry)
        end
    end
    plan, ir_cache = trim_compile_plan(normalized)
    TRIM_IR_CACHE[] = ir_cache
    try
        return _compile_closed_world_plan(plan; kwargs...)
    finally
        TRIM_IR_CACHE[] = nothing
    end
end

function compile_module(functions::Vector;
                        existing_module::Union{WasmModule, Nothing}=nothing,
                        import_stubs::Vector=[],
                        return_registries::Bool=false,
                        optimize_ir::Bool=true,
                        register_ir_types::Bool=false,
                        discovery::Symbol=:trim)
    discovery === :trim || throw(ArgumentError(
        "only the closed-world compilation path is supported (discovery=:trim)"))
    return _compile_module_trim(functions;
        existing_module, import_stubs, return_registries,
        optimize_ir, register_ir_types)
end

"""
    _collect_reachable_ir_types(function_data) -> Set{DataType}

census F2 (march5) — the CLOSED-WORLD type collector (dart class_info.dart:583-690:
number every class of the component once, before codegen). Walks every function's
typed-IR ssa/arg/return types and decomposes Unions, returning the concrete struct
types reachable from the IR so `assign_type_ids!` numbers the whole world in one
DFS. PURE COLLECTION — registration stays lazy (eager registration reorders field
resolution and forks layouts); a collected type registered later receives its
pre-assigned id via `ensure_type_id!`.
"""
function _collect_reachable_ir_types(function_data)::Set{DataType}
    out = Set{DataType}()
    seen = Set{Any}()
    function reg!(@nospecialize(T))
        T === nothing && return
        T in seen && return
        push!(seen, T)
        if T isa Union
            reg!(T.a); reg!(T.b)
            return
        end
        T isa DataType || return
        if T <: Type && T !== Type && length(T.parameters) == 1
            reg!(T.parameters[1])
            return
        end
        # exclude what WT represents as NON-structs: Memory/MemoryRef lower to
        # wasm arrays (an id here admits them as dispatch candidates whose
        # wrappers then have no struct to cast to — the _la_sub regression)
        if isconcretetype(T) && isstructtype(T) &&
           (!(T <: Function) || T in _ENROLLED_CALLABLE_TYPES[]) && T !== Core.Box &&
           !(T <: GenericMemory) && !(T <: Core.GenericMemoryRef)
            push!(out, T)
        end
    end
    for fd in function_data
        code_info = fd[4]
        code_info === nothing && continue
        for at in fd[2]
            reg!(at isa Type ? at : typeof(at))
        end
        reg!(fd[5])
        ssats = code_info.ssavaluetypes
        if ssats isa Vector
            for t in ssats
                reg!(Core.Compiler.widenconst(t))
            end
        end
    end
    return out
end
# Julia may discover several specialized functions with the same source-level name.
# Name disambiguation is a CODEGEN policy; the low-level module builder, like dart's
# ExportsBuilder, rejects duplicate names instead of silently repairing the request.
function add_codegen_export!(mod::WasmModule, name::String, kind::Integer, idx::Integer)
    final = name
    if any(e -> e.name == final, mod.exports)
        local k = 2
        while any(e -> e.name == string(name, "_d", k), mod.exports)
            k += 1
        end
        final = string(name, "_d", k)
    end
    return add_export!(mod, final, kind, idx)
end
