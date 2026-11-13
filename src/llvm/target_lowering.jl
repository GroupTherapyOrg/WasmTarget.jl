# LLVM's target lowering's DAG simplifications the type legalizer's expansions call
# (llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp), over SDValues as src/julia/machine.jl records
# them (sd_get): a constant half an Int64, any other value the local holding it.

# Try to simplify a setcc built with the specified operands and cc: a Bool where the compare is
# decided, the operands and condition of an equal compare it rewrites to, or nothing. Its operands are
# two SDValues of one integer type, as src/julia/machine.jl records them (sd_get): a half's (a local, or
# an Int64 constant), or a 128-bit integer's, the pair of its halves (a constant node exactly where both
# halves are constants, ExpandIntRes_Constant's split of a literal). The int128 arm
# (src/intrinsics.jl) calls it on the 128-bit setcc, as DAGCombiner::visitSETCC does before the type
# legalizer, and IntegerExpandSetCCOperands on each pair of halves. Ported:
# - DAG.FoldSetCC (llvm/lib/CodeGen/SelectionDAG/SelectionDAG.cpp:2707), its integer arms: icmp X, X
#   answers ISD::isTrueWhenEqual, the operands one node (one local or one pair of locals, or two equal
#   constants, which the DAG keeps as one node); two constants answer their compare
#   (ICmpInst::compare). Undef has no counterpart: no SDValue here is undef;
# - the canonicalization of a constant to the right, the condition swapped (:4819-:4826), taken
#   before operation legalization (DAGCombinerInfo at BeforeLegalizeTypes for the 128-bit setcc,
#   AfterLegalizeTypes for the halves, LegalizeIntegerTypes.cpp:5932);
# - the block on a constant right operand (:5292-:5381), over the operands' bits (64 or 128): X >= MIN
#   and X <= MAX true, X < MIN and X > MAX false; X >= C rewritten X > C-1 and X <= C rewritten X < C+1;
#   X < MAX and X > MIN rewritten !=, and X < MIN+1, X > MAX-1 rewritten == to the bound, each of a
#   constant that is not opaque.
# The int128 arm reads each statement's 128-bit operands from their class's struct, so a half is a
# constant only where its operand is a literal (a zero extension's constant high half is stored into
# its struct and read back into a local); a compare of two literals Julia's inference folds before the
# IR it reads, so no compile reaches the fold of two constants, which test/src/code_generator_intrinsics.jl
# calls on halves and on pairs directly. Not ported, each reading a fact of a DAG that Julia's IR does
# not build: the folds through the operands' own nodes (a sub, a shift, an and, a zero or sign
# extension, an or of halves, :4829-:5290 and the equality block from :5383), and the folds past the
# constant block, which read known bits
@parity "llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:4800 TargetLowering::SimplifySetCC" function simplify_set_cc(n0::Union{WasmBuilder.IR.Local,Int64,Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, n1::Union{WasmBuilder.IR.Local,Int64,Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}}, cond::Symbol)::Union{Bool,Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64},Symbol},Tuple{Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}},Symbol},Nothing}
    (n0 isa Tuple) === (n1 isa Tuple) ||
        reject!(Internal("llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:4800 TargetLowering::SimplifySetCC: the operands $n0 and $n1 are of two widths"), "TargetLowering::SimplifySetCC")
    # a constant node's value (isConstOrConstSplat): a half's Int64, a pair's Int128 of its two
    # constant halves; nothing for any other node. A value is made a node as ExpandIntRes_Constant makes it
    local value(n::Union{WasmBuilder.IR.Local,Int64,Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}})::Union{Int64,Int128,Nothing} =
        n isa Int64 ? n :
        n isa Tuple && n[1] isa Int64 && n[2] isa Int64 ? (Int128(n[2]) << 64) | Int128(reinterpret(UInt64, n[1])) : nothing
    local node(c::Union{Int64,Int128})::Union{Int64,Tuple{Int64,Int64}} = c isa Int64 ? c : expand_int_res_constant(c)
    # Constant fold or commute setcc: DAG.FoldSetCC. icmp X, X -> true/false
    n0 === n1 && return cond === :SETEQ || cond === :SETGE || cond === :SETLE || cond === :SETUGE || cond === :SETULE
    local c0, c1 = value(n0), value(n1)
    if c0 !== nothing && c1 !== nothing
        # two constants: ICmpInst::compare of the two
        local u0, u1 = reinterpret(unsigned(typeof(c0)), c0), reinterpret(unsigned(typeof(c1)), c1)
        cond === :SETEQ && return c0 == c1
        cond === :SETNE && return c0 != c1
        cond === :SETLT && return c0 < c1
        cond === :SETLE && return c0 <= c1
        cond === :SETGT && return c0 > c1
        cond === :SETGE && return c0 >= c1
        cond === :SETULT && return u0 < u1
        cond === :SETULE && return u0 <= u1
        cond === :SETUGT && return u0 > u1
        cond === :SETUGE && return u0 >= u1
        reject!(Internal("llvm/lib/CodeGen/SelectionDAG/SelectionDAG.cpp:2707 SelectionDAG::FoldSetCC: $cond is no integer condition code"), "TargetLowering::SimplifySetCC")
    end
    # Canonicalize toward having the constant on the RHS, the condition swapped: ISD::getSetCCSwappedOperands
    # (llvm/lib/CodeGen/SelectionDAG/SelectionDAG.cpp:635) swaps its L and G bits, EQ and NE their own swap
    if c0 !== nothing && c1 === nothing
        local swapped = cond === :SETLT ? :SETGT : cond === :SETGT ? :SETLT : cond === :SETLE ? :SETGE : cond === :SETGE ? :SETLE :
                        cond === :SETULT ? :SETUGT : cond === :SETUGT ? :SETULT : cond === :SETULE ? :SETUGE : cond === :SETUGE ? :SETULE : cond
        return (n1, n0, swapped)
    end
    c1 === nothing && return nothing
    # ISD::isSignedIntSetCC: the operands' signed bounds, else their unsigned ones (0 and all ones)
    local signed = cond === :SETGT || cond === :SETGE || cond === :SETLT || cond === :SETLE
    local min_val = signed ? typemin(c1) : zero(c1)
    local max_val = signed ? typemax(c1) : -one(c1)
    # Canonicalize GE/LE comparisons to use GT/LT comparisons
    if cond === :SETGE || cond === :SETUGE
        # X >= MIN --> true
        c1 == min_val && return true
        # X >= C0 --> X > (C0 - 1)
        return (n0, node(c1 - one(c1)), cond === :SETGE ? :SETGT : :SETUGT)
    end
    if cond === :SETLE || cond === :SETULE
        # X <= MAX --> true
        c1 == max_val && return true
        # X <= C0 --> X < (C0 + 1)
        return (n0, node(c1 + one(c1)), cond === :SETLE ? :SETLT : :SETULT)
    end
    if cond === :SETLT || cond === :SETULT
        # X < MIN --> false
        c1 == min_val && return false
        # Canonicalize setlt X, Max --> setne X, Max
        c1 == max_val && return (n0, n1, :SETNE)
        # If we have setult X, 1, turn it into seteq X, 0
        c1 == min_val + one(c1) && return (n0, node(min_val), :SETEQ)
    end
    if cond === :SETGT || cond === :SETUGT
        # X > MAX --> false
        c1 == max_val && return false
        # Canonicalize setgt X, Min --> setne X, Min
        c1 == min_val && return (n0, n1, :SETNE)
        # If we have setugt X, Max-1, turn it into seteq X, Max
        c1 == max_val - one(c1) && return (n0, node(max_val), :SETEQ)
    end
    return nothing
