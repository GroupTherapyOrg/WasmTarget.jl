# ============================================================================
# String IO — wasm:text-decoder / wasm:text-encoder Imports
# ============================================================================

"""
    add_string_io_imports!(mod, type_registry) -> (decode_idx, encode_idx)

Add `wasm:text-decoder.decodeStringFromUTF8Array` and
`wasm:text-encoder.encodeStringToUTF8Array` imports to the module.

These are JS String Builtins that convert between WasmGC `(array (mut i8))`
UTF-8 byte arrays and JS strings (externref). They are provided automatically
by engines compiled with `builtins: ["js-string"]`, or can be polyfilled.

Returns a named tuple `(decode_idx, encode_idx)` with the import function indices.
"""
function add_string_io_imports!(mod::WasmModule, type_registry::TypeRegistry)
    # Ensure string array type is registered (needed for ConcreteRef in signatures)
    str_arr_type_idx = get_string_array_type!(mod, type_registry)
    str_arr_ref_nullable = ConcreteRef(str_arr_type_idx, true)   # (ref null $str_arr)
    str_arr_ref_nonnull = ConcreteRef(str_arr_type_idx, false)   # (ref $str_arr)

    # decodeStringFromUTF8Array: (ref null (array (mut i8)), i32, i32) → (ref extern)
    # V8 requires non-null (ref extern) return type, not nullable externref
    decode_idx = add_import!(mod, "wasm:text-decoder", "decodeStringFromUTF8Array",
        WasmValType[str_arr_ref_nullable, I32, I32],
        WasmValType[NonNullExternRef])

    # encodeStringToUTF8Array: (externref) → (ref (array (mut i8)))
    encode_idx = add_import!(mod, "wasm:text-encoder", "encodeStringToUTF8Array",
        WasmValType[ExternRef],
        WasmValType[str_arr_ref_nonnull])

    return (decode_idx=decode_idx, encode_idx=encode_idx)
end

"""
    emit_jl_string_to_js(bytes, decode_func_idx)

Emit bytecode to convert a Julia string (WasmGC i8 array on stack) to a JS string (externref).

**Stack effect:** `[(ref \$str_arr)] → [externref]`

Emits: `local.tee \$tmp; i32.const 0; local.get \$tmp; array.len; call \$decode`

Note: Caller must ensure a scratch local is available for tee-ing the array ref.
This function takes `tmp_local` as the index of that scratch local.
"""
function emit_jl_string_to_js!(bytes::Vector{UInt8}, decode_func_idx::UInt32, tmp_local::UInt32)
    # Stack: [str_arr_ref]
    # We need: [str_arr_ref, 0, str_arr_ref.len]
    # Tee the array ref so we can get its length
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(tmp_local))

    # Push offset = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)

    # Push length = array.len
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(tmp_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)

    # Call decodeStringFromUTF8Array(array, offset, length) → externref
    push!(bytes, Opcode.CALL)
    append!(bytes, encode_leb128_unsigned(decode_func_idx))
end

"""
    emit_js_to_jl_string!(bytes, encode_func_idx)

Emit bytecode to convert a JS string (externref on stack) to a Julia string (WasmGC i8 array).

**Stack effect:** `[externref] → [(ref \$str_arr)]`
"""
function emit_js_to_jl_string!(bytes::Vector{UInt8}, encode_func_idx::UInt32)
    # Stack: [externref]
    # Call encodeStringToUTF8Array(externref) → (ref $str_arr)
    push!(bytes, Opcode.CALL)
    append!(bytes, encode_leb128_unsigned(encode_func_idx))
end

# ============================================================================
# Stack Trace Support — JS new Error().stack Import
# ============================================================================

"""
    add_stack_trace_import!(mod) -> func_idx

Add a `capture_stack` import that returns an externref containing the JS
stack trace string from `new Error().stack`. Used for backtrace support
in exception handling.

Returns the import function index.
"""
function add_stack_trace_import!(mod::WasmModule)
    # capture_stack: () → externref
    func_idx = add_import!(mod, "env", "capture_stack",
        WasmValType[],
        WasmValType[ExternRef])
    return func_idx
end

"""
    ensure_stack_trace_global!(mod) -> global_idx

Ensure a module-level `\$current_stack_trace (mut externref)` global exists.
Returns the global index.
"""
function ensure_stack_trace_global!(mod::WasmModule)
    # Check if already added
    for (i, g) in enumerate(mod.globals)
        if g.valtype === ExternRef && g.mutable
            return UInt32(i - 1)
        end
    end
    # Add new global: (global $current_stack_trace (mut externref) ref.null extern)
    init_expr = UInt8[0xD0, 0x6F, 0x0B]  # ref.null extern, end
    idx = add_global!(mod, ExternRef, true, init_expr)
    return idx
