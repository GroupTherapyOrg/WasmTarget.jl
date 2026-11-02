# LLVM's type legalizer's expansion of an integer too wide for the target into two halves of the
# legal width (llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp, DAGTypeLegalizer's
# ExpandIntegerResult and ExpandIntegerOperand): on wasm an i128 is TypeExpandInteger into two i64,
# which src/intrinsics.jl's int128 arm holds as its class's two fields. Each expansion here is the one
# LegalizeIntegerTypes.cpp names, its branches in its order, over SDValues as src/julia/machine.jl
# records them (sd_get): a constant half an Int64, any other value the local holding it, each result
# a new local of the function being written. A branch that turns on a fact of the target is taken as
# LLVM's WebAssembly backend sets it:
#   - booleans are ZeroOrOneBooleanContent (llvm/lib/Target/WebAssembly/WebAssemblyISelLowering.cpp:54)
#   - UADDO, USUBO, UADDO_CARRY, USUBO_CARRY and SETCCCARRY are Expand: TargetLoweringBase.cpp:1168
#     and :1173's defaults, which WebAssembly overrides only with the wide-arithmetic feature
#     (WebAssemblyISelLowering.cpp:186), never enabled in a module WasmTarget writes
#   - ADDC, ADDE, SUBC, SUBE, SHL_PARTS, SRA_PARTS, SRL_PARTS, MULHU, MULHS, UMUL_LOHI and SMUL_LOHI
#     are Expand (WebAssemblyISelLowering.cpp:176)
#   - FSHL and FSHR are Expand, TargetLoweringBase.cpp:1141's default
#   - a shift's amount is an i32 where the type is wider than 64 bits (WebAssemblyISelLowering.cpp:493
#     getScalarShiftAmountTy), and the shift strategy of a one-step expansion is ExpandToParts
#     (llvm/include/llvm/CodeGen/TargetLowering.h:1115 preferredShiftLegalizationStrategy)
# What has no counterpart: DAG.computeKnownBits, and the folds of TargetLowering::SimplifySetCC that read
# an operand's own node (src/llvm/target_lowering.jl names each), read facts of a DAG that Julia's IR
# does not build. WasmTarget knows a value only as a literal (a constant SDValue), so each branch they
# decide is taken where the operands are literals and named where it is not taken.

# The halves of a constant: its low bits, and its bits shifted down by the half's width
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4296 DAGTypeLegalizer::ExpandIntRes_Constant" function expand_int_res_constant(cst::Union{Int128,UInt128})::Tuple{Int64,Int64}
    return (cst % Int64, (cst >>> 64) % Int64)
end

# ADD and SUB over the halves. HasOpCarry (UADDO_CARRY, USUBO_CARRY), hasCarry (ADDC, SUBC) and hasOVF
# (UADDO, USUBO) are each false on wasm (above), so the carry is the low halves' compare
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:3905 DAGTypeLegalizer::ExpandIntRes_ADDSUB" function expand_int_res_addsub(b::WasmBuilder.InstructionsBuilder, is_add::Bool, lhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, rhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local (lhsl, lhsh), (rhsl, rhsh) = lhs, rhs
    local lo = WasmBuilder.add_local(b, i64); local hi = WasmBuilder.add_local(b, i64)
    if is_add
        sd_get(b, lhsl); sd_get(b, rhsl); WasmBuilder.i64_add(b); WasmBuilder.local_set(b, lo)
        # Special case: X+1 has a carry out if X+1==0. Adding all ones carries where X != 0, or, all
        # ones in both halves, where X == 0. Any other sum carries where it is below an addend
        local cmp = rhsl === Int64(1) ? get_set_cc(b, lo, Int64(0), :SETEQ) :
            rhsl === Int64(-1) ? get_set_cc(b, lhsl, Int64(0), rhsh === Int64(-1) ? :SETEQ : :SETNE) :
            get_set_cc(b, lo, lhsl, :SETULT)
        # the carry: the compare zero-extended (ZeroOrOneBooleanContent)
        local carry = WasmBuilder.add_local(b, i64)
        WasmBuilder.local_get(b, cmp); WasmBuilder.i64_extend_i32_u(b); WasmBuilder.local_set(b, carry)
        if rhsl === Int64(-1) && rhsh === Int64(-1)
            sd_get(b, lhsh); WasmBuilder.local_get(b, carry); WasmBuilder.i64_sub(b)
        else
            sd_get(b, lhsh); sd_get(b, rhsh); WasmBuilder.i64_add(b); WasmBuilder.local_get(b, carry); WasmBuilder.i64_add(b)
        end
        WasmBuilder.local_set(b, hi)
    else
        sd_get(b, lhsl); sd_get(b, rhsl); WasmBuilder.i64_sub(b); WasmBuilder.local_set(b, lo)
        # the borrow: the low minuend below the subtrahend, unsigned, zero-extended
        local cmp = get_set_cc(b, lhsl, rhsl, :SETULT)
        sd_get(b, lhsh); sd_get(b, rhsh); WasmBuilder.i64_sub(b)
        WasmBuilder.local_get(b, cmp); WasmBuilder.i64_extend_i32_u(b); WasmBuilder.i64_sub(b)
        WasmBuilder.local_set(b, hi)
    end
    return (lo, hi)
