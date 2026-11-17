# compiler-rt's 128-bit product (compiler-rt/lib/builtins/multi3.c), the libcall LLVM's
# ExpandIntRes_MUL makes on wasm (src/llvm/legalize_integer_types.jl), emitted in place over the
# operands' halves, SDValues as src/julia/machine.jl records them (sd_get), its twords' s.low and
# s.high each a new i64 local. The builder is `b`, so the C parameter b is `c` here.

# Returns: a * c, the full 128-bit product of two 64-bit halves, by their 32-bit pieces
@parity "compiler-rt/lib/builtins/multi3.c:19 __mulddi3" function __mulddi3(b::WasmBuilder.InstructionsBuilder, a::Union{WasmBuilder.IR.Local,Int64}, c::Union{WasmBuilder.IR.Local,Int64})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local get(v::Union{WasmBuilder.IR.Local,Int64}) = sd_get(b, v)
    local k(n::Integer) = WasmBuilder.i64_const(b, Int64(n))
    local bits_in_dword_2 = 32
    local lower_mask = 0xffffffff
    local low = WasmBuilder.add_local(b, i64); local high = WasmBuilder.add_local(b, i64); local t = WasmBuilder.add_local(b, i64)
    local lget(v::WasmBuilder.IR.Local) = WasmBuilder.local_get(b, v)
    local lset(v::WasmBuilder.IR.Local) = WasmBuilder.local_set(b, v)
    # r.s.low = (a & lower_mask) * (b & lower_mask)
    get(a); k(lower_mask); WasmBuilder.i64_and(b); get(c); k(lower_mask); WasmBuilder.i64_and(b); WasmBuilder.i64_mul(b); lset(low)
    # du_int t = r.s.low >> bits_in_dword_2
    lget(low); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); lset(t)
    # r.s.low &= lower_mask
    lget(low); k(lower_mask); WasmBuilder.i64_and(b); lset(low)
    # t += (a >> bits_in_dword_2) * (b & lower_mask)
    lget(t); get(a); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); get(c); k(lower_mask); WasmBuilder.i64_and(b); WasmBuilder.i64_mul(b); WasmBuilder.i64_add(b); lset(t)
    # r.s.low += (t & lower_mask) << bits_in_dword_2
    lget(low); lget(t); k(lower_mask); WasmBuilder.i64_and(b); k(bits_in_dword_2); WasmBuilder.i64_shl(b); WasmBuilder.i64_add(b); lset(low)
    # r.s.high = t >> bits_in_dword_2
    lget(t); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); lset(high)
    # t = r.s.low >> bits_in_dword_2
    lget(low); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); lset(t)
    # r.s.low &= lower_mask
    lget(low); k(lower_mask); WasmBuilder.i64_and(b); lset(low)
    # t += (b >> bits_in_dword_2) * (a & lower_mask)
    lget(t); get(c); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); get(a); k(lower_mask); WasmBuilder.i64_and(b); WasmBuilder.i64_mul(b); WasmBuilder.i64_add(b); lset(t)
    # r.s.low += (t & lower_mask) << bits_in_dword_2
    lget(low); lget(t); k(lower_mask); WasmBuilder.i64_and(b); k(bits_in_dword_2); WasmBuilder.i64_shl(b); WasmBuilder.i64_add(b); lset(low)
    # r.s.high += t >> bits_in_dword_2
    lget(high); lget(t); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); WasmBuilder.i64_add(b); lset(high)
    # r.s.high += (a >> bits_in_dword_2) * (b >> bits_in_dword_2)
    lget(high); get(a); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); get(c); k(bits_in_dword_2); WasmBuilder.i64_shr_u(b); WasmBuilder.i64_mul(b); WasmBuilder.i64_add(b); lset(high)
    return (low, high)
end

# Returns: a * c, the low 128 bits: the low halves' full product, its high half plus the cross
# products' low halves
@parity "compiler-rt/lib/builtins/multi3.c:40 __multi3" function __multi3(b::WasmBuilder.InstructionsBuilder, a::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, c::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local (x_low, x_high), (y_low, y_high) = a, c
    # r.all = __mulddi3(x.s.low, y.s.low)
    local (low, high) = __mulddi3(b, x_low, y_low)
    # r.s.high += x.s.high * y.s.low + x.s.low * y.s.high
    WasmBuilder.local_get(b, high)
    sd_get(b, x_high); sd_get(b, y_low); WasmBuilder.i64_mul(b)
    sd_get(b, x_low); sd_get(b, y_high); WasmBuilder.i64_mul(b)
    WasmBuilder.i64_add(b); WasmBuilder.i64_add(b)
    WasmBuilder.local_set(b, high)
    return (low, high)
end
