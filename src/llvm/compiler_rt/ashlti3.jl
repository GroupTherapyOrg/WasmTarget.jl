# compiler-rt's 128-bit shift left (compiler-rt/lib/builtins/ashlti3.c), the libcall LLVM's
# ExpandIntRes_Shift makes on wasm (src/llvm/legalize_integer_types.jl), emitted in place over the
# operand's halves, SDValues as src/julia/machine.jl records them (sd_get), its twords' s.low and
# s.high each a new i64 local. The builder is `b`, so the C parameter b, the amount, is `c` here: an
# i64 local whose low 32 bits are the C int's.

# Returns: a << c. Precondition: 0 <= c < bits_in_tword
@parity "compiler-rt/lib/builtins/ashlti3.c:21 __ashlti3" function __ashlti3(b::WasmBuilder.InstructionsBuilder, a::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, c::WasmBuilder.IR.Local)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local bits_in_dword = 64
    local (input_low, input_high) = a
    local low = WasmBuilder.add_local(b, i64); local high = WasmBuilder.add_local(b, i64)
    local k(n::Integer) = WasmBuilder.i64_const(b, Int64(n))
    # if (b & bits_in_dword): bits_in_dword <= b < bits_in_tword
    WasmBuilder.local_get(b, c); k(bits_in_dword); WasmBuilder.i64_and(b); k(0); WasmBuilder.i64_ne(b)
    WasmBuilder.if_(b)
    # result.s.low = 0; result.s.high = input.s.low << (b - bits_in_dword)
    k(0); WasmBuilder.local_set(b, low)
    sd_get(b, input_low); WasmBuilder.local_get(b, c); k(bits_in_dword); WasmBuilder.i64_sub(b); WasmBuilder.i64_shl(b); WasmBuilder.local_set(b, high)
    WasmBuilder.else_(b)
    # 0 <= b < bits_in_dword: if (b == 0) return a
    WasmBuilder.local_get(b, c); WasmBuilder.i64_eqz(b)
    WasmBuilder.if_(b)
    sd_get(b, input_low); WasmBuilder.local_set(b, low); sd_get(b, input_high); WasmBuilder.local_set(b, high)
    WasmBuilder.else_(b)
    # result.s.low = input.s.low << b
    sd_get(b, input_low); WasmBuilder.local_get(b, c); WasmBuilder.i64_shl(b); WasmBuilder.local_set(b, low)
    # result.s.high = ((du_int)input.s.high << b) | (input.s.low >> (bits_in_dword - b))
    sd_get(b, input_high); WasmBuilder.local_get(b, c); WasmBuilder.i64_shl(b)
    sd_get(b, input_low); k(bits_in_dword); WasmBuilder.local_get(b, c); WasmBuilder.i64_sub(b); WasmBuilder.i64_shr_u(b)
    WasmBuilder.i64_or(b); WasmBuilder.local_set(b, high)
    WasmBuilder.var"end"(b)
    WasmBuilder.var"end"(b)
    return (low, high)
end