end

# AND, OR and XOR, each half's. An OR's disjoint flag is kept by LLVM for later combines; wasm's or
# reads none
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4695 DAGTypeLegalizer::ExpandIntRes_Logical" function expand_int_res_logical(b::WasmBuilder.InstructionsBuilder, opcode::Symbol, lhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, rhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local (ll, lh), (rl, rh) = lhs, rhs
    local op() = opcode === :AND ? WasmBuilder.i64_and(b) : opcode === :OR ? WasmBuilder.i64_or(b) : opcode === :XOR ? WasmBuilder.i64_xor(b) :
        reject!(Internal("llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4695 DAGTypeLegalizer::ExpandIntRes_Logical: $opcode is no logical opcode"), "DAGTypeLegalizer::ExpandIntRes_Logical")
    local lo = WasmBuilder.add_local(b, i64); local hi = WasmBuilder.add_local(b, i64)
    sd_get(b, ll); sd_get(b, rl); op(); WasmBuilder.local_set(b, lo)
    sd_get(b, lh); sd_get(b, rh); op(); WasmBuilder.local_set(b, hi)
    return (lo, hi)
end

# BSWAP: the operand's halves exchanged, each byte-swapped by `bswap_half`, the BSWAP of an i64, which
# is Expand on wasm (WebAssemblyISelLowering.cpp:176) and so its own expansion (TargetLowering.cpp
# expandBSWAP, the code generator's i64 byte swap)
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4277 DAGTypeLegalizer::ExpandIntRes_BSWAP" function expand_int_res_bswap(b::WasmBuilder.InstructionsBuilder, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, bswap_half::Function)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    # Note swapped operands
    local (hi_in, lo_in) = x
    local lo = WasmBuilder.add_local(b, i64); local hi = WasmBuilder.add_local(b, i64)
    sd_get(b, lo_in); bswap_half(); WasmBuilder.local_set(b, lo)
    sd_get(b, hi_in); bswap_half(); WasmBuilder.local_set(b, hi)
    return (lo, hi)
end

# CTLZ: Hi != 0 ? ctlz(Hi) : ctlz(Lo) + 64, the high half zero. wasm's i64.clz answers 64 for zero, so
# CTLZ and CTLZ_ZERO_POISON are both it
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4363 DAGTypeLegalizer::ExpandIntRes_CTLZ" function expand_int_res_ctlz(b::WasmBuilder.InstructionsBuilder, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,Int64}
    local i64 = WasmBuilder.IR.NumType_i64
    local (lo, hi) = x
    local hi_not_zero = get_set_cc(b, hi, Int64(0), :SETNE)
    local lo_lz = WasmBuilder.add_local(b, i64); local hi_lz = WasmBuilder.add_local(b, i64); local sum = WasmBuilder.add_local(b, i64)
    sd_get(b, lo); WasmBuilder.i64_clz(b); WasmBuilder.local_set(b, lo_lz)
    sd_get(b, hi); WasmBuilder.i64_clz(b); WasmBuilder.local_set(b, hi_lz)
    WasmBuilder.local_get(b, lo_lz); WasmBuilder.i64_const(b, Int64(64)); WasmBuilder.i64_add(b); WasmBuilder.local_set(b, sum)
    return (get_select(b, i64, hi_not_zero, hi_lz, sum), Int64(0))