end

# ============================================================================
# IO Bridge — println/print via JS Imports
# ============================================================================

"""
PURE-9040: IO import indices stored in the module for println/print support.
"""
mutable struct IOImports
    write_string_idx::UInt32    # io.write_string(externref) → void
    write_int_idx::UInt32       # io.write_int(i64) → void
    write_float_idx::UInt32     # io.write_float(f64) → void
    write_bool_idx::UInt32      # io.write_bool(i32) → void
    write_newline_idx::UInt32   # io.write_newline() → void
    decode_idx::UInt32          # wasm:text-decoder.decodeStringFromUTF8Array
end

"""
    add_io_imports!(mod, type_registry) -> IOImports

Add IO bridge imports for println/print support.
Imports: io.write_string, io.write_int, io.write_float, io.write_bool, io.write_newline
Also adds wasm:text-decoder import for string conversion.
"""
function add_io_imports!(mod::WasmModule, type_registry::TypeRegistry)
    # String decoder for converting Julia strings to JS strings
    str_arr_type_idx = get_string_array_type!(mod, type_registry)
    str_arr_ref_nullable = ConcreteRef(str_arr_type_idx, true)

    decode_idx = add_import!(mod, "wasm:text-decoder", "decodeStringFromUTF8Array",
        WasmValType[str_arr_ref_nullable, I32, I32],
        WasmValType[NonNullExternRef])

    # IO imports
    write_string_idx = add_import!(mod, "io", "write_string",
        WasmValType[ExternRef], WasmValType[])
    write_int_idx = add_import!(mod, "io", "write_int",
        WasmValType[I64], WasmValType[])
    write_float_idx = add_import!(mod, "io", "write_float",
        WasmValType[F64], WasmValType[])
    write_bool_idx = add_import!(mod, "io", "write_bool",
        WasmValType[I32], WasmValType[])
    write_newline_idx = add_import!(mod, "io", "write_newline",
        WasmValType[], WasmValType[])

    return IOImports(write_string_idx, write_int_idx, write_float_idx,
                     write_bool_idx, write_newline_idx, decode_idx)
end

# Module-level storage for IO imports (set during compile_module if println/print is used)
const _IO_IMPORTS = Ref{Union{Nothing, IOImports}}(nothing)

"""
    get_io_imports() -> Union{Nothing, IOImports}

Get the current IO imports, or nothing if not initialized.
"""
function get_io_imports()
    return _IO_IMPORTS[]
end

"""
    set_io_imports!(imports::IOImports)

Store IO imports for use during compilation.
"""
function set_io_imports!(imports::IOImports)
    _IO_IMPORTS[] = imports
end

"""
    clear_io_imports!()

Clear IO imports after compilation.
"""
function clear_io_imports!()
    _IO_IMPORTS[] = nothing
end

# ============================================================================
# String Operations
# ============================================================================

"""
Compile string concatenation (str1 * str2).
Creates a new string array with combined contents.
Uses locals for intermediate values.
"""
function compile_string_concat(str1, str2, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    # Get string array type index
    str_type_idx = ctx.type_registry.string_array_idx

    # We need 4 locals: str1_ref, str2_ref, len1, len2
    # Allocate them (these are temporary locals for this operation)
    base_local = length(ctx.code_info.slotnames) + length(ctx.ssa_locals) + length(ctx.phi_locals)
    str1_local = base_local
    str2_local = base_local + 1
    len1_local = base_local + 2
    len2_local = base_local + 3

    # Add the locals to the function (string refs and i32s for lengths)
    # Note: We're using ConcreteRef for string arrays
    # For simplicity, we'll store lengths as i32 directly

    # Compile str1, store in local
    append!(bytes, compile_value(str1, ctx))
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(str1_local))

    # Get len1
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len1_local))

    # Compile str2, store in local
    append!(bytes, compile_value(str2, ctx))
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(str2_local))

    # Get len2
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len2_local))

    # Create new array with len1 + len2 elements, initialized to 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len2_local))
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    # Now stack has: [new_array]

    # Copy str1 to new_array at offset 0
    # array.copy dst_type src_type : [dst_ref dst_offset src_ref src_offset len]
    # dst = new_array (on stack), dst_offset = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # dst_offset = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))  # src_ref
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # src_offset = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))  # len
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_COPY)
    append!(bytes, encode_leb128_unsigned(str_type_idx))  # dst type
    append!(bytes, encode_leb128_unsigned(str_type_idx))  # src type
    # Stack is empty now, we need to get new_array back
    # Actually array.copy doesn't consume the dst ref... let me check
    # Actually it does consume all arguments. We need to restructure.

    # Let me use a different approach: store new_array in a local too
    return compile_string_concat_with_locals(str1, str2, ctx)
