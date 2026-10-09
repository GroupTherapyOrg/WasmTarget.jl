# ============================================================================
# 128-bit Integer Operation Emitters
# These emit WASM bytecode for 128-bit arithmetic operations.
# 128-bit integers are stored as structs with fields: lo (i64), hi (i64)
# ============================================================================

# parity(quarantine: Int128/UInt128 have no dart equivalent — dart's `int` is a single
# 64-bit value (translator.dart:346 `coreTypes.intClass: w.NumType.i64`), never a two-limb
# struct; looked for a 128-bit integer representation in translator.dart/intrinsics.dart,
# absent). Int128/UInt128's concrete wasm type IS its registered
# two-i64 struct — resolved at the registration point, no post-hoc re-guess.
_int128_structref(ctx, T::Type)::ConcreteRef = ConcreteRef(get_int128_type!(ctx.mod, ctx.type_registry, T), true)

"""
Emit bytecode for 128-bit addition.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo + b_lo; carry = (result_lo < a_lo); result_hi = a_hi + b_hi + carry
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `add_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_add!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit bytecode for 128-bit subtraction.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo - b_lo; borrow = (a_lo < b_lo); result_hi = a_hi - b_hi - borrow
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `sub_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_sub!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit bytecode for 128-bit multiplication (low 128 bits only).
Stack: [a_struct, b_struct] -> [result_struct]
Uses the identity: (a_lo + a_hi*2^64) * (b_lo + b_hi*2^64)
= a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo)*2^64 + a_hi*b_hi*2^128
Since we only need low 128 bits: result_lo = low64(a_lo*b_lo), result_hi = high64(a_lo*b_lo) + low64(a_lo*b_hi) + low64(a_hi*b_lo)
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `mul_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_mul!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit 128-bit negation: -x = ~x + 1 = (0, 0) - x.
Builder-native (THE implementation): consumes [x_struct] from `b`'s stack, pushes -x.
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `neg_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_neg!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

# parity(quarantine: Int128/UInt128 comparison has no dart equivalent — dart's `int` is a
# single 64-bit value compared with one i64 comparison opcode; looked for a multi-limb
# integer comparator in intrinsics.dart's binary-operator emitters, absent). the
# builder-native comparator core. With [a_struct, b_struct]
# on `b`'s stack, spill to locals and extract (a_lo, a_hi, b_lo, b_hi) — the shared
# preamble of slt/ult/eq. Returns the four value-local indices.
function _int128_cmp_operands!(b::InstrBuilder, ctx, arg_type::Type)::NTuple{4, Int}
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
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `slt_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_slt!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # Signed 128-bit a < b: (a_hi <_s b_hi) | ((a_hi == b_hi) & (a_lo <_u b_lo))
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_LT_S)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_LT_U)
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    return b
end

"""
Emit 128-bit unsigned less than: a < b (unsigned).
Builder-native: consumes [a_struct, b_struct] from `b`'s stack, pushes i32.
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ult_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ult!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # Unsigned a < b: (a_hi <_u b_hi) | ((a_hi == b_hi) & (a_lo <_u b_lo))
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_LT_U)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_LT_U)
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    return b
end

"""
Emit 128-bit signed less-or-equal: a <=_s b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_s b) || (a == b)
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `sle_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_sle!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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

"""
Emit 128-bit unsigned less-or-equal: a <=_u b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_u b) || (a == b)
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ule_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ule!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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