end

# CTPOP: ctpop(Hi) + ctpop(Lo), the high half zero. The libcall branch serves a target whose CTPOP
# action is LibCall; WebAssembly sets none
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4414 DAGTypeLegalizer::ExpandIntRes_CTPOP" function expand_int_res_ctpop(b::WasmBuilder.InstructionsBuilder, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,Int64}
    local (lo, hi) = x
    local r = WasmBuilder.add_local(b, WasmBuilder.IR.NumType_i64)
    sd_get(b, lo); WasmBuilder.i64_popcnt(b); sd_get(b, hi); WasmBuilder.i64_popcnt(b); WasmBuilder.i64_add(b)
    WasmBuilder.local_set(b, r)
    return (r, Int64(0))
end

# CTTZ: Lo != 0 ? cttz(Lo) : cttz(Hi) + 64, the high half zero; wasm's i64.ctz answers 64 for zero
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4445 DAGTypeLegalizer::ExpandIntRes_CTTZ" function expand_int_res_cttz(b::WasmBuilder.InstructionsBuilder, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,Int64}
    local i64 = WasmBuilder.IR.NumType_i64
    local (lo, hi) = x
    local lo_not_zero = get_set_cc(b, lo, Int64(0), :SETNE)
    local lo_lz = WasmBuilder.add_local(b, i64); local hi_lz = WasmBuilder.add_local(b, i64); local sum = WasmBuilder.add_local(b, i64)
    sd_get(b, lo); WasmBuilder.i64_ctz(b); WasmBuilder.local_set(b, lo_lz)
    sd_get(b, hi); WasmBuilder.i64_ctz(b); WasmBuilder.local_set(b, hi_lz)
    WasmBuilder.local_get(b, hi_lz); WasmBuilder.i64_const(b, Int64(64)); WasmBuilder.i64_add(b); WasmBuilder.local_set(b, sum)
    return (get_select(b, i64, lo_not_zero, lo_lz, sum), Int64(0))
end

# MUL: TLI.expandMUL needs MULHU or UMUL_LOHI legal or custom, neither on wasm (above), so the libcall
# RTLIB::getMUL(i128) names, compiler-rt's __multi3, here emitted in place
# (src/llvm/compiler_rt/multi3.jl). forceExpandMultiply serves a target with no such libcall; wasm's
# runtime library has it
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:4710 DAGTypeLegalizer::ExpandIntRes_MUL" function expand_int_res_mul(b::WasmBuilder.InstructionsBuilder, lhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, rhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    return __multi3(b, lhs, rhs)
end

# SDIV, SREM, UDIV and UREM: SDIVREM and UDIVREM of an i128 keep TargetLoweringBase.cpp:1063
# initActions's default, every operation Legal (its memset of OpActions to 0), which no WebAssembly
# setOperationAction overrides (WebAssemblyISelLowering.cpp:176 sets i32's and i64's only): not Custom, so each is the libcall RTLIB names for an i128 (SDIV_I128, SREM_I128, UDIV_I128,
# UREM_I128: compiler-rt's __divti3, __modti3, __udivti3 and __umodti3), made by `make_lib_call`
# (TargetLowering::makeLibCall: the caller's call of the routine and SplitInteger of its result). A
# constant divisor of UDIV and UREM first tries TLI.expandDIVREMByConstant, which needs MULHU or
# UMUL_LOHI legal or custom on the half (TargetLowering.cpp:8583), neither on wasm, so it declines
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5086 DAGTypeLegalizer::ExpandIntRes_SDIV" function expand_int_res_sdiv(ops::Tuple{Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, make_lib_call::Function)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    return make_lib_call(:SDIV_I128, ops)
end

@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5388 DAGTypeLegalizer::ExpandIntRes_SREM" function expand_int_res_srem(ops::Tuple{Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, make_lib_call::Function)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    return make_lib_call(:SREM_I128, ops)
end

@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5549 DAGTypeLegalizer::ExpandIntRes_UDIV" function expand_int_res_udiv(ops::Tuple{Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, make_lib_call::Function)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    return make_lib_call(:UDIV_I128, ops)
end

