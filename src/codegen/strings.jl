# ============================================================================
# String IO — wasm:js-string Builtins (standardized, Chrome 131+)
# ============================================================================

# Module-level storage for the i16 char array type index used at the JS boundary
const _CHAR_ARRAY_TYPE_IDX = TaskLocalRef{Union{Nothing, UInt32}}(:_wt_char_array_idx, nothing)

function clear_char_array_type!()
    _CHAR_ARRAY_TYPE_IDX[] = nothing
end

"""
Get or create the i16 char array type used for `wasm:js-string.fromCharCodeArray`.
Internal strings stay as i8 UTF-8; this i16 type is only for the JS boundary.
"""
function get_char_array_type!(mod::WasmModule)::UInt32
    if _CHAR_ARRAY_TYPE_IDX[] !== nothing
        return _CHAR_ARRAY_TYPE_IDX[]
    end
    # (array (mut i16)) for UTF-16 char codes
    idx = add_array_type!(mod, UInt8(0x77), true)  # 0x77 = i16
    _CHAR_ARRAY_TYPE_IDX[] = idx
    return idx
end

"""
    add_string_io_imports!(mod, type_registry) -> (decode_idx, encode_idx)

Add `wasm:js-string.fromCharCodeArray` and `wasm:js-string.intoCharCodeArray`
imports. These are standardized JS String Builtins auto-provided by engines
when compiled with `builtins: ["js-string"]` (Chrome 131+, Node 23+).

Returns a named tuple `(decode_idx, encode_idx)` with the import function indices.
"""
function add_string_io_imports!(mod::WasmModule, type_registry::TypeRegistry)
    char_arr_type_idx = get_char_array_type!(mod)
    char_arr_ref_nullable = ConcreteRef(char_arr_type_idx, true)   # (ref null $i16arr)

    str_arr_type_idx = get_string_array_type!(mod, type_registry)
    str_arr_ref_nonnull = ConcreteRef(str_arr_type_idx, false)     # (ref $str_arr)

    # fromCharCodeArray: (ref null (array (mut i16)), i32, i32) → (ref extern)
    decode_idx = add_import!(mod, "wasm:js-string", "fromCharCodeArray",
        WasmValType[char_arr_ref_nullable, I32, I32],
        WasmValType[NonNullExternRef])

    # intoCharCodeArray: (externref, ref null (array (mut i16)), i32) → i32
    # For encode, we keep the old approach as a stub — not yet used at IO boundary
    encode_idx = decode_idx  # placeholder — encode not used in println path

    return (decode_idx=decode_idx, encode_idx=encode_idx)
end

"""
Module-level storage for the utf8_to_js helper function index.
This helper converts an i8 UTF-8 array to a JS string via fromCharCodeArray.
Created once per module in add_string_io_imports! or add_io_imports!.
"""
const _UTF8_TO_JS_FUNC_IDX = TaskLocalRef{Union{Nothing, UInt32}}(:_wt_utf8_to_js_idx, nothing)

function clear_utf8_to_js_func!()
    _UTF8_TO_JS_FUNC_IDX[] = nothing
end