"""
Emit 128-bit left shift: x << n (where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

WASM shift amounts are mod 64, so i64.shl(x, 64) = i64.shl(x, 0) = x.
Must handle n >= 64 and n == 0 edge cases with select.

select(val1, val2, cond): cond != 0 → val1 (deeper), cond == 0 → val2 (shallower)
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `shl_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_shl!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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
    select!(b, I64); local_set!(b, result_lo_local)

    # cross = n_mod==0 ? 0 : x_lo >> (64 - n_mod)   via select(0, x_lo>>(64-n_mod), n_mod==0)
    i64_const!(b, 0)
    local_get!(b, x_lo_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHR_U)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b, I64); local_set!(b, cross_local)

    # hi_normal = (x_hi << n_mod) | cross   (left on stack)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHL)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    # hi_ge64 = x_lo << n_mod   (left on stack above hi_normal)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHL)
    # result_hi = n<64 ? hi_normal : hi_ge64   (negated cond so select args line up)
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b, I64); local_set!(b, result_hi_local)

    # an amount of at least 128 gives 0: Julia's shl_int selects on `shift >= width`
    # (intrinsics.cpp), which the limb shifts above, taking their amount modulo 64, never see
    for r in (result_lo_local, result_hi_local)
        local_get!(b, r); i64_const!(b, 0)
        local_get!(b, n_local); i64_const!(b, 128); num!(b, Opcode.I64_LT_U)
        select!(b, I64); local_set!(b, r)
    end
    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""
Emit 128-bit logical right shift: x >> n (unsigned, where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

Same mod-64 edge case handling as emit_int128_shl.
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `lshr_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_lshr!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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
    select!(b, I64); local_set!(b, result_hi_local)

    # cross = n_mod==0 ? 0 : x_hi << (64 - n_mod)
    i64_const!(b, 0)
    local_get!(b, x_hi_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHL)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b, I64); local_set!(b, cross_local)

    # lo_normal = (x_lo >>u n_mod) | cross  (on stack); lo_ge64 = x_hi >>u n_mod (on stack)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    # result_lo = n<64 ? lo_normal : lo_ge64
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b, I64); local_set!(b, result_lo_local)

    # an amount of at least 128 gives 0: Julia's lshr_int selects on `shift >= width`
    # (intrinsics.cpp), which the limb shifts above, taking their amount modulo 64, never see
    for r in (result_lo_local, result_hi_local)
        local_get!(b, r); i64_const!(b, 0)
        local_get!(b, n_local); i64_const!(b, 128); num!(b, Opcode.I64_LT_U)
        select!(b, I64); local_set!(b, r)
    end
    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
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
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ashr_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ashr!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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
    select!(b, I64); local_set!(b, result_hi_local)

    # cross = n_mod==0 ? 0 : x_hi << (64 - n_mod)
    i64_const!(b, 0)
    local_get!(b, x_hi_local); i64_const!(b, 64); local_get!(b, n_mod_local); num!(b, Opcode.I64_SUB); num!(b, Opcode.I64_SHL)
    local_get!(b, n_mod_local); num!(b, Opcode.I64_EQZ)
    select!(b, I64); local_set!(b, cross_local)

    # lo_normal = (x_lo >>u n_mod) | cross (stack); lo_ge64 = x_hi >>s n_mod (stack)
    local_get!(b, x_lo_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_U)
    local_get!(b, cross_local); num!(b, Opcode.I64_OR)
    local_get!(b, x_hi_local); local_get!(b, n_mod_local); num!(b, Opcode.I64_SHR_S)
    # result_lo = n<64 ? lo_normal : lo_ge64
    local_get!(b, n_local); i64_const!(b, 64); num!(b, Opcode.I64_LT_U)
    select!(b, I64); local_set!(b, result_lo_local)

    # an amount of at least 128 gives the sign in every bit: Julia's ashr_int selects on `shift >= width`
    # (intrinsics.cpp), which the limb shifts above, taking their amount modulo 64, never see
    for r in (result_lo_local, result_hi_local)
        local_get!(b, r); local_get!(b, sign_local)
        local_get!(b, n_local); i64_const!(b, 128); num!(b, Opcode.I64_LT_U)
        select!(b, I64); local_set!(b, r)
    end
    # Create result struct (typeId, lo, hi)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))  # real classId (was placeholder 0)
    local_get!(b, result_lo_local); local_get!(b, result_hi_local)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""
Emit 128-bit count leading zeros
Stack: [x_struct] -> [result_struct (UInt128)]

Cleaned up dead code from first attempt that wasted 3 locals.
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ctlz_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ctlz!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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
    select!(b, I64)

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

"""
Emit 128-bit count trailing zeros (F11). Stack: [x_struct] -> [result_struct].
tz(x) = lo==0 ? 64 + ctz(hi) : ctz(lo). Mirrors emit_int128_ctlz (lo/hi roles swapped);
the prior code emitted a single i64.ctz on a 128-bit value → invalid wasm.
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `cttz_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_cttz!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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
    select!(b, I64)

    result_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    builder_set_local_type!(b, result_local, I64)
    local_set!(b, result_local)
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, arg_type)))  # real classId (was placeholder 0)
    local_get!(b, result_local)
    i64_const!(b, 0)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""
Emit 128-bit population count (F11). Stack: [x_struct] -> [result_struct].
popcnt(x) = popcnt(lo) + popcnt(hi). The prior code emitted a single i64.popcnt on a
128-bit value → invalid wasm.
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ctpop_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ctpop!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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

"""
Emit 128-bit bitwise NOT (F11). Stack: [x_struct] -> [result_struct].
~x = {~lo, ~hi}. The prior code emitted a single i64.xor -1 on a 128-bit value → invalid
wasm; surfaced via count_zeros (= count_ones(~x)).
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `not_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_not!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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