@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5584 DAGTypeLegalizer::ExpandIntRes_UREM" function expand_int_res_urem(ops::Tuple{Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, make_lib_call::Function)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    return make_lib_call(:UREM_I128, ops)
end

# SHL, SRL and SRA. A constant amount: ExpandShiftByConstant. ExpandShiftWithKnownAmountBit reads the
# amount's known bits (DAG.computeKnownBits), which Julia's IR does not compute; WasmTarget knows an
# amount only as a literal, the branch above. SHL_PARTS, SRL_PARTS and SRA_PARTS are Expand on wasm,
# so not LegalOrCustom, and the strategy is ExpandToParts, not ExpandThroughStack (above): the
# libcall, compiler-rt's __ashlti3, __lshrti3 or __ashrti3, emitted in place
# (src/llvm/compiler_rt/), its amount the i32 the shift's amount is truncated to, held in an i64
# local; ExpandShiftWithUnknownAmountBit serves a target with no such libcall
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5227 DAGTypeLegalizer::ExpandIntRes_Shift" function expand_int_res_shift(b::WasmBuilder.InstructionsBuilder, opc::Symbol, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, amt::Union{WasmBuilder.IR.Local,Int64})::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}
    amt isa Int64 && return expand_shift_by_constant(b, opc, x, amt)
    opc === :SHL && return __ashlti3(b, x, amt)
    opc === :SRL && return __lshrti3(b, x, amt)
    opc === :SRA && return __ashrti3(b, x, amt)
    reject!(Internal("llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5227 DAGTypeLegalizer::ExpandIntRes_Shift: $opc is no shift"), "DAGTypeLegalizer::ExpandIntRes_Shift")
end

# A shift by a constant amount, unsigned: 0 returns the operand; the type's width or more, all zeros
# (the sign for SRA); more than a half's width, one half shifted into the other; exactly a half's
# width, the half moved; less, the bits carried across (FSHL and FSHR are Expand, so as an OR)
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:3476 DAGTypeLegalizer::ExpandShiftByConstant" function expand_shift_by_constant(b::WasmBuilder.InstructionsBuilder, opc::Symbol, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, amt::Int64)::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}
    local (inl, inh) = x
    amt == 0 && return (inl, inh)
    local i64 = WasmBuilder.IR.NumType_i64
    local vtbits = UInt64(128)
    local nvtbits = 64
    local a = reinterpret(UInt64, amt)
    # an SDValue of `op` over `v` by a constant amount, a new local
    local shift(op::Function, v::Union{WasmBuilder.IR.Local,Int64}, n::Integer) = begin
        local r = WasmBuilder.add_local(b, i64)
        sd_get(b, v); WasmBuilder.i64_const(b, Int64(n)); op(b); WasmBuilder.local_set(b, r)
        r
    end
    local orof(p::WasmBuilder.IR.Local, q::WasmBuilder.IR.Local) = begin
        local r = WasmBuilder.add_local(b, i64)
        WasmBuilder.local_get(b, p); WasmBuilder.local_get(b, q); WasmBuilder.i64_or(b); WasmBuilder.local_set(b, r)
        r
    end
    if opc === :SHL
        a >= vtbits && return (Int64(0), Int64(0))
        a > nvtbits && return (Int64(0), shift(WasmBuilder.i64_shl, inl, a - nvtbits))
        a == nvtbits && return (Int64(0), inl)
        return (shift(WasmBuilder.i64_shl, inl, a), orof(shift(WasmBuilder.i64_shl, inh, a), shift(WasmBuilder.i64_shr_u, inl, nvtbits - a)))
    elseif opc === :SRL
        a >= vtbits && return (Int64(0), Int64(0))
        a > nvtbits && return (shift(WasmBuilder.i64_shr_u, inh, a - nvtbits), Int64(0))
        a == nvtbits && return (inh, Int64(0))
        return (orof(shift(WasmBuilder.i64_shr_u, inl, a), shift(WasmBuilder.i64_shl, inh, nvtbits - a)), shift(WasmBuilder.i64_shr_u, inh, a))
    elseif opc === :SRA
        if a >= vtbits
            local s = shift(WasmBuilder.i64_shr_s, inh, nvtbits - 1)
            return (s, s)
        end
        a > nvtbits && return (shift(WasmBuilder.i64_shr_s, inh, a - nvtbits), shift(WasmBuilder.i64_shr_s, inh, nvtbits - 1))
        a == nvtbits && return (inh, shift(WasmBuilder.i64_shr_s, inh, nvtbits - 1))
        return (orof(shift(WasmBuilder.i64_shr_u, inl, a), shift(WasmBuilder.i64_shl, inh, nvtbits - a)), shift(WasmBuilder.i64_shr_s, inh, a))
    end
    reject!(Internal("llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:3476 DAGTypeLegalizer::ExpandShiftByConstant: $opc is no shift"), "DAGTypeLegalizer::ExpandShiftByConstant")
