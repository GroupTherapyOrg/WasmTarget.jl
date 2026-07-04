# ============================================================================
# 128-bit Integer Operation Emitters
# These emit WASM bytecode for 128-bit arithmetic operations.
# 128-bit integers are stored as structs with fields: lo (i64), hi (i64)
# ============================================================================

# parity(march 3, R5→floor): Int128/UInt128's concrete wasm type IS its registered
# two-i64 struct — resolved at the registration point, no post-hoc re-guess.
_int128_structref(ctx, T::Type) = ConcreteRef(get_int128_type!(ctx.mod, ctx.type_registry, T), true)

"""
Emit bytecode for 128-bit addition.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo + b_lo; carry = (result_lo < a_lo); result_hi = a_hi + b_hi + carry
Builder-native (THE implementation, march4).
"""
function emit_int128_add!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    # struct locals (pop from stack) then i64 locals for extracted values
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    for (i, t) in ((b_struct_local, structref), (a_struct_local, structref), (a_lo_local, I64),
                   (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64), (result_lo_local, I64))
        builder_set_local_type!(b, i, t)
    end

    # Pop b_struct (top) then a_struct
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract a_lo, a_hi, b_lo, b_hi (lo=field 1, hi=field 2)
    local_get!(b, a_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, a_lo_local)
    local_get!(b, a_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, a_hi_local)
    local_get!(b, b_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, b_lo_local)
    local_get!(b, b_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, b_hi_local)

    # result_lo = a_lo + b_lo
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_ADD)
    local_tee!(b, result_lo_local)
    # carry = (result_lo <_u a_lo) ? 1 : 0  → i64
    local_get!(b, a_lo_local); num!(b, Opcode.I64_LT_U); num!(b, Opcode.I64_EXTEND_I32_U)
    # result_hi = a_hi + carry + b_hi
    local_get!(b, a_hi_local); num!(b, Opcode.I64_ADD)
    local_get!(b, b_hi_local); num!(b, Opcode.I64_ADD)

    # Save result_hi, then push fields in order (typeId, lo, hi)
    hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, hi_local, I64)
    local_set!(b, hi_local)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local)
    local_get!(b, hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_add(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_add", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_add!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit bytecode for 128-bit subtraction.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo - b_lo; borrow = (a_lo < b_lo); result_hi = a_hi - b_hi - borrow
Builder-native (THE implementation, march4).
"""
function emit_int128_sub!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    borrow_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    for (i, t) in ((b_struct_local, structref), (a_struct_local, structref), (a_lo_local, I64),
                   (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (result_lo_local, I64), (result_hi_local, I64), (borrow_local, I64))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals (b_struct on top)
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    # result_lo = a_lo - b_lo
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_SUB); local_set!(b, result_lo_local)
    # borrow = (a_lo <_u b_lo) ? 1 : 0  → i64
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_LT_U); num!(b, Opcode.I64_EXTEND_I32_U); local_set!(b, borrow_local)
    # result_hi = a_hi - b_hi - borrow
    local_get!(b, a_hi_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_SUB)
    local_get!(b, borrow_local); num!(b, Opcode.I64_SUB); local_set!(b, result_hi_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_sub(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_sub", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_sub!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit bytecode for 128-bit multiplication (low 128 bits only).
Stack: [a_struct, b_struct] -> [result_struct]
Uses the identity: (a_lo + a_hi*2^64) * (b_lo + b_hi*2^64)
= a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo)*2^64 + a_hi*b_hi*2^128
Since we only need low 128 bits: result_lo = low64(a_lo*b_lo), result_hi = high64(a_lo*b_lo) + low64(a_lo*b_hi) + low64(a_hi*b_lo)
Builder-native (THE implementation, march4).
"""
function emit_int128_mul!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    # Extra locals for 32-bit decomposition (Knuth Algorithm M for the lo*lo carry)
    a0_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b0_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    t_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    w1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    w2_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    for i in (a_lo_local, a_hi_local, b_lo_local, b_hi_local, a0_local, a1_local, b0_local,
              b1_local, t_local, w1_local, w2_local, result_lo_local, result_hi_local)
        builder_set_local_type!(b, i, I64)
    end
    builder_set_local_type!(b, b_struct_local, structref); builder_set_local_type!(b, a_struct_local, structref)

    # Pop structs; extract fields (lo=field 1, hi=field 2)
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    mask32 = Int64(0xFFFFFFFF)
    # a0 = a_lo & mask ; a1 = a_lo >>u 32 ; b0 = b_lo & mask ; b1 = b_lo >>u 32
    local_get!(b, a_lo_local); i64_const!(b, mask32); num!(b, Opcode.I64_AND); local_set!(b, a0_local)
    local_get!(b, a_lo_local); i64_const!(b, 32); num!(b, Opcode.I64_SHR_U); local_set!(b, a1_local)
    local_get!(b, b_lo_local); i64_const!(b, mask32); num!(b, Opcode.I64_AND); local_set!(b, b0_local)
    local_get!(b, b_lo_local); i64_const!(b, 32); num!(b, Opcode.I64_SHR_U); local_set!(b, b1_local)
    # t = (a0*b0) >>u 32   (k)
    local_get!(b, a0_local); local_get!(b, b0_local); num!(b, Opcode.I64_MUL)
    i64_const!(b, 32); num!(b, Opcode.I64_SHR_U); local_set!(b, t_local)
    # t = a1*b0 + k
    local_get!(b, a1_local); local_get!(b, b0_local); num!(b, Opcode.I64_MUL)
    local_get!(b, t_local); num!(b, Opcode.I64_ADD); local_set!(b, t_local)
    # w1 = t & mask ; w2 = t >>u 32
    local_get!(b, t_local); i64_const!(b, mask32); num!(b, Opcode.I64_AND); local_set!(b, w1_local)
    local_get!(b, t_local); i64_const!(b, 32); num!(b, Opcode.I64_SHR_U); local_set!(b, w2_local)
    # t = (a0*b1 + w1) >>u 32   (k)
    local_get!(b, a0_local); local_get!(b, b1_local); num!(b, Opcode.I64_MUL)
    local_get!(b, w1_local); num!(b, Opcode.I64_ADD)
    i64_const!(b, 32); num!(b, Opcode.I64_SHR_U); local_set!(b, t_local)
    # carry = a1*b1 + w2 + k  (left ON STACK)
    local_get!(b, a1_local); local_get!(b, b1_local); num!(b, Opcode.I64_MUL)
    local_get!(b, w2_local); num!(b, Opcode.I64_ADD)
    local_get!(b, t_local); num!(b, Opcode.I64_ADD)
    # result_lo = a_lo * b_lo
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_MUL); local_set!(b, result_lo_local)
    # result_hi = a_lo*b_hi + carry + a_hi*b_lo   (carry still on stack)
    local_get!(b, a_lo_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_MUL); num!(b, Opcode.I64_ADD)
    local_get!(b, a_hi_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_MUL); num!(b, Opcode.I64_ADD)
    local_set!(b, result_hi_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_mul(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_mul", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_mul!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit negation: -x = ~x + 1 = (0, 0) - x.
Builder-native (THE implementation): consumes [x_struct] from `b`'s stack, pushes -x.
"""
function emit_int128_neg!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    for (i, t) in ((x_lo_local, I64), (x_hi_local, I64), (x_struct_local, structref),
                   (result_lo_local, I64), (result_hi_local, I64))
        builder_set_local_type!(b, i, t)
    end

    # Pop struct to local; extract lo (field 1), hi (field 2)
    local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # Two's complement: result_lo = ~x_lo + 1 ; result_hi = ~x_hi + (x_lo==0 ? 1 : 0)
    local_get!(b, x_lo_local); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
    i64_const!(b, 1); num!(b, Opcode.I64_ADD); local_set!(b, result_lo_local)
    local_get!(b, x_hi_local); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
    local_get!(b, x_lo_local); num!(b, Opcode.I64_EQZ); num!(b, Opcode.I64_EXTEND_I32_U)
    num!(b, Opcode.I64_ADD); local_set!(b, result_hi_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_neg(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_neg", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref])
    emit_int128_neg!(b, ctx, result_type)
    return builder_code(b)
end

# parity(march 3, R2→0): the builder-native comparator core. With [a_struct, b_struct]
# on `b`'s stack, spill to locals and extract (a_lo, a_hi, b_lo, b_hi) — the shared
# preamble of slt/ult/eq. Returns the four value-local indices.
function _int128_cmp_operands!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for (i, t) in ((a_lo_local, I64), (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (b_struct_local, structref), (a_struct_local, structref))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2; typeId at field 0)
    for (struct_local, lo_local, hi_local) in ((a_struct_local, a_lo_local, a_hi_local),
                                               (b_struct_local, b_lo_local, b_hi_local))
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end
    return (a_lo_local, a_hi_local, b_lo_local, b_hi_local)
end

"""
Emit 128-bit signed less than: a < b (signed).
Builder-native: consumes [a_struct, b_struct] from `b`'s stack, pushes i32.
"""
function emit_int128_slt!(b::InstrBuilder, ctx, arg_type::Type)
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # Signed 128-bit a < b: (a_hi <_s b_hi) | ((a_hi == b_hi) & (a_lo <_u b_lo))
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_LT_S)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_LT_U)
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    return b
end

# bytes shell for the remaining byte-region callers (dies with them)
function emit_int128_slt(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_slt", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_slt!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit unsigned less than: a < b (unsigned).
Builder-native: consumes [a_struct, b_struct] from `b`'s stack, pushes i32.
"""
function emit_int128_ult!(b::InstrBuilder, ctx, arg_type::Type)
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # Unsigned a < b: (a_hi <_u b_hi) | ((a_hi == b_hi) & (a_lo <_u b_lo))
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_LT_U)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_LT_U)
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    return b
end

# bytes shell for the remaining byte-region callers (dies with them)
function emit_int128_ult(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_ult", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_ult!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit signed less-or-equal: a <=_s b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_s b) || (a == b)
"""
# MIGRATED to InstrBuilder. (a <_s b) || (a == b); composes slt + eq via emit_raw!.
function emit_int128_sle!(b::InstrBuilder, ctx, arg_type::Type)
    structref = _int128_structref(ctx, arg_type)

    # Pop b and a to struct locals (so we can use each twice)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    builder_set_local_type!(b, b_struct_local, structref); builder_set_local_type!(b, a_struct_local, structref)
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # a <_s b (builder-native comparator; consumes the two structs)
    local_get!(b, a_struct_local); local_get!(b, b_struct_local)
    emit_int128_slt!(b, ctx, arg_type)
    # a == b
    local_get!(b, a_struct_local); local_get!(b, b_struct_local)
    emit_int128_eq!(b, ctx, arg_type)
    # (a < b) || (a == b)
    num!(b, Opcode.I32_OR)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_sle(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_sle", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_sle!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit unsigned less-or-equal: a <=_u b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_u b) || (a == b)
"""
# MIGRATED to InstrBuilder. (a <_u b) || (a == b); composes ult + eq via emit_raw!.
function emit_int128_ule!(b::InstrBuilder, ctx, arg_type::Type)
    structref = _int128_structref(ctx, arg_type)

    # Pop b and a to struct locals (so we can use each twice)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    builder_set_local_type!(b, b_struct_local, structref); builder_set_local_type!(b, a_struct_local, structref)
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # a <_u b (builder-native comparator; consumes the two structs)
    local_get!(b, a_struct_local); local_get!(b, b_struct_local)
    emit_int128_ult!(b, ctx, arg_type)
    # a == b
    local_get!(b, a_struct_local); local_get!(b, b_struct_local)
    emit_int128_eq!(b, ctx, arg_type)
    # (a < b) || (a == b)
    num!(b, Opcode.I32_OR)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_ule(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_ule", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_ule!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit left shift: x << n (where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

WBUILD-5001: WASM shift amounts are mod 64, so i64.shl(x, 64) = i64.shl(x, 0) = x.
Must handle n >= 64 and n == 0 edge cases with select.

select(val1, val2, cond): cond != 0 → val1 (deeper), cond == 0 → val2 (shallower)
Builder-native (THE implementation, march4).
"""
function emit_int128_shl!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    n_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    n_mod_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    cross_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, x_struct_local, structref)
    for i in (n_local, x_lo_local, x_hi_local, n_mod_local, result_lo_local, result_hi_local, cross_local)
        builder_set_local_type!(b, i, I64)
    end

    # Pop n (top) and x_struct; extract lo (field 1), hi (field 2)
    local_set!(b, n_local); local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # n_mod = n & 63
    local_get!(b, n_local); i64_const!(b, 63); num!(b, Opcode.I64_AND); local_set!(b, n_mod_local)

    # result_lo = n>=64 ? 0 : (x_lo << n_mod)   via select(0, x_lo<<n_mod, n>=64)
    i64_const!(b, 0)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHL)
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_GE_U)
    select!(b); local_set!(b, result_lo_local)

    # cross = n_mod==0 ? 0 : x_lo >> (64 - n_mod)   via select(0, x_lo>>(64-n_mod), n_mod==0)
    i64_const!(b, 0)
    local_get!(b, x_lo_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHR_U)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b); local_set!(b, cross_local)

    # hi_normal = (x_hi << n_mod) | cross   (left on stack)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHL)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    # hi_ge64 = x_lo << n_mod   (left on stack above hi_normal)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHL)
    # result_hi = n<64 ? hi_normal : hi_ge64   (negated cond so select args line up)
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b); local_set!(b, result_hi_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_shl(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_shl", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, I64])
    emit_int128_shl!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit logical right shift: x >> n (unsigned, where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

WBUILD-5001: Same mod-64 edge case handling as emit_int128_shl.
Builder-native (THE implementation, march4).
"""
function emit_int128_lshr!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    n_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    n_mod_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    cross_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, x_struct_local, structref)
    for i in (n_local, x_lo_local, x_hi_local, n_mod_local, result_lo_local, result_hi_local, cross_local)
        builder_set_local_type!(b, i, I64)
    end

    # Pop n (top), x_struct; extract lo (field 1), hi (field 2)
    local_set!(b, n_local); local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # n_mod = n & 63
    local_get!(b, n_local); i64_const!(b, 63); num!(b, Opcode.I64_AND); local_set!(b, n_mod_local)

    # result_hi = n>=64 ? 0 : (x_hi >>u n_mod)
    i64_const!(b, 0)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_GE_U)
    select!(b); local_set!(b, result_hi_local)

    # cross = n_mod==0 ? 0 : x_hi << (64 - n_mod)
    i64_const!(b, 0)
    local_get!(b, x_hi_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHL)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b); local_set!(b, cross_local)

    # lo_normal = (x_lo >>u n_mod) | cross  (on stack); lo_ge64 = x_hi >>u n_mod (on stack)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    # result_lo = n<64 ? lo_normal : lo_ge64
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b); local_set!(b, result_lo_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_lshr(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_lshr", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, I64])
    emit_int128_lshr!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit ARITHMETIC right shift: x >> n (signed, where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

Mirrors emit_int128_lshr but sign-fills the vacated high bits with the sign word
(x_hi >>s 63 = all-1s if negative): result_hi defaults to `sign` for n>=64, and
every shift of the high word uses i64.shr_s (arithmetic) instead of i64.shr_u.
The low word's own bits are still logical (i64.shr_u); only bits arriving FROM
the high word (cross / the n>=64 lo) carry the sign. Was MISSING — signed
`Int128 >>` fell through to the i64 guard (`i64.shr_s` on the struct ref →
validation failure; WasmMakie TwicePrecision range/tick widemul path).
Builder-native (THE implementation, march4).
"""
function emit_int128_ashr!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    n_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    n_mod_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    sign_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    cross_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, x_struct_local, structref)
    for i in (n_local, x_lo_local, x_hi_local, n_mod_local, sign_local, result_lo_local, result_hi_local, cross_local)
        builder_set_local_type!(b, i, I64)
    end

    # Pop n (top), x_struct; extract lo (field 1), hi (field 2)
    local_set!(b, n_local); local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # n_mod = n & 63 ; sign = x_hi >>s 63 (all-1s if negative)
    local_get!(b, n_local); i64_const!(b, 63); num!(b, Opcode.I64_AND); local_set!(b, n_mod_local)
    local_get!(b, x_hi_local); i64_const!(b, 63); num!(b, Opcode.I64_SHR_S); local_set!(b, sign_local)

    # result_hi = n>=64 ? sign : (x_hi >>s n_mod)
    local_get!(b, sign_local)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_S)
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_GE_U)
    select!(b); local_set!(b, result_hi_local)

    # cross = n_mod==0 ? 0 : x_hi << (64 - n_mod)
    i64_const!(b, 0)
    local_get!(b, x_hi_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHL)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b); local_set!(b, cross_local)

    # lo_normal = (x_lo >>u n_mod) | cross (stack); lo_ge64 = x_hi >>s n_mod (stack)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_S)
    # result_lo = n<64 ? lo_normal : lo_ge64
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b); local_set!(b, result_lo_local)

    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_ashr(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_ashr", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, I64])
    emit_int128_ashr!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit count leading zeros
Stack: [x_struct] -> [result_struct (UInt128)]

WBUILD-5001: Cleaned up dead code from first attempt that wasted 3 locals.
Builder-native (THE implementation, march4).
"""
function emit_int128_ctlz!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    clz_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for i in (x_lo_local, x_hi_local, clz_hi_local); builder_set_local_type!(b, i, I64); end
    builder_set_local_type!(b, x_struct_local, structref)

    # Pop x_struct; extract lo (field 1), hi (field 2)
    local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # clz_hi = clz(x_hi)
    local_get!(b, x_hi_local); num!(b, Opcode.I64_CLZ); local_set!(b, clz_hi_local)

    # hi==0 ? 64+clz(lo) : clz(hi)   via select(64+clz(lo), clz(hi), hi==0)
    i64_const!(b, 64); local_get!(b, x_lo_local); num!(b, Opcode.I64_CLZ); num!(b, Opcode.I64_ADD)
    local_get!(b, clz_hi_local)
    local_get!(b, x_hi_local); num!(b, Opcode.I64_EQZ)
    select!(b)

    # Wrap i64 result in UInt128 struct (lo=clz_result, hi=0)
    result_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, result_local, I64)
    local_set!(b, result_local)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, arg_type)))  # real classId (was placeholder 0)
    local_get!(b, result_local)
    i64_const!(b, 0)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_ctlz(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_ctlz", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref])
    emit_int128_ctlz!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit count trailing zeros (F11). Stack: [x_struct] -> [result_struct].
tz(x) = lo==0 ? 64 + ctz(hi) : ctz(lo). Mirrors emit_int128_ctlz (lo/hi roles swapped);
the prior code emitted a single i64.ctz on a 128-bit value → invalid wasm.
Builder-native (THE implementation, march4).
"""
function emit_int128_cttz!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    ctz_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for i in (x_lo_local, x_hi_local, ctz_lo_local); builder_set_local_type!(b, i, I64); end
    builder_set_local_type!(b, x_struct_local, structref)

    local_set!(b, x_struct_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, x_lo_local)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, x_hi_local)

    # ctz_lo = ctz(x_lo)
    local_get!(b, x_lo_local); num!(b, Opcode.I64_CTZ); local_set!(b, ctz_lo_local)

    # lo==0 ? 64+ctz(hi) : ctz(lo)   via select(64+ctz(hi), ctz(lo), lo==0)
    i64_const!(b, 64); local_get!(b, x_hi_local); num!(b, Opcode.I64_CTZ); num!(b, Opcode.I64_ADD)
    local_get!(b, ctz_lo_local)
    local_get!(b, x_lo_local); num!(b, Opcode.I64_EQZ)
    select!(b)

    result_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, result_local, I64)
    local_set!(b, result_local)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, arg_type)))  # real classId (was placeholder 0)
    local_get!(b, result_local)
    i64_const!(b, 0)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_cttz(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_cttz", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref])
    emit_int128_cttz!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit population count (F11). Stack: [x_struct] -> [result_struct].
popcnt(x) = popcnt(lo) + popcnt(hi). The prior code emitted a single i64.popcnt on a
128-bit value → invalid wasm.
Builder-native (THE implementation, march4).
"""
function emit_int128_ctpop!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    builder_set_local_type!(b, x_struct_local, structref)
    local_set!(b, x_struct_local)

    # popcnt(lo) + popcnt(hi)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); num!(b, Opcode.I64_POPCNT)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); num!(b, Opcode.I64_POPCNT)
    num!(b, Opcode.I64_ADD)

    result_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, result_local, I64)
    local_set!(b, result_local)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, arg_type)))  # real classId (was placeholder 0)
    local_get!(b, result_local)
    i64_const!(b, 0)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_ctpop(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_ctpop", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref])
    emit_int128_ctpop!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit bitwise NOT (F11). Stack: [x_struct] -> [result_struct].
~x = {~lo, ~hi}. The prior code emitted a single i64.xor -1 on a 128-bit value → invalid
wasm; surfaced via count_zeros (= count_ones(~x)).
Builder-native (THE implementation, march4).
"""
function emit_int128_not!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    builder_set_local_type!(b, x_struct_local, structref)
    local_set!(b, x_struct_local)

    # { typeId=0, lo = lo xor -1, hi = hi xor -1 }
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, arg_type)))  # real classId (was placeholder 0)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 1, I64); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
    local_get!(b, x_struct_local); struct_get!(b, type_idx, 2, I64); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_not(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_not", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref])
    emit_int128_not!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit bitwise AND
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation, march4).
"""
function emit_int128_and!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for (i, t) in ((a_lo_local, I64), (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (b_struct_local, structref), (a_struct_local, structref))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2; typeId at field 0)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    # result_lo = a_lo & b_lo ; result_hi = a_hi & b_hi
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_AND)
    local_get!(b, a_hi_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_AND)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_and(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_and", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_and!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit bitwise OR
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation, march4).
"""
function emit_int128_or!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for (i, t) in ((a_lo_local, I64), (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (b_struct_local, structref), (a_struct_local, structref))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2; typeId at field 0)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    # result_lo = a_lo | b_lo ; result_hi = a_hi | b_hi
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_OR)
    local_get!(b, a_hi_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_OR)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_or(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_or", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_or!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit bitwise XOR
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation, march4).
"""
function emit_int128_xor!(b::InstrBuilder, ctx, result_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    structref = _int128_structref(ctx, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for (i, t) in ((a_lo_local, I64), (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (b_struct_local, structref), (a_struct_local, structref))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2; typeId at field 0)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    # result_lo = a_lo ^ b_lo ; result_hi = a_hi ^ b_hi
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_XOR)
    local_get!(b, a_hi_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_XOR)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_xor(ctx, result_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, result_type)
    b = InstrBuilder(; func_name="emit_int128_xor", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_xor!(b, ctx, result_type)
    return builder_code(b)
end

"""
Emit 128-bit equality comparison.
Builder-native: consumes [a_struct, b_struct] from `b`'s stack, pushes i32.
"""
function emit_int128_eq!(b::InstrBuilder, ctx, arg_type::Type)
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # (a_lo == b_lo) && (a_hi == b_hi)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_EQ)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    num!(b, Opcode.I32_AND)
    return b
end

# bytes shell for the remaining byte-region callers (dies with them)
function emit_int128_eq(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_eq", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_eq!(b, ctx, arg_type)
    return builder_code(b)
end

"""
Emit 128-bit not-equal comparison
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Builder-native (THE implementation, march4).
"""
function emit_int128_ne!(b::InstrBuilder, ctx, arg_type::Type)
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)
    structref = _int128_structref(ctx, arg_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    a_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, structref)
    for (i, t) in ((a_lo_local, I64), (a_hi_local, I64), (b_lo_local, I64), (b_hi_local, I64),
                   (b_struct_local, structref), (a_struct_local, structref))
        builder_set_local_type!(b, i, t)
    end

    # Pop structs to locals
    local_set!(b, b_struct_local)
    local_set!(b, a_struct_local)

    # Extract fields (lo=field 1, hi=field 2; typeId at field 0)
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        local_get!(b, struct_local); struct_get!(b, type_idx, 1, I64); local_set!(b, lo_local)
        local_get!(b, struct_local); struct_get!(b, type_idx, 2, I64); local_set!(b, hi_local)
    end

    # (a_lo != b_lo) || (a_hi != b_hi)
    local_get!(b, a_lo_local); local_get!(b, b_lo_local); num!(b, Opcode.I64_NE)
    local_get!(b, a_hi_local); local_get!(b, b_hi_local); num!(b, Opcode.I64_NE)
    num!(b, Opcode.I32_OR)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_int128_ne(ctx, arg_type::Type)::Vector{UInt8}
    structref = _int128_structref(ctx, arg_type)
    b = InstrBuilder(; func_name="emit_int128_ne", strict=_wt_builder_strict())
    seed_input!(b, WasmValType[structref, structref])
    emit_int128_ne!(b, ctx, arg_type)
    return builder_code(b)
end