end

# Lower a MULO (SMULO, UMULO: the product's low bits and whether it overflowed), the node of LLVM's
# llvm.smul.with.overflow and llvm.umul.with.overflow, which LegalizeDAG expands on wasm: SMULO and
# UMULO keep TargetLoweringBase.cpp:1168's Expand, which WebAssembly never overrides. Its branches in
# their order, each decided as LLVM's WebAssembly backend decides it: SMUL_LOHI, UMUL_LOHI, MULHS and
# MULHU are Expand (WebAssemblyISelLowering.cpp:176), so an i32's product is its wide type's, the i64
# being legal (isTypeLegal), and an i64's is forceExpandWideMUL's, no i128 being legal. The operands
# are one integer type `vt` (an i32 or an i64), LHS a local and RHS an SDValue as src/julia/machine.jl
# records it (sd_get), a constant an Int64 holding its bits. Returns the result (the product's low
# half) and the overflow flag, an i32 ZeroOrOneBooleanContent (WebAssemblyISelLowering.cpp:54), the
# i1 RType's width needing no truncate. The power-of-two shift expansion is taken where RHS is a
# literal (isConstOrConstSplat); DAGCombiner::visitMULO's folds before legalization (DAGCombiner.cpp:6102:
# two constants folded, a constant moved to the right, mulo by 0 or 2, one known not to overflow made a
# mul) read a DAG Julia's IR does not build, and are not ported: each answers the same product and flag
@parity "llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:13153 TargetLowering::expandMULO" function expand_mulo(b::WasmBuilder.InstructionsBuilder, is_signed::Bool, vt::WasmBuilder.IR.NumType, lhs::WasmBuilder.IR.Local, rhs::Union{WasmBuilder.IR.Local,Int64})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i32, i64 = WasmBuilder.IR.NumType_i32, WasmBuilder.IR.NumType_i64
    (vt == i32 || vt == i64) || reject!(Internal("llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:13153 TargetLowering::expandMULO: $vt is no legal integer type"), "TargetLowering::expandMULO")
    local bits = vt == i64 ? 64 : 32
    local k(n::Integer) = vt == i64 ? WasmBuilder.i64_const(b, Int64(n)) : WasmBuilder.i32_const(b, Int64(n))
    local get(v::Union{WasmBuilder.IR.Local,Int64}) = v isa Int64 ? k(v) : WasmBuilder.local_get(b, v)
    local overflow = WasmBuilder.add_local(b, i32)
    # For power-of-two multiplications we can use a simpler shift expansion.
    if rhs isa Int64
        local c = vt == i64 ? reinterpret(UInt64, rhs) : UInt64(rhs % UInt32)
        # mulo(X, 1 << S) -> { X << S, (X << S) >> S != X }
        if ispow2(c)
            # smulo(x, signed_min) is same as umulo(x, signed_min).
            local use_arith_shift = is_signed && c != UInt64(1) << (bits - 1)
            local shift_amt = trailing_zeros(c)
            local shifted = WasmBuilder.add_local(b, vt)
            WasmBuilder.local_get(b, lhs); k(shift_amt); vt == i64 ? WasmBuilder.i64_shl(b) : WasmBuilder.i32_shl(b)
            WasmBuilder.local_tee(b, shifted)
            k(shift_amt)
            if use_arith_shift
                vt == i64 ? WasmBuilder.i64_shr_s(b) : WasmBuilder.i32_shr_s(b)
            else
                vt == i64 ? WasmBuilder.i64_shr_u(b) : WasmBuilder.i32_shr_u(b)
            end
            WasmBuilder.local_get(b, lhs)
            vt == i64 ? WasmBuilder.i64_ne(b) : WasmBuilder.i32_ne(b)
            WasmBuilder.local_set(b, overflow)
            return (shifted, overflow)
        end
    end
    local bottom_half::WasmBuilder.IR.Local, top_half::Union{WasmBuilder.IR.Local,Int64}
    if vt == i32
        # isTypeLegal(WideVT): each operand extended to the i64 (SIGN_EXTEND, ZERO_EXTEND), their MUL,
        # its TRUNCATE the bottom half and its SRL by the width, truncated, the top half
        local extend() = is_signed ? WasmBuilder.i64_extend_i32_s(b) : WasmBuilder.i64_extend_i32_u(b)
        local mul = WasmBuilder.add_local(b, i64)
        bottom_half = WasmBuilder.add_local(b, i32)
        top_half = WasmBuilder.add_local(b, i32)
        WasmBuilder.local_get(b, lhs); extend(); get(rhs); extend(); WasmBuilder.i64_mul(b)
        WasmBuilder.local_tee(b, mul); WasmBuilder.i32_wrap_i64(b); WasmBuilder.local_set(b, bottom_half)
        WasmBuilder.local_get(b, mul); WasmBuilder.i64_const(b, 32); WasmBuilder.i64_shr_u(b); WasmBuilder.i32_wrap_i64(b)
        WasmBuilder.local_set(b, top_half)
    else
        bottom_half, top_half = force_expand_wide_mul(b, is_signed, lhs, rhs)
    end
    if is_signed
        # Overflow = TopHalf != BottomHalf >> (width - 1), the arithmetic shift its sign
        get(top_half); WasmBuilder.local_get(b, bottom_half); k(bits - 1)
        vt == i64 ? WasmBuilder.i64_shr_s(b) : WasmBuilder.i32_shr_s(b)
    else
        # Overflow = TopHalf != 0
        get(top_half); k(0)
    end
    vt == i64 ? WasmBuilder.i64_ne(b) : WasmBuilder.i32_ne(b)
    WasmBuilder.local_set(b, overflow)
    return (bottom_half, overflow)