end

# SIGN_EXTEND of an operand no wider than a half, `op` (an i32 or i64 local, its value already
# extended within that width): the low half its sign extension, the high half the low's arithmetic
# shift by all but one of its bits. An operand wider than a half is promoted first (an i48's
# extension, GetPromotedInteger); Julia's integers wider than 64 bits are 128 bits wide, and sext_int
# to an equal width is no extension, so no such operand reaches here
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5332 DAGTypeLegalizer::ExpandIntRes_SIGN_EXTEND" function expand_int_res_sign_extend(b::WasmBuilder.InstructionsBuilder, op::WasmBuilder.IR.Local)::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local lo = WasmBuilder.add_local(b, i64); local hi = WasmBuilder.add_local(b, i64)
    WasmBuilder.local_get(b, op)
    op.type == WasmBuilder.IR.NumType_i32 && WasmBuilder.i64_extend_i32_s(b)
    WasmBuilder.local_set(b, lo)
    local lo_size = 64
    WasmBuilder.local_get(b, lo); WasmBuilder.i64_const(b, Int64(lo_size - 1)); WasmBuilder.i64_shr_s(b); WasmBuilder.local_set(b, hi)
    return (lo, hi)
end

# ZERO_EXTEND of an operand no wider than a half, `op` (an i32 or i64 local, its value already
# extended within that width): the low half its zero extension, the high half zero. An operand wider
# than a half reaches no more than at SIGN_EXTEND
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5619 DAGTypeLegalizer::ExpandIntRes_ZERO_EXTEND" function expand_int_res_zero_extend(b::WasmBuilder.InstructionsBuilder, op::WasmBuilder.IR.Local)::Tuple{WasmBuilder.IR.Local,Int64}
    local lo = WasmBuilder.add_local(b, WasmBuilder.IR.NumType_i64)
    WasmBuilder.local_get(b, op)
    op.type == WasmBuilder.IR.NumType_i32 && WasmBuilder.i64_extend_i32_u(b)
    WasmBuilder.local_set(b, lo)
    return (lo, Int64(0))
end

