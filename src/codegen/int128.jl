# ============================================================================
# 128-bit Integer Operation Emitters
# These emit WASM bytecode for 128-bit arithmetic operations.
# 128-bit integers are stored as structs with fields: lo (i64), hi (i64)
# ============================================================================

"""
Emit bytecode for 128-bit addition.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo + b_lo; carry = (result_lo < a_lo); result_hi = a_hi + b_hi + carry
"""
function emit_int128_add(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # We need locals to hold extracted values and struct refs
    # Allocate them dynamically

    # First allocate struct locals so we can pop from stack
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))

    # Then allocate i64 locals for extracted values
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Stack: [a_struct, b_struct]
    # Pop b_struct to a local (b_struct is on top)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    # Now stack: [a_struct]
    # Pop a_struct to a local
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract a_lo, a_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))

    # Extract b_lo, b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))

    # Compute result_lo = a_lo + b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_TEE)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # Compute carry = (result_lo < a_lo) ? 1 : 0  (unsigned comparison)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.I64_LT_U)
    push!(bytes, Opcode.I64_EXTEND_I32_U)  # Convert i32 bool to i64

    # Compute result_hi = a_hi + b_hi + carry
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.I64_ADD)  # a_hi + carry
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_ADD)  # + b_hi

    # Stack: [result_hi]
    # Need: [result_lo, result_hi] for struct.new
    # Save result_hi to local, then push lo, then hi
    hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(hi_local))

    # Stack: [] — push in struct field order: typeId first, then lo, then hi
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(hi_local))

    # Create result struct
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit bytecode for 128-bit subtraction.
Stack: [a_struct, b_struct] -> [result_struct]
Algorithm: result_lo = a_lo - b_lo; borrow = (a_lo < b_lo); result_hi = a_hi - b_hi - borrow
"""
function emit_int128_sub(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # First allocate struct locals so we can pop from stack
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))

    # Allocate i64 locals for extracted values and results
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    borrow_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals (b_struct is on top of stack)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # result_lo = a_lo - b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # borrow = (a_lo < b_lo) ? 1 : 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_LT_U)
    push!(bytes, Opcode.I64_EXTEND_I32_U)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(borrow_local))

    # result_hi = a_hi - b_hi - borrow
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(borrow_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct: (typeId, result_lo, result_hi)
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit bytecode for 128-bit multiplication (low 128 bits only).
Stack: [a_struct, b_struct] -> [result_struct]
Uses the identity: (a_lo + a_hi*2^64) * (b_lo + b_hi*2^64)
= a_lo*b_lo + (a_lo*b_hi + a_hi*b_lo)*2^64 + a_hi*b_hi*2^128
Since we only need low 128 bits: result_lo = low64(a_lo*b_lo), result_hi = high64(a_lo*b_lo) + low64(a_lo*b_hi) + low64(a_hi*b_lo)
"""
function emit_int128_mul(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # WBUILD-5001: Full 128-bit multiplication with carry from lo*lo.
    # WASM has no 64x64→128 multiply, so we use Knuth's Algorithm M with 32-bit halves
    # to compute the upper 64 bits of (a_lo * b_lo). This "carry" was previously missing,
    # causing widemul(UInt64, UInt64) to always return 0 in the hi word.
    #
    # Algorithm (Knuth vol 2, sec 4.3.1):
    #   a0 = a_lo & 0xFFFFFFFF; a1 = a_lo >> 32
    #   b0 = b_lo & 0xFFFFFFFF; b1 = b_lo >> 32
    #   t = a0*b0; k = t >> 32
    #   t = a1*b0 + k; w1 = t & 0xFFFFFFFF; w2 = t >> 32
    #   t = a0*b1 + w1; k = t >> 32
    #   carry = a1*b1 + w2 + k
    #   result_lo = a_lo * b_lo (i64.mul gives low 64 bits)
    #   result_hi = a_lo*b_hi + a_hi*b_lo + carry

    # Extra locals for 32-bit decomposition
    a0_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    a1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b0_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    b1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    t_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    w1_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    w2_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)

    mask32 = Int64(0xFFFFFFFF)

    # a0 = a_lo & 0xFFFFFFFF
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(mask32))
    push!(bytes, Opcode.I64_AND)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(a0_local))

    # a1 = a_lo >> 32 (unsigned)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(32))
    push!(bytes, Opcode.I64_SHR_U)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(a1_local))

    # b0 = b_lo & 0xFFFFFFFF
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(mask32))
    push!(bytes, Opcode.I64_AND)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(b0_local))

    # b1 = b_lo >> 32 (unsigned)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(32))
    push!(bytes, Opcode.I64_SHR_U)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(b1_local))

    # t = a0 * b0; k = t >> 32
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a0_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b0_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(32))
    push!(bytes, Opcode.I64_SHR_U)  # k = (a0*b0) >> 32
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(t_local))  # reuse t for k

    # t = a1 * b0 + k
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a1_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b0_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(t_local))  # k
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(t_local))

    # w1 = t & 0xFFFFFFFF
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(t_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(mask32))
    push!(bytes, Opcode.I64_AND)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(w1_local))

    # w2 = t >> 32
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(t_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(32))
    push!(bytes, Opcode.I64_SHR_U)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(w2_local))

    # t = a0 * b1 + w1; k = t >> 32
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a0_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b1_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(w1_local))
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(32))
    push!(bytes, Opcode.I64_SHR_U)  # k = (a0*b1 + w1) >> 32
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(t_local))  # reuse t for k

    # carry = a1*b1 + w2 + k  (upper 64 bits of a_lo*b_lo)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a1_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b1_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(w2_local))
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(t_local))  # k
    push!(bytes, Opcode.I64_ADD)
    # carry is now on the stack

    # result_lo = a_lo * b_lo (i64.mul gives low 64 bits)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_lo_local))

    # result_hi = a_lo*b_hi + a_hi*b_lo + carry
    # carry is still on stack from above
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit negation: -x = ~x + 1 = (0, 0) - x
Stack: [x_struct] -> [result_struct]
"""
function emit_int128_neg(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    x_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop struct to local
    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract fields
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(2))  # hi (offset by 1 for typeId at field 0)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))

    # Two's complement negation: -x = ~x + 1
    # result_lo = ~x_lo + 1
    # result_hi = ~x_hi + carry
    # where carry = 1 if ~x_lo overflows when adding 1 (i.e., x_lo == 0)

    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # ~x_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CONST)
    push!(bytes, 0x7F)  # -1 in LEB128
    push!(bytes, Opcode.I64_XOR)

    # +1
    push!(bytes, Opcode.I64_CONST)
    push!(bytes, 0x01)
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # carry = (x_lo == 0) ? 1 : 0
    # ~x_hi + carry
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CONST)
    push!(bytes, 0x7F)  # -1
    push!(bytes, Opcode.I64_XOR)

    # Add carry if x_lo was 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_EQZ)
    push!(bytes, Opcode.I64_EXTEND_I32_U)  # Convert i32 bool to i64
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit signed less than: a < b (signed)
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
"""
function emit_int128_slt(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # Signed 128-bit comparison: a < b
    # if a_hi < b_hi (signed): true
    # if a_hi > b_hi (signed): false
    # if a_hi == b_hi: a_lo < b_lo (unsigned, since lo is always unsigned)

    # (a_hi < b_hi) || (a_hi == b_hi && a_lo < b_lo)
    # Using: (a_hi <_s b_hi) | ((a_hi == b_hi) & (a_lo <_u b_lo))

    # a_hi < b_hi (signed)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_LT_S)

    # a_hi == b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_EQ)

    # a_lo < b_lo (unsigned)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_LT_U)

    # (a_hi == b_hi) && (a_lo < b_lo)
    push!(bytes, Opcode.I32_AND)

    # (a_hi < b_hi) || ((a_hi == b_hi) && (a_lo < b_lo))
    push!(bytes, Opcode.I32_OR)

    return bytes
end

"""
Emit 128-bit unsigned less than: a < b (unsigned)
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
"""
function emit_int128_ult(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # Unsigned comparison: (a_hi < b_hi) || (a_hi == b_hi && a_lo < b_lo)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_LT_U)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_EQ)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_LT_U)

    push!(bytes, Opcode.I32_AND)
    push!(bytes, Opcode.I32_OR)

    return bytes
end

"""
Emit 128-bit signed less-or-equal: a <=_s b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_s b) || (a == b)
"""
function emit_int128_sle(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Pop b and a to struct locals (so we can use each twice)
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Push a and b for slt check
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    # a <_s b (reuse emit_int128_slt)
    append!(bytes, emit_int128_slt(ctx, arg_type))

    # Push a and b for eq check
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    # a == b (reuse emit_int128_eq)
    append!(bytes, emit_int128_eq(ctx, arg_type))

    # (a < b) || (a == b)
    push!(bytes, Opcode.I32_OR)

    return bytes
end

"""
Emit 128-bit unsigned less-or-equal: a <=_u b
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
Implementation: (a <_u b) || (a == b)
"""
function emit_int128_ule(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Pop b and a to struct locals (so we can use each twice)
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Push a and b for ult check
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    # a <_u b (reuse emit_int128_ult)
    append!(bytes, emit_int128_ult(ctx, arg_type))

    # Push a and b for eq check
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    # a == b (reuse emit_int128_eq)
    append!(bytes, emit_int128_eq(ctx, arg_type))

    # (a < b) || (a == b)
    push!(bytes, Opcode.I32_OR)

    return bytes
end

"""
Emit 128-bit left shift: x << n (where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

WBUILD-5001: WASM shift amounts are mod 64, so i64.shl(x, 64) = i64.shl(x, 0) = x.
Must handle n >= 64 and n == 0 edge cases with select.

select(val1, val2, cond): cond != 0 → val1 (deeper), cond == 0 → val2 (shallower)
"""
function emit_int128_shl(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    n_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    n_mod_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    cross_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)

    # Pop n and x_struct
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_hi_local))

    # n_mod = n & 63
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(63))
    push!(bytes, Opcode.I64_AND)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(n_mod_local))

    # --- result_lo = n >= 64 ? 0 : (x_lo << n_mod) ---
    # select(val1=0, val2=x_lo<<n_mod, cond=n>=64) → n>=64 ? 0 : x_lo<<n_mod
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(0))  # val1: 0

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHL)  # val2: x_lo << n_mod

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.I64_GE_U)  # cond: n >= 64

    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_lo_local))

    # --- cross = n_mod == 0 ? 0 : x_lo >> (64 - n_mod) ---
    # When n_mod=0, (64-n_mod)=64 which wraps to 0 in WASM, giving x_lo instead of 0
    # select(val1=0, val2=x_lo>>(64-n_mod), cond=n_mod==0)
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(0))  # val1: 0

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.I64_SHR_U)  # val2: x_lo >> (64 - n_mod)

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_EQZ)  # cond: n_mod == 0

    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(cross_local))

    # --- hi_normal = (x_hi << n_mod) | cross ---
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHL)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(cross_local))
    push!(bytes, Opcode.I64_OR)
    # hi_normal is on stack

    # --- hi_ge64 = x_lo << n_mod ---
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHL)
    # hi_ge64 is on stack

    # --- result_hi = n >= 64 ? hi_ge64 : hi_normal ---
    # Stack: [hi_normal, hi_ge64]
    # select(val1=hi_normal, val2=hi_ge64, cond) — but we need val1=hi_ge64 when cond true
    # Swap: push hi_ge64 first (val1), then hi_normal (val2)
    # But stack already has [hi_normal, hi_ge64] — need to use locals
    # Save hi_ge64 and hi_normal to rearrange
    # Actually easier: save hi_normal before computing hi_ge64

    # Let me redo: save hi_normal to a local first
    bytes_len = length(bytes)  # checkpoint
    # Undo the last few pushes — we need to restructure
    # Actually I can't easily undo bytecode. Let me use a temporary local.

    # hi_ge64 is on top of stack, hi_normal is below it. I need:
    # select(val1=hi_ge64, val2=hi_normal, cond=n>=64) → n>=64 ? hi_ge64 : hi_normal
    # But stack order is [hi_normal, hi_ge64, ...]. After pushing cond:
    # [hi_normal, hi_ge64, cond] → select returns cond!=0 ? hi_normal : hi_ge64
    # That's backwards! We want n>=64 ? hi_ge64 : hi_normal
    # But select gives us n>=64 ? hi_normal (val1=deeper) : hi_ge64 (val2=shallower)
    # So we need to swap the stack order, or negate the condition.

    # Easiest: negate the condition. n < 64 instead of n >= 64.
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.I64_LT_U)  # cond: n < 64

    # select(val1=hi_normal, val2=hi_ge64, cond=n<64) → n<64 ? hi_normal : hi_ge64 ✓
    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct
    push!(bytes, Opcode.I32_CONST); push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(result_hi_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit logical right shift: x >> n (unsigned, where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]

WBUILD-5001: Same mod-64 edge case handling as emit_int128_shl.
"""
function emit_int128_lshr(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    n_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    n_mod_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    cross_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)

    # Pop n and x_struct
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_hi_local))

    # n_mod = n & 63
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(63))
    push!(bytes, Opcode.I64_AND)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(n_mod_local))

    # --- result_hi = n >= 64 ? 0 : (x_hi >> n_mod) ---
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(0))  # val1: 0

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHR_U)  # val2: x_hi >> n_mod

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.I64_GE_U)  # cond: n >= 64

    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_hi_local))

    # --- cross = n_mod == 0 ? 0 : x_hi << (64 - n_mod) ---
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(0))  # val1: 0

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.I64_SHL)  # val2: x_hi << (64 - n_mod)

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_EQZ)  # cond: n_mod == 0

    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(cross_local))

    # --- lo_normal = (x_lo >> n_mod) | cross ---
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHR_U)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(cross_local))
    push!(bytes, Opcode.I64_OR)
    # lo_normal on stack

    # --- lo_ge64 = x_hi >> n_mod ---
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_mod_local))
    push!(bytes, Opcode.I64_SHR_U)
    # lo_ge64 on stack

    # --- result_lo = n < 64 ? lo_normal : lo_ge64 ---
    # Stack: [lo_normal, lo_ge64]. select(val1=lo_normal, val2=lo_ge64, cond)
    # cond = n < 64 → returns lo_normal when true, lo_ge64 when false ✓
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.I64_LT_U)

    push!(bytes, Opcode.SELECT)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_lo_local))

    # Create result struct
    push!(bytes, Opcode.I32_CONST); push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(result_lo_local))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(result_hi_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit count leading zeros
Stack: [x_struct] -> [result_struct (UInt128)]

WBUILD-5001: Cleaned up dead code from first attempt that wasted 3 locals.
"""
function emit_int128_ctlz(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    x_lo_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    clz_hi_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)

    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx)); append!(bytes, encode_leb128_unsigned(2))
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(x_hi_local))

    # clz(x_hi) → store
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CLZ)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(clz_hi_local))

    # select(val1=64+clz(lo), val2=clz(hi), cond=hi==0)
    # → hi==0 ? 64+clz(lo) : clz(hi) ✓
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(64))
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CLZ)
    push!(bytes, Opcode.I64_ADD)  # val1: 64 + clz(lo)

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(clz_hi_local))  # val2: clz(hi)

    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_EQZ)  # cond: hi == 0

    push!(bytes, Opcode.SELECT)

    # Wrap i64 result in UInt128 struct (lo=clz_result, hi=0)
    result_local = length(ctx.locals) + ctx.n_params; push!(ctx.locals, I64)
    push!(bytes, Opcode.LOCAL_SET); append!(bytes, encode_leb128_unsigned(result_local))

    push!(bytes, Opcode.I32_CONST); push!(bytes, 0x00)
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(result_local))
    push!(bytes, Opcode.I64_CONST); append!(bytes, encode_leb128_signed(0))
    push!(bytes, Opcode.GC_PREFIX); push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit bitwise AND