"""
Create a WASM helper function that converts i8 UTF-8 array → JS string.

The helper:
1. Gets the i8 array length
2. Creates an i16 array of the same length
3. Loops: zero-extends each i8 byte to i16
4. Calls fromCharCodeArray(i16arr, 0, len) → (ref extern)

Signature: (ref null \$i8arr) → (ref extern)
"""
function create_utf8_to_js_helper!(mod::WasmModule, type_registry::TypeRegistry, decode_import_idx::UInt32)::UInt32
    str_arr_type_idx = get_string_array_type!(mod, type_registry)
    char_arr_type_idx = get_char_array_type!(mod)

    i8arr_ref = ConcreteRef(str_arr_type_idx, true)  # param type: (ref null $i8arr)

    # Function type: (ref null $i8arr) → (ref extern)
    ft = FuncType(WasmValType[i8arr_ref], WasmValType[NonNullExternRef])
    type_idx = add_type!(mod, ft)

    # Locals: 0=param(i8arr), 1=len(i32), 2=i16arr(ref $i16arr), 3=i(i32)
    locals = WasmValType[I32, ConcreteRef(char_arr_type_idx, true), I32]

    local_i8arr = UInt32(0)
    local_len = UInt32(1)
    local_i16arr = UInt32(2)
    local_i = UInt32(3)

    # MIGRATED to InstrBuilder (typed). Full helper-function body: i8 UTF-8 array →
    # i16 char array → fromCharCodeArray. Byte-identical to the raw emission below.
    char_arr_ref = ConcreteRef(char_arr_type_idx, true)
    b = InstrBuilder(WasmValType[i8arr_ref], WasmValType[NonNullExternRef];
                     func_name="create_utf8_to_js_helper", strict=_wt_builder_strict())
    builder_set_local_type!(b, local_len, I32)
    builder_set_local_type!(b, local_i16arr, char_arr_ref)
    builder_set_local_type!(b, local_i, I32)

    # len = i8arr.len
    local_get!(b, local_i8arr)
    array_len!(b)
    local_tee!(b, local_len)

    # i16arr = array.new_default $i16arr len
    array_new_default!(b, char_arr_type_idx)
    local_set!(b, local_i16arr)

    # i = 0
    i32_const!(b, 0)
    local_set!(b, local_i)

    # block { loop {
    block!(b)
    loop!(b)

    # if i >= len, break
    local_get!(b, local_i)
    local_get!(b, local_len)
    num!(b, Opcode.I32_GE_U)
    br_if!(b, 1)

    # i16arr[i] = (i32)i8arr[i]  — array.get_u zero-extends, array.set truncates
    local_get!(b, local_i16arr)
    local_get!(b, local_i)
    local_get!(b, local_i8arr)
    local_get!(b, local_i)
    array_get!(b, str_arr_type_idx, I32; signed=false)
    array_set!(b, char_arr_type_idx, I32)

    # i++
    local_get!(b, local_i)
    i32_const!(b, 1)
    num!(b, Opcode.I32_ADD)
    local_set!(b, local_i)

    # br loop
    br!(b, 0)

    end_block!(b)  # end loop
    end_block!(b)  # end block

    # return fromCharCodeArray(i16arr, 0, len)
    local_get!(b, local_i16arr)
    i32_const!(b, 0)
    local_get!(b, local_len)
    call!(b, decode_import_idx,
          WasmValType[char_arr_ref, I32, I32], WasmValType[NonNullExternRef])

    end_block!(b)  # end function
    body = builder_code(b)

    func = WasmFunction(type_idx, locals, body)
    push!(mod.functions, func)
    func_idx = UInt32(length(mod.imports) + length(mod.functions) - 1)
    _UTF8_TO_JS_FUNC_IDX[] = func_idx
    return func_idx
end

"""
    emit_jl_string_to_js!(bytes, decode_func_idx, tmp_local)

Emit bytecode to convert a Julia string (WasmGC i8 array on stack) to a
JS string (externref). Calls the module-level `\$utf8_to_js` helper function.

**Stack effect:** `[(ref \$str_arr)] → [externref]`
"""
function emit_jl_string_to_js!(bytes::Vector{UInt8}, decode_func_idx::UInt32, tmp_local::UInt32)
    helper_idx = _UTF8_TO_JS_FUNC_IDX[]
    if helper_idx === nothing
        error("utf8_to_js helper not created — call create_utf8_to_js_helper! first")
    end
    # Stack: [i8_arr_ref]
    # Call $utf8_to_js(i8_arr_ref) → (ref extern)
    # MIGRATED to InstrBuilder (typed). call! emits CALL + leb_u(helper_idx), byte-identical.
    # This is an external emit_*!(bytes,...) helper that mutates the caller's buffer, so we
    # build into a local collect-mode builder and splice the result (no seeding needed; the
    # caller's bridge already declares the [i8_arr_ref] → [externref] stack effect).
    ib = InstrBuilder(; func_name="emit_jl_string_to_js")
    call!(ib, helper_idx, WasmValType[], WasmValType[])
    append!(bytes, builder_code(ib))
end