# The operands of a SETCC of two expanded integers, and its condition: equality as the halves' xors
# or'd and compared with zero, or a comparison with all ones as the halves' and; a sign-bit test as
# the high halves'; any other as the low halves' unsigned compare where the high halves are equal,
# else the high halves' compare under the original condition. A scalar result (NewRHS nothing) is
# the compare itself. LoCmp and HiCmp are each TLI.SimplifySetCC's where it simplifies (a constant
# half decides one, X >= MIN or X < MIN), and a decided half answers alone: for LE and GE a high
# compare known false, for LT and GT a high compare known true or a low compare known false, returns
# the high compare (:5956). SETCCCARRY is Expand on wasm (above), so the select of the two compares,
# the high halves' equality simplified the same way
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5879 DAGTypeLegalizer::IntegerExpandSetCCOperands" function integer_expand_set_cc_operands(b::WasmBuilder.InstructionsBuilder, lhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, rhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, cccode::Symbol)::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64,Nothing},Symbol}
    local i64 = WasmBuilder.IR.NumType_i64
    local (lhslo, lhshi), (rhslo, rhshi) = lhs, rhs
    if cccode === :SETEQ || cccode === :SETNE
        if rhslo === rhshi && rhslo === Int64(-1)
            # Equality comparison to -1
            local newlhs = WasmBuilder.add_local(b, i64)
            sd_get(b, lhslo); sd_get(b, lhshi); WasmBuilder.i64_and(b); WasmBuilder.local_set(b, newlhs)
            return (newlhs, rhslo, cccode)
        end
        local newlhs = WasmBuilder.add_local(b, i64)
        sd_get(b, lhslo); sd_get(b, rhslo); WasmBuilder.i64_xor(b)
        sd_get(b, lhshi); sd_get(b, rhshi); WasmBuilder.i64_xor(b)
        WasmBuilder.i64_or(b); WasmBuilder.local_set(b, newlhs)
        return (newlhs, Int64(0), cccode)
    end
    # If this is a comparison of the sign bit, just look at the top part: X < 0, X > -1
    if rhslo isa Int64 && rhshi isa Int64 &&
       ((cccode === :SETLT && rhslo == 0 && rhshi == 0) || (cccode === :SETGT && rhslo == -1 && rhshi == -1))
        return (lhshi, rhshi, cccode)
    end
    local lowcc = cccode === :SETLT || cccode === :SETULT ? :SETULT :
                  cccode === :SETGT || cccode === :SETUGT ? :SETUGT :
                  cccode === :SETLE || cccode === :SETULE ? :SETULE :
                  cccode === :SETGE || cccode === :SETUGE ? :SETUGE :
                  reject!(Internal("llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:5879 DAGTypeLegalizer::IntegerExpandSetCCOperands: Unknown integer setcc! $cccode"), "DAGTypeLegalizer::IntegerExpandSetCCOperands")
    # LoCmp = lo(op1) < lo(op2), always unsigned; HiCmp = hi(op1) < hi(op2), its signedness the operands':
    # each TLI.SimplifySetCC's (a Bool where it decides, an equal compare it rewrites to), else the
    # compare itself; a compare is emitted only where it is used (a node the DAG drops is none)
    local cmp(l::Union{WasmBuilder.IR.Local,Int64}, r::Union{WasmBuilder.IR.Local,Int64}, cc::Symbol) = (local s = simplify_set_cc(l, r, cc); s === nothing ? (l, r, cc) : s)
    local emit(c::Union{Bool,Tuple}) = c isa Bool ? get_bool_constant(b, c) : get_set_cc(b, c...)
    local locmp = cmp(lhslo, rhslo, lowcc)
    local hicmp = cmp(lhshi, rhshi, cccode)
    # For LE / GE, if high part is known false, ignore the low part. For LT / GT: if low part is known
    # false, return the high part; if high part is known true, ignore the low part
    local eq_allowed = cccode === :SETLE || cccode === :SETGE || cccode === :SETULE || cccode === :SETUGE
    if (eq_allowed && hicmp === false) || (!eq_allowed && (hicmp === true || locmp === false))
        return (emit(hicmp), nothing, cccode)
    end
    # the high halves the same node: comparing the low bits is enough
    lhshi === rhshi && return (emit(locmp), nothing, cccode)
    local lo = emit(locmp)
    local hi = emit(hicmp)
    # dest = hi(op1) == hi(op2) ? LoCmp : HiCmp
    local eq = emit(cmp(lhshi, rhshi, :SETEQ))
    return (get_select(b, WasmBuilder.IR.NumType_i32, eq, lo, hi), nothing, cccode)
end

# A SETCC whose operands are expanded integers: the scalar IntegerExpandSetCCOperands answers, or the
# compare of the operands it makes, an i32 local
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:6055 DAGTypeLegalizer::ExpandIntOp_SETCC" function expand_int_op_setcc(b::WasmBuilder.InstructionsBuilder, lhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, rhs::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, cccode::Symbol)::WasmBuilder.IR.Local
    local (newlhs, newrhs, cc) = integer_expand_set_cc_operands(b, lhs, rhs, cccode)
    # If ExpandSetCCOperands returned a scalar, use it
    newrhs === nothing && return newlhs::WasmBuilder.IR.Local
    return get_set_cc(b, newlhs, newrhs, cc)
end

# A TRUNCATE of an expanded integer: just truncate the low part of the source, pushed, to an i32
# where the result is narrower than a half
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:6228 DAGTypeLegalizer::ExpandIntOp_TRUNCATE" function expand_int_op_truncate(b::WasmBuilder.InstructionsBuilder, x::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, vt::WasmBuilder.IR.ValueType)::Nothing
    sd_get(b, x[1])
    vt == WasmBuilder.IR.NumType_i32 && WasmBuilder.i32_wrap_i64(b)
    return nothing
end
