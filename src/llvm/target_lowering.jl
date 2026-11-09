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