"""
    emit_js_to_jl_string!(bytes, encode_func_idx)

Emit bytecode to convert a JS string (externref on stack) to a Julia string (WasmGC i8 array).

**Stack effect:** `[externref] → [(ref \$str_arr)]`

NOTE: This currently uses the legacy wasm:text-encoder path. For the playground,
only the decode (Julia→JS) direction is needed for println output.
"""
function emit_js_to_jl_string!(bytes::Vector{UInt8}, encode_func_idx::UInt32)
    # Stack: [externref]
    # Call encodeStringToUTF8Array(externref) → (ref $str_arr)
    # MIGRATED to InstrBuilder (typed). call! emits CALL + leb_u(encode_func_idx), byte-identical.
    # External emit_*!(bytes,...) helper that mutates the caller's buffer → build into a local
    # collect-mode builder and splice (caller's bridge declares the [externref] → [str_arr] effect).
    ib = InstrBuilder(; func_name="emit_js_to_jl_string")
    call!(ib, encode_func_idx, WasmValType[], WasmValType[])
    append!(bytes, builder_code(ib))
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
    write_nothing_idx::UInt32   # io.write_nothing() → void (PURE-9041)
    decode_idx::UInt32          # wasm:text-decoder.decodeStringFromUTF8Array
end

"""
    add_io_imports!(mod, type_registry) -> IOImports

Add IO bridge imports for println/print support.
Imports: io.write_string, io.write_int, io.write_float, io.write_bool, io.write_newline
Also adds wasm:text-decoder import for string conversion.
"""
function add_io_imports!(mod::WasmModule, type_registry::TypeRegistry)
    # String decoder via standardized wasm:js-string builtins
    char_arr_type_idx = get_char_array_type!(mod)
    char_arr_ref_nullable = ConcreteRef(char_arr_type_idx, true)

    decode_idx = add_import!(mod, "wasm:js-string", "fromCharCodeArray",
        WasmValType[char_arr_ref_nullable, I32, I32],
        WasmValType[NonNullExternRef])

    # IO imports (must be registered BEFORE the helper function, since imports shift function indices)
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
    # PURE-9041: write_nothing() outputs "nothing" string
    write_nothing_idx = add_import!(mod, "io", "write_nothing",
        WasmValType[], WasmValType[])

    # Create the utf8→js helper AFTER all imports are registered
    # (adding imports after this would shift function indices)
    create_utf8_to_js_helper!(mod, type_registry, decode_idx)

    return IOImports(write_string_idx, write_int_idx, write_float_idx,
                     write_bool_idx, write_newline_idx, write_nothing_idx, decode_idx)
end

# Module-level storage for IO imports (set during compile_module if println/print is used)
const _IO_IMPORTS = TaskLocalRef{Union{Nothing, IOImports}}(:_wt_io_imports, nothing)

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
# Performance Timer — jl_hrtime via performance.now() (PURE-9042)
# ============================================================================

const _PERF_NOW_IDX = TaskLocalRef{Union{Nothing, UInt32}}(:_wt_perf_now_idx, nothing)

"""
    ensure_perf_now_import!(mod) -> UInt32

Import env.perf_now() → f64 for high-resolution timing. Idempotent.
"""
function ensure_perf_now_import!(mod::WasmModule)::UInt32
    existing = _PERF_NOW_IDX[]
    if existing !== nothing
        return existing
    end
    idx = add_import!(mod, "env", "perf_now", WasmValType[], WasmValType[F64])
    _PERF_NOW_IDX[] = idx
    return idx
end

function clear_perf_now!()
    _PERF_NOW_IDX[] = nothing
end

# ============================================================================
# RNG State — Xoshiro256++ via Wasm Globals (PURE-9043)
# ============================================================================

"""
PURE-9043: RNG state stored in 4 mutable i64 Wasm globals.
Julia's rand() uses Xoshiro256++ with task-local state (rngState0..3).
We store these in Wasm globals instead.
"""
struct RNGGlobals
    rng0_idx::UInt32  # global index for rngState0 (i64)
    rng1_idx::UInt32  # global index for rngState1 (i64)
    rng2_idx::UInt32  # global index for rngState2 (i64)
    rng3_idx::UInt32  # global index for rngState3 (i64)
    seed_import_idx::UInt32  # import index for env.random_i64
end

const _RNG_GLOBALS = TaskLocalRef{Union{Nothing, RNGGlobals}}(:_wt_rng_globals, nothing)

function get_rng_globals()
    return _RNG_GLOBALS[]
end