end

"""
String concatenation implementation using explicit locals.
Uses scratch locals allocated by allocate_scratch_locals!.
"""
function compile_string_concat_with_locals(str1, str2, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    str_type_idx = ctx.type_registry.string_array_idx

    # Use scratch locals stored in context (allocated at compile context creation time)
    if ctx.scratch_locals === nothing
        error("String operations require scratch locals but none were allocated")
    end
    result_local, str1_local, str2_local, len1_local, i_local = ctx.scratch_locals

    # Store str1
    append!(bytes, compile_value(str1, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(str1_local))

    # Store str2
    append!(bytes, compile_value(str2, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(str2_local))

    # Get len1 and store
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(len1_local))

    # Get len2
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    # Stack: [len2]

    # Create result array: len1 + len2
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))
    push!(bytes, Opcode.I32_ADD)  # len1 + len2
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_NEW_DEFAULT)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Copy str1 to result[0:len1]
    # array.copy: [dst, dst_off, src, src_off, len]
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # dst_off = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # src_off = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_COPY)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    # Copy str2 to result[len1:]
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len1_local))  # dst_off = len1
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # src_off = 0
    # len = str2.len
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_COPY)
    append!(bytes, encode_leb128_unsigned(str_type_idx))
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    # Return result
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))

    return bytes
end

"""
Compile string equality comparison (str1 == str2).
Returns i32 (0 or 1).
Uses scratch locals allocated by allocate_scratch_locals!.
"""
function compile_string_equal(str1, str2, ctx::CompilationContext)::Vector{UInt8}
    bytes = UInt8[]

    str_type_idx = ctx.type_registry.string_array_idx

    # Use scratch locals stored in context (allocated at compile context creation time)
    if ctx.scratch_locals === nothing
        error("String operations require scratch locals but none were allocated")
    end
    _, str1_local, str2_local, len_local, i_local = ctx.scratch_locals

    # Store str1 and str2
    append!(bytes, compile_value(str1, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(str1_local))

    append!(bytes, compile_value(str2, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(str2_local))

    # Compare lengths first
    # Get len1, store in len_local
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(len_local))

    # Compare with len2
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_LEN)
    push!(bytes, Opcode.I32_NE)

    # If lengths differ, result is 0; else compare elements
    push!(bytes, Opcode.IF)
    push!(bytes, 0x7F)  # result type i32

    # Then: lengths differ -> not equal
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)

    push!(bytes, Opcode.ELSE)

    # Else: lengths equal, compare element by element
    # Initialize i = 0
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_local))

    # Block for breaking out of loop with result
    push!(bytes, Opcode.BLOCK)
    push!(bytes, 0x7F)  # result type i32

    # Loop (void type - always exits via br)
    push!(bytes, Opcode.LOOP)
    push!(bytes, 0x40)  # void

    # Check if i >= len (done comparing, all matched)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(len_local))
    push!(bytes, Opcode.I32_GE_S)
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void
    # All elements matched -> push 1 and break
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # break to result block
    push!(bytes, Opcode.END)  # end if (i >= len)

    # Compare str1[i] vs str2[i]
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str1_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET_U)
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(str2_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.ARRAY_GET_U)
    append!(bytes, encode_leb128_unsigned(str_type_idx))

    push!(bytes, Opcode.I32_NE)

    # If elements differ -> push 0 and break
    push!(bytes, Opcode.IF)
    push!(bytes, 0x40)  # void
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)
    push!(bytes, Opcode.BR)
    push!(bytes, 0x02)  # break to result block
    push!(bytes, Opcode.END)  # end if (elements differ)

    # Increment i
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(i_local))
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I32_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(i_local))

    # Continue loop
    push!(bytes, Opcode.BR)
    push!(bytes, 0x00)  # br to loop

    push!(bytes, Opcode.END)  # end loop

    # Loop never falls through (always br), so this is unreachable
    push!(bytes, Opcode.UNREACHABLE)

    push!(bytes, Opcode.END)  # end result block

    push!(bytes, Opcode.END)  # end if-else (lengths comparison)

    return bytes
end

