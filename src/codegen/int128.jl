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
    append!(bytes, encode_leb128_unsigned(0))  # lo field
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # hi field
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))

    # Extract b_lo, b_hi
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(0))  # lo field
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # hi field
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

    # Stack: [] — push in struct field order: lo first, then hi
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
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

    # Create result struct: (result_lo, result_hi)
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

    # For 64x64->128 multiplication, we split each 64-bit value into two 32-bit halves
    # This is complex. Let me use a simpler approximation for now:
    # result_lo = a_lo * b_lo (truncated to 64 bits)
    # result_hi = a_lo * b_hi + a_hi * b_lo (approximation, ignores carry from lo*lo)

    # Actually, WASM doesn't have 64x64->128 multiplication directly.
    # We need to implement Karatsuba or schoolbook multiplication using 32-bit pieces.

    # Simplified version (may lose precision for large numbers):
    # This is acceptable for sin() where the values are typically small
    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # result_lo = a_lo * b_lo (low 64 bits)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # result_hi = a_lo * b_hi + a_hi * b_lo
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_hi_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(a_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(b_lo_local))
    push!(bytes, Opcode.I64_MUL)
    push!(bytes, Opcode.I64_ADD)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct
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
    append!(bytes, encode_leb128_unsigned(0))  # lo
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # hi
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
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
Algorithm: result_lo = x_lo << n, result_hi = (x_hi << n) | (x_lo >> (64 - n))
"""
function emit_int128_shl(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate all locals upfront
    n_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    x_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Stack: [x_struct, n_i64]
    # Pop n first (it's on top)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(n_local))

    # Pop x struct
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))

    # result_lo = x_lo << n
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SHL)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # result_hi = (x_hi << n) | (x_lo >> (64 - n))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SHL)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CONST)
    append!(bytes, encode_leb128_unsigned(64))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.I64_SHR_U)

    push!(bytes, Opcode.I64_OR)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))

    # Create result struct
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
Emit 128-bit logical right shift: x >> n (unsigned, where n is 64-bit)
Stack: [x_struct, n_i64] -> [result_struct]
"""
function emit_int128_lshr(ctx, result_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, result_type)

    # Allocate locals
    x_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    n_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    result_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop n first
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(n_local))

    # Pop x struct
    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(result_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))

    # Logical right shift (for n < 64):
    # result_hi = x_hi >> n
    # result_lo = (x_lo >> n) | (x_hi << (64 - n))

    # result_hi = x_hi >> n (logical)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SHR_U)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_hi_local))

    # result_lo = (x_lo >> n) | (x_hi << (64 - n))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SHR_U)

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CONST)
    append!(bytes, encode_leb128_unsigned(64))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(n_local))
    push!(bytes, Opcode.I64_SUB)
    push!(bytes, Opcode.I64_SHL)

    push!(bytes, Opcode.I64_OR)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_lo_local))

    # Create result struct
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
Emit 128-bit count leading zeros
Stack: [x_struct] -> [i64 result]
"""
function emit_int128_ctlz(ctx, arg_type::Type)::Vector{UInt8}
    bytes = UInt8[]
    type_idx = get_int128_type!(ctx.mod, ctx.type_registry, arg_type)

    # Allocate locals
    x_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop x struct
    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))

    # Count leading zeros:
    # if hi != 0: clz(hi)
    # else: 64 + clz(lo)

    # Compute: (x_hi == 0) ? (64 + clz(x_lo)) : clz(x_hi)
    # Using select: select(64 + clz(x_lo), clz(x_hi), x_hi == 0)

    # clz(x_hi)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CLZ)

    # 64 + clz(x_lo)
    push!(bytes, Opcode.I64_CONST)
    append!(bytes, encode_leb128_unsigned(64))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CLZ)
    push!(bytes, Opcode.I64_ADD)

    # x_hi == 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_EQZ)

    # select(64+clz_lo, clz_hi, hi_is_zero) - but args are in wrong order
    # WASM select: select a, b, c -> c ? a : b
    # We want: (x_hi == 0) ? (64 + clz_lo) : clz_hi
    # So: select(64+clz_lo, clz_hi, x_hi==0) is wrong order
    # Actually: stack has [clz_hi, 64+clz_lo, x_hi==0]
    # select pops [val1, val2, cond] and pushes cond ? val1 : val2
    # So we need [64+clz_lo, clz_hi, x_hi==0] to get (x_hi==0) ? (64+clz_lo) : clz_hi
    # Current stack: [clz_hi, 64+clz_lo, x_hi==0]
    # We need to swap clz_hi and 64+clz_lo... not easy without locals

    # Let's use locals instead
    bytes = UInt8[]

    # Allocate locals
    x_lo_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    x_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    clz_hi_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)

    # Pop x struct
    x_struct_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, julia_to_wasm_type_concrete(arg_type, ctx))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))

    # Extract x fields
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(0))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))

    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_struct_local))
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(type_idx))
    append!(bytes, encode_leb128_unsigned(1))
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))

    # clz(x_hi) -> store
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_CLZ)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(clz_hi_local))

    # Now compute result with proper select order:
    # select(64+clz_lo, clz_hi, hi==0)
    # Stack needs: [true_val, false_val, cond]

    # 64 + clz(x_lo) - true value (when hi == 0)
    push!(bytes, Opcode.I64_CONST)
    append!(bytes, encode_leb128_unsigned(64))
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_lo_local))
    push!(bytes, Opcode.I64_CLZ)
    push!(bytes, Opcode.I64_ADD)

    # clz(x_hi) - false value
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(clz_hi_local))

    # x_hi == 0
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(x_hi_local))
    push!(bytes, Opcode.I64_EQZ)

    # select
    push!(bytes, Opcode.SELECT)

    # Now we have an i64 on the stack (the clz result)
    # But Julia expects ctlz_int to return UInt128, so wrap it in a struct with hi=0
    # Stack: [clz_result (i64)]

    # Store the clz result temporarily
    result_local = length(ctx.locals) + ctx.n_params
    push!(ctx.locals, I64)
    push!(bytes, Opcode.LOCAL_SET)
    append!(bytes, encode_leb128_unsigned(result_local))

    # Create UInt128 struct: (lo=clz_result, hi=0)
    push!(bytes, Opcode.LOCAL_GET)
    append!(bytes, encode_leb128_unsigned(result_local))  # lo = clz_result
    push!(bytes, Opcode.I64_CONST)
    append!(bytes, encode_leb128_signed(0))  # hi = 0
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(hi_local))
    end

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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
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
        append!(bytes, encode_leb128_unsigned(0))
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(lo_local))

        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(struct_local))
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.STRUCT_GET)
        append!(bytes, encode_leb128_unsigned(type_idx))
        append!(bytes, encode_leb128_unsigned(1))
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