function set_rng_globals!(rng::RNGGlobals)
    _RNG_GLOBALS[] = rng
end

function clear_rng_globals!()
    _RNG_GLOBALS[] = nothing
end

"""
    ensure_rng_globals!(mod) -> RNGGlobals

Create 4 mutable i64 globals for Xoshiro256++ RNG state + JS seed import.
Idempotent — returns existing globals if already created.
"""
function ensure_rng_globals!(mod::WasmModule)::RNGGlobals
    existing = get_rng_globals()
    if existing !== nothing
        return existing
    end

    # Import seed function: env.random_i64() -> i64
    seed_idx = add_import!(mod, "env", "random_i64",
        WasmValType[], WasmValType[I64])

    # Create 4 mutable i64 globals with non-zero seeds
    # Initial values are arbitrary non-zero constants (within signed i64 range)
    seeds = Int64[
        1311768467294899695,   # 0x1234567890ABCDEF & 0x7FFF...
        3978425108881204001,   # non-zero seed
        7463728394857261543,   # non-zero seed
        2846573918374629105,   # non-zero seed
    ]

    rng_indices = UInt32[]
    for seed in seeds
        # MIGRATED to InstrBuilder (typed). Const-expr init = (i64.const seed) (end).
        # Byte-identical: i64_const! emits I64_CONST + leb_s(seed); the const-expr END
        # terminator (0x0B) is bridged (no open block in a const expr to balance).
        ib = InstrBuilder(; func_name="ensure_rng_globals!", mod=mod)
        i64_const!(ib, seed)
        emit_raw!(ib, UInt8[Opcode.END])
        init = builder_code(ib)
        push!(mod.globals, WasmGlobalDef(I64, true, init))
        push!(rng_indices, UInt32(length(mod.globals) - 1))
    end

    rng = RNGGlobals(rng_indices[1], rng_indices[2], rng_indices[3], rng_indices[4], seed_idx)
    set_rng_globals!(rng)
    return rng
end

"""
    get_rng_global_idx(field_name::Symbol) -> Union{UInt32, Nothing}

Map rngState field name to global index. Returns nothing if field is not an RNG field.
"""
function get_rng_global_idx(field_name::Symbol)::Union{UInt32, Nothing}
    rng = get_rng_globals()
    if rng === nothing
        return nothing
    end
    if field_name === :rngState0
        return rng.rng0_idx
    elseif field_name === :rngState1
        return rng.rng1_idx
    elseif field_name === :rngState2
        return rng.rng2_idx
    elseif field_name === :rngState3
        return rng.rng3_idx
    end
    return nothing
end

# ============================================================================
# String Operations
# ============================================================================

"""
Compile string concatenation (str1 * str2).
Creates a new string array with combined contents.
Uses locals for intermediate values.
"""
# Thin delegator. The explicit-locals implementation below is the real one; the old
# inline body here built a `bytes` vector then discarded it (dead bloat) — removed.
function compile_string_concat(str1, str2, ctx::AbstractCompilationContext)::Vector{UInt8}
    return compile_string_concat_with_locals(str1, str2, ctx)
end

"""
String concatenation implementation using explicit locals.
Uses scratch locals allocated by allocate_scratch_locals!.
"""
# MIGRATED to InstrBuilder (typed). Concatenates two char-arrays via scratch locals +
# array.copy. Byte-identical to before.
function compile_string_concat_with_locals(str1, str2, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = ctx.type_registry.string_array_idx

    # Use scratch locals stored in context (allocated at compile context creation time)
    if ctx.scratch_locals === nothing
        error("String operations require scratch locals but none were allocated")
    end
    result_local, str1_local, str2_local, len1_local, i_local = ctx.scratch_locals

    b = InstrBuilder(; func_name="compile_string_concat", strict=_wt_builder_strict())
    set_context!(b, "string concat")
    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, result_local, strref)
    builder_set_local_type!(b, str1_local, strref)
    builder_set_local_type!(b, str2_local, strref)
    builder_set_local_type!(b, len1_local, I32)

    # Store str1, str2
    emit_value!(b, str1, ctx)
    local_set!(b, str1_local)
    emit_value!(b, str2, ctx)
    local_set!(b, str2_local)

    # len1 = str1.len (stored); len2 = str2.len (left on stack)
    local_get!(b, str1_local); array_len!(b); local_set!(b, len1_local)
    local_get!(b, str2_local); array_len!(b)            # stack: [len2]

    # Create result array of len1 + len2
    local_get!(b, len1_local); num!(b, Opcode.I32_ADD)
    array_new_default!(b, str_type_idx); local_set!(b, result_local)

    # Copy str1 → result[0:len1]   array.copy: [dst, dst_off, src, src_off, len]
    local_get!(b, result_local); i32_const!(b, 0)
    local_get!(b, str1_local); i32_const!(b, 0)
    local_get!(b, len1_local)
    array_copy!(b, str_type_idx, str_type_idx)

    # Copy str2 → result[len1:]
    local_get!(b, result_local); local_get!(b, len1_local)  # dst_off = len1
    local_get!(b, str2_local); i32_const!(b, 0)             # src_off = 0
    local_get!(b, str2_local); array_len!(b)                # len = str2.len
    array_copy!(b, str_type_idx, str_type_idx)

    local_get!(b, result_local)                             # return result
    return builder_code(b)