"""
Emit 128-bit bitwise AND
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `and_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_and!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit 128-bit bitwise OR
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `or_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_or!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit 128-bit bitwise XOR
Stack: [a_struct, b_struct] -> [result_struct]
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `xor_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_xor!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
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

"""
Emit 128-bit equality comparison.
Builder-native: consumes [a_struct, b_struct] from `b`'s stack, pushes i32.
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `eq_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_eq!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
    a_lo, a_hi, b_lo, b_hi = _int128_cmp_operands!(b, ctx, arg_type)
    # (a_lo == b_lo) && (a_hi == b_hi)
    local_get!(b, a_lo); local_get!(b, b_lo); num!(b, Opcode.I64_EQ)
    local_get!(b, a_hi); local_get!(b, b_hi); num!(b, Opcode.I64_EQ)
    num!(b, Opcode.I32_AND)
    return b
end

"""
Emit 128-bit not-equal comparison
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Builder-native (THE implementation).
parity(quarantine: Int128/UInt128 have no dart type — dart's `int` is one i64
(translator.dart:346); Julia's `ne_int` on a 128-bit operand lowers over the two-i64 limb struct.)
"""
function emit_int128_ne!(b::InstrBuilder, ctx, arg_type::Type)::InstrBuilder
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

"""
    get_u128_divrem_function!(mod, registry) -> UInt32

The one runtime helper for 128-bit unsigned division: `(n_lo, n_hi, d_lo, d_hi) -> (q_lo, q_hi,
r_lo, r_hi)` for a divisor that is not zero (its callers test that first). When both high limbs
are zero it is one `i64.div_u` and one `i64.rem_u`; otherwise restoring long division over the
128 bits, one dividend bit per step from the top: the remainder shifts left taking the bit and
subtracts the divisor when it is not below it (unsigned). Before each step the remainder is at
most the dividend's prefix above that bit, so no bit leaves its high limb (dev/formal/
Int128Limbs.tla checks it: the division is exact with no carry-out term). A step's shift of a
limb by `i` relies on wasm taking the amount modulo 64, so `i >= 64` addresses the high limb.
parity(quarantine: dart's int is one i64; Julia lowers `udiv`/`urem` on 128 bits to compiler-rt's
__udivti3/__umodti3, which the helper is.)
"""
function get_u128_divrem_function!(mod::WasmModule, registry::TypeRegistry)::UInt32
    registry.u128_divrem_func_idx !== nothing && return registry.u128_divrem_func_idx
    local params = WasmValType[I64, I64, I64, I64]
    local results = WasmValType[I64, I64, I64, I64]
    local fidx = add_function!(mod, params, results, WasmValType[],
                               UInt8[Opcode.UNREACHABLE, Opcode.END];
                               name=generated_function_name(:udivmodti4))
    registry.u128_divrem_func_idx = fidx
    local b = InstrBuilder(params, results; func_name="u128_divrem", mod=mod)
    local extra = WasmValType[]
    local alloc = w -> (push!(extra, w); builder_add_local!(b, w))
    local n_lo, n_hi, d_lo, d_hi = 0, 1, 2, 3
    local q_lo, q_hi, r_lo, r_hi, i = alloc(I64), alloc(I64), alloc(I64), alloc(I64), alloc(I64)
    local borrow = alloc(I64)
    # both high limbs zero: one-limb division
    local_get!(b, n_hi); num!(b, Opcode.I64_EQZ)
    local_get!(b, d_hi); num!(b, Opcode.I64_EQZ)
    num!(b, Opcode.I32_AND)
    if_!(b)
    local_get!(b, n_lo); local_get!(b, d_lo); num!(b, Opcode.I64_DIV_U); i64_const!(b, 0)
    local_get!(b, n_lo); local_get!(b, d_lo); num!(b, Opcode.I64_REM_U); i64_const!(b, 0)
    return_!(b)
    end_block!(b)
    # long division: i = 127 .. 0
    i64_const!(b, 127); local_set!(b, i)
    local step = loop!(b)
    # r = (r << 1) | bit i of n
    local_get!(b, r_hi); i64_const!(b, 1); num!(b, Opcode.I64_SHL)
    local_get!(b, r_lo); i64_const!(b, 63); num!(b, Opcode.I64_SHR_U)
    num!(b, Opcode.I64_OR); local_set!(b, r_hi)
    local_get!(b, r_lo); i64_const!(b, 1); num!(b, Opcode.I64_SHL)
    local_get!(b, n_hi); local_get!(b, i); num!(b, Opcode.I64_SHR_U)
    local_get!(b, n_lo); local_get!(b, i); num!(b, Opcode.I64_SHR_U)
    local_get!(b, i); i64_const!(b, 64); num!(b, Opcode.I64_GE_U)
    select!(b, I64)
    i64_const!(b, 1); num!(b, Opcode.I64_AND)
    num!(b, Opcode.I64_OR); local_set!(b, r_lo)
    # r >= d (unsigned): not (r_hi <u d_hi or (r_hi == d_hi and r_lo <u d_lo))
    local_get!(b, r_hi); local_get!(b, d_hi); num!(b, Opcode.I64_LT_U)
    local_get!(b, r_hi); local_get!(b, d_hi); num!(b, Opcode.I64_EQ)
    local_get!(b, r_lo); local_get!(b, d_lo); num!(b, Opcode.I64_LT_U)
    num!(b, Opcode.I32_AND)
    num!(b, Opcode.I32_OR)
    num!(b, Opcode.I32_EQZ)
    if_!(b)
    # r -= d
    i64_const!(b, 1); i64_const!(b, 0)
    local_get!(b, r_lo); local_get!(b, d_lo); num!(b, Opcode.I64_LT_U)
    select!(b, I64); local_set!(b, borrow)
    local_get!(b, r_lo); local_get!(b, d_lo); num!(b, Opcode.I64_SUB); local_set!(b, r_lo)
    local_get!(b, r_hi); local_get!(b, d_hi); num!(b, Opcode.I64_SUB)
    local_get!(b, borrow); num!(b, Opcode.I64_SUB); local_set!(b, r_hi)
    # q |= 1 << i, in the limb i addresses
    local_get!(b, i); i64_const!(b, 64); num!(b, Opcode.I64_GE_U)
    if_!(b)
    local_get!(b, q_hi); i64_const!(b, 1); local_get!(b, i); num!(b, Opcode.I64_SHL)
    num!(b, Opcode.I64_OR); local_set!(b, q_hi)
    else_!(b)
    local_get!(b, q_lo); i64_const!(b, 1); local_get!(b, i); num!(b, Opcode.I64_SHL)
    num!(b, Opcode.I64_OR); local_set!(b, q_lo)
    end_block!(b)
    end_block!(b)
    # next bit, while i > 0
    local_get!(b, i); num!(b, Opcode.I64_EQZ); num!(b, Opcode.I32_EQZ)
    if_!(b)
    local_get!(b, i); i64_const!(b, 1); num!(b, Opcode.I64_SUB); local_set!(b, i)
    br!(b, step)
    end_block!(b)
    end_block!(b)
    local_get!(b, q_lo); local_get!(b, q_hi); local_get!(b, r_lo); local_get!(b, r_hi)
    end_block!(b)
    local slot = fidx - num_imported_funcs(mod) + 1
    mod.functions[slot] = WasmFunction(mod.functions[slot].type_idx, extra, builder_code(b);
                                       name=mod.functions[slot].name)
    return fidx
end

"""
    emit_int128_divrem!(b, ctx, T; signed, rem) -> InstrBuilder

Julia's `{s,u}{div,rem}_int` and `checked_{s,u}{div,rem}_int` on a 128-bit operand pair.
Stack: `[a_struct, b_struct] -> [result_struct]`. A zero divisor throws Julia's DivideError, and
so does `typemin ÷ -1` for signed division (intrinsics.cpp: checked_sdiv_int raises unless
`y != 0 && (y != -1 || x != typemin)`; checked_srem_int raises only for `y == 0` and answers 0
for `y == -1`, which division on magnitudes gives). The unchecked intrinsics are undefined in
LLVM on those operands and get the same guard, as the 64-bit ones do (`_emit_div_guard!`).
Signed division runs on the operands' magnitudes: the quotient is negative when the signs
differ, and the remainder takes the dividend's sign (truncating division).

formal(dev/formal/Int128Limbs.tla): the limb algorithms compute Julia's 128-bit intrinsics
exactly for every operand.
parity(quarantine: dart's int is one i64; Int128 and UInt128 are Julia's, over two i64 limbs.)
"""
function emit_int128_divrem!(b::InstrBuilder, ctx, result_type::Type; signed::Bool, rem::Bool)::InstrBuilder
    local type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    local structref = _int128_structref(ctx, result_type)
    local loc! = w -> (i = allocate_local!(ctx, w); builder_set_local_type!(b, i, w); i)
    local sa = loc!(structref)
    local sb = loc!(structref)
    local a_lo, a_hi, b_lo, b_hi = loc!(I64), loc!(I64), loc!(I64), loc!(I64)
    local q_lo, q_hi, r_lo, r_hi = loc!(I64), loc!(I64), loc!(I64), loc!(I64)
    local na = loc!(I32)
    local nb = loc!(I32)
    local_set!(b, sb); local_set!(b, sa)
    for (st, lo, hi) in ((sa, a_lo, a_hi), (sb, b_lo, b_hi))
        local_get!(b, st); struct_get!(b, type_idx, 1, I64); local_set!(b, lo)
        local_get!(b, st); struct_get!(b, type_idx, 2, I64); local_set!(b, hi)
    end
    # DivideError: a zero divisor; signed division of typemin by -1
    local_get!(b, b_lo); local_get!(b, b_hi); num!(b, Opcode.I64_OR); num!(b, Opcode.I64_EQZ)
    if_!(b); _emit_throw_error_struct!(b, ctx, DivideError); end_block!(b)
    if signed && !rem
        local_get!(b, a_lo); num!(b, Opcode.I64_EQZ)
        local_get!(b, a_hi); i64_const!(b, typemin(Int64)); num!(b, Opcode.I64_EQ)
        num!(b, Opcode.I32_AND)
        local_get!(b, b_lo); local_get!(b, b_hi); num!(b, Opcode.I64_AND); i64_const!(b, -1); num!(b, Opcode.I64_EQ)
        num!(b, Opcode.I32_AND)
        if_!(b); _emit_throw_error_struct!(b, ctx, DivideError); end_block!(b)
    end
    # a limb pair negated in place: ~x + 1, the carry into the high limb when the low one is 0
    local neg! = (lo, hi) -> begin
        local_get!(b, hi); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
        i64_const!(b, 1); i64_const!(b, 0); local_get!(b, lo); num!(b, Opcode.I64_EQZ); select!(b, I64)
        num!(b, Opcode.I64_ADD); local_set!(b, hi)
        local_get!(b, lo); i64_const!(b, -1); num!(b, Opcode.I64_XOR)
        i64_const!(b, 1); num!(b, Opcode.I64_ADD); local_set!(b, lo)
    end
    local neg_if! = (flag, lo, hi) -> (local_get!(b, flag); if_!(b); neg!(lo, hi); end_block!(b))
    if signed
        local_get!(b, a_hi); i64_const!(b, 0); num!(b, Opcode.I64_LT_S); local_set!(b, na)
        local_get!(b, b_hi); i64_const!(b, 0); num!(b, Opcode.I64_LT_S); local_set!(b, nb)
        neg_if!(na, a_lo, a_hi); neg_if!(nb, b_lo, b_hi)
    end
    local_get!(b, a_lo); local_get!(b, a_hi); local_get!(b, b_lo); local_get!(b, b_hi)
    call!(b, get_u128_divrem_function!(ctx.mod, ctx.type_registry),
          WasmValType[I64, I64, I64, I64], WasmValType[I64, I64, I64, I64])
    local_set!(b, r_hi); local_set!(b, r_lo); local_set!(b, q_hi); local_set!(b, q_lo)
    local lo, hi = rem ? (r_lo, r_hi) : (q_lo, q_hi)
    if signed
        if rem
            neg_if!(na, lo, hi)
        else
            local_get!(b, na); local_get!(b, nb); num!(b, Opcode.I32_XOR); local_set!(b, na)
            neg_if!(na, lo, hi)
        end
    end
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))
    local_get!(b, lo); local_get!(b, hi)
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end

"""
    emit_int128_bswap!(b, ctx, T) -> InstrBuilder

Julia's `bswap_int` on a 128-bit value: the byte reversal of each limb, with the limbs
exchanged. Stack: `[x_struct] -> [result_struct]`.

formal(dev/formal/Int128Limbs.tla): the limb algorithms compute Julia's 128-bit intrinsics
exactly for every operand.
parity(quarantine: dart's int is one i64; Int128 and UInt128 are Julia's, over two i64 limbs.)
"""
function emit_int128_bswap!(b::InstrBuilder, ctx, result_type::Type)::InstrBuilder
    local type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)
    local structref = _int128_structref(ctx, result_type)
    local loc! = w -> (i = allocate_local!(ctx, w); builder_set_local_type!(b, i, w); i)
    local x = loc!(structref)
    local lo = loc!(I64)
    local hi = loc!(I64)
    local_set!(b, x)
    local_get!(b, x); struct_get!(b, type_idx, 1, I64); local_set!(b, lo)
    local_get!(b, x); struct_get!(b, type_idx, 2, I64); local_set!(b, hi)
    # byte k of the limb moves to byte 7 - k
    local swap! = l -> for k in 0:7
        local_get!(b, l); i64_const!(b, 8k); num!(b, Opcode.I64_SHR_U)
        i64_const!(b, 0xFF); num!(b, Opcode.I64_AND)
        i64_const!(b, 8 * (7 - k)); num!(b, Opcode.I64_SHL)
        k > 0 && num!(b, Opcode.I64_OR)
    end
    i32_const!(b, Int64(ensure_type_id!(ctx.type_registry, result_type)))
    swap!(hi)   # the new low limb
    swap!(lo)   # the new high limb
    struct_new!(b, type_idx, WasmValType[I32, I64, I64])
    return b
end