end

# The full product of two i64s, its low and high halves, where no i128 multiply is legal: MUL_I128's
# libcall, compiler-rt's __multi3 (src/llvm/compiler_rt/multi3.jl), which wasm's libcalls hold, so the
# brute-force forceExpandMultiply is never taken. Its operands are the i128s each i64 extends to: the
# high half an operand's arithmetic shift by 63 where signed (a constant's own, folded as getNode folds
# a constant's shift), else 0; wasm is little-endian, so the halves are passed and returned low first
@parity "llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:12755 TargetLowering::forceExpandWideMUL" function force_expand_wide_mul(b::WasmBuilder.InstructionsBuilder, is_signed::Bool, lhs::Union{WasmBuilder.IR.Local,Int64}, rhs::Union{WasmBuilder.IR.Local,Int64})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local high(v::Union{WasmBuilder.IR.Local,Int64})::Union{WasmBuilder.IR.Local,Int64} = begin
        is_signed || return Int64(0)
        v isa Int64 && return v >> 63
        local h = WasmBuilder.add_local(b, WasmBuilder.IR.NumType_i64)
        WasmBuilder.local_get(b, v); WasmBuilder.i64_const(b, 63); WasmBuilder.i64_shr_s(b); WasmBuilder.local_set(b, h)
        h
    end
    local hi_lhs, hi_rhs = high(lhs), high(rhs)
    return __multi3(b, (lhs, hi_lhs), (rhs, hi_rhs))
end