end

"""
Compile string equality comparison (str1 == str2).
Returns i32 (0 or 1).
Uses scratch locals allocated by allocate_scratch_locals!.
"""
# MIGRATED to InstrBuilder (typed). Element-wise char-array equality with explicit
# control flow (if/else over length mismatch, then a compare-loop). Byte-identical.
function compile_string_equal(str1, str2, ctx::AbstractCompilationContext)::Vector{UInt8}
    str_type_idx = ctx.type_registry.string_array_idx

    # Use scratch locals stored in context (allocated at compile context creation time)
    if ctx.scratch_locals === nothing
        error("String operations require scratch locals but none were allocated")
    end
    _, str1_local, str2_local, len_local, i_local = ctx.scratch_locals

    b = InstrBuilder(; func_name="compile_string_equal", strict=_wt_builder_strict())
    set_context!(b, "string ==")
    strref = ConcreteRef(UInt32(str_type_idx), true)
    builder_set_local_type!(b, str1_local, strref)
    builder_set_local_type!(b, str2_local, strref)
    builder_set_local_type!(b, len_local, I32)
    builder_set_local_type!(b, i_local, I32)

    # Store str1 and str2
    emit_value!(b, str1, ctx)
    local_set!(b, str1_local)
    emit_value!(b, str2, ctx)
    local_set!(b, str2_local)

    # len1 = str1.len (tee into len_local); compare with len2
    local_get!(b, str1_local); array_len!(b); local_tee!(b, len_local)
    local_get!(b, str2_local); array_len!(b); num!(b, Opcode.I32_NE)

    # If lengths differ → 0; else compare elements
    if_!(b, 0x7F; results=WasmValType[I32])
        i32_const!(b, 0)                                   # lengths differ → not equal
    else_!(b)
        i32_const!(b, 0); local_set!(b, i_local)           # i = 0
        block!(b, 0x7F; results=WasmValType[I32])          # break-with-result block
            loop!(b, 0x40)                                 # void loop
                # if i >= len → all matched, push 1 and break to block
                local_get!(b, i_local); local_get!(b, len_local); num!(b, Opcode.I32_GE_S)
                if_!(b, 0x40)
                    i32_const!(b, 1); br!(b, 2)
                end_block!(b)
                # compare str1[i] vs str2[i] (unsigned packed-byte get)
                local_get!(b, str1_local); local_get!(b, i_local)
                array_get!(b, str_type_idx, I32; signed=false)
                local_get!(b, str2_local); local_get!(b, i_local)
                array_get!(b, str_type_idx, I32; signed=false)
                num!(b, Opcode.I32_NE)
                if_!(b, 0x40)
                    i32_const!(b, 0); br!(b, 2)             # differ → not equal
                end_block!(b)
                # i += 1; continue
                local_get!(b, i_local); i32_const!(b, 1); num!(b, Opcode.I32_ADD); local_set!(b, i_local)
                br!(b, 0)
            end_block!(b)                                  # end loop
            unreachable!(b)                                # loop never falls through  # structural trap (dart-legit dead path)
        end_block!(b)                                      # end result block
    end_block!(b)                                          # end if-else

    return builder_code(b)
end