Stack: [a_struct, b_struct] -> [result_struct]
"""
function emit_int128_and(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # typeId for struct
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0

    # result_lo = a_lo & b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_AND)

    # result_hi = a_hi & b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_AND)

    # Create result struct
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit bitwise OR
Stack: [a_struct, b_struct] -> [result_struct]
"""
function emit_int128_or(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # typeId for struct
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0

    # result_lo = a_lo | b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_OR)

    # result_hi = a_hi | b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_OR)

    # Create result struct
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit bitwise XOR
Stack: [a_struct, b_struct] -> [result_struct]
"""
function emit_int128_xor(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # typeId for struct
    push!(bytes, Opcode.I32_CONST)
    push!(bytes, 0x00)  # typeId = 0

    # result_lo = a_lo ^ b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_XOR)

    # result_hi = a_hi ^ b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_XOR)

    # Create result struct
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(type_idx))

    return bytes
end

"""
Emit 128-bit equality comparison
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
"""
function emit_int128_eq(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # (a_lo == b_lo) && (a_hi == b_hi)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_EQ)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_EQ)

    push!(bytes, Opcode.I32_AND)

    return bytes
end

"""
Emit 128-bit not-equal comparison
Stack: [a_struct, b_struct] -> [i32 result (0 or 1)]
"""
function emit_int128_ne(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Allocate locals
    a_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    a_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    b_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop structs to locals
    b_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))

    a_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))

    # Extract fields
    for (struct_local, lo_local, hi_local) in [(a_struct_local, a_lo_local, a_hi_local),
                                                (b_struct_local, b_lo_local, b_hi_local)]
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))  # lo field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(2))  # hi field (offset by 1 for typeId at field 0)
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # (a_lo != b_lo) || (a_hi != b_hi)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_NE)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_NE)

    push!(bytes, Opcode.I32_OR)

    return bytes
end

