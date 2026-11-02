# LLVM's target lowering's DAG simplifications the type legalizer's expansions call
# (llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp), over SDValues as src/julia/machine.jl records
# them (sd_get): a constant half an Int64, any other value the local holding it.

# Try to simplify a setcc built with the specified operands and cc: a Bool where the compare is
# decided, the operands and condition of an equal compare it rewrites to, or nothing. Ported:
# - DAG.FoldSetCC (llvm/lib/CodeGen/SelectionDAG/SelectionDAG.cpp:2707), its integer arms: icmp X, X
#   answers ISD::isTrueWhenEqual, the operands one node (one local, or two equal constants, which the
#   DAG keeps as one node); two constants answer their compare (ICmpInst::compare). Undef has no
#   counterpart: no SDValue here is undef;
# - the canonicalization of a constant to the right, the condition swapped (:4819-:4826), taken before
#   operation legalization (DAGCombinerInfo at AfterLegalizeTypes, LegalizeIntegerTypes.cpp:5932);
# - the block on a constant right operand (:5292-:5381), over a half's 64 bits: X >= MIN and X <= MAX
#   true, X < MIN and X > MAX false; X >= C rewritten X > C-1 and X <= C rewritten X < C+1; X < MAX and
#   X > MIN rewritten !=, and X < MIN+1, X > MAX-1 rewritten == to the bound, each of a constant that is
#   not opaque.
# The int128 arm reads each statement's 128-bit operands from their class's struct, so a half is a
# constant only where its operand is a literal, and a literal left operand is moved right before the
# legalizer (src/intrinsics.jl): the fold of two constants is reached by two literal operands, the
# commute by a constant half an expansion makes on the left. Not ported, each reading a fact of a DAG
# that Julia's IR does not build: the folds through the operands' own nodes (a sub, a shift, an and, a
# zero or sign extension, an or of halves, :4829-:5290 and the equality block from :5383), and the
# folds past the constant block, which read known bits
@parity "llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:4800 TargetLowering::SimplifySetCC" function simplify_set_cc(n0::Union{WasmBuilder.IR.Local,Int64}, n1::Union{WasmBuilder.IR.Local,Int64}, cond::Symbol)::Union{Bool,Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64},Symbol},Nothing}
    # Constant fold or commute setcc: DAG.FoldSetCC. icmp X, X -> true/false
    n0 === n1 && return cond === :SETEQ || cond === :SETGE || cond === :SETLE || cond === :SETUGE || cond === :SETULE
    if n0 isa Int64 && n1 isa Int64
        # two constants: ICmpInst::compare of the two
        local u0, u1 = reinterpret(UInt64, n0), reinterpret(UInt64, n1)
        cond === :SETEQ && return n0 == n1
        cond === :SETNE && return n0 != n1
        cond === :SETLT && return n0 < n1
        cond === :SETLE && return n0 <= n1
        cond === :SETGT && return n0 > n1
        cond === :SETGE && return n0 >= n1
        cond === :SETULT && return u0 < u1
        cond === :SETULE && return u0 <= u1
        cond === :SETUGT && return u0 > u1
        cond === :SETUGE && return u0 >= u1
        reject!(Internal("llvm/lib/CodeGen/SelectionDAG/SelectionDAG.cpp:2707 SelectionDAG::FoldSetCC: $cond is no integer condition code"), "TargetLowering::SimplifySetCC")
    end
    # Canonicalize toward having the constant on the RHS (ISD::getSetCCSwappedOperands)
    if n0 isa Int64
        local swapped = cond === :SETLT ? :SETGT : cond === :SETGT ? :SETLT : cond === :SETLE ? :SETGE : cond === :SETGE ? :SETLE :
                        cond === :SETULT ? :SETUGT : cond === :SETUGT ? :SETULT : cond === :SETULE ? :SETUGE : cond === :SETUGE ? :SETULE : cond
        return (n1, n0, swapped)
    end
    n1 isa Int64 || return nothing
    local c1 = n1
    # ISD::isSignedIntSetCC: the half's signed bounds, else its unsigned ones (0 and all ones)
    local signed = cond === :SETGT || cond === :SETGE || cond === :SETLT || cond === :SETLE
    local min_val = signed ? typemin(Int64) : Int64(0)
    local max_val = signed ? typemax(Int64) : Int64(-1)
    # Canonicalize GE/LE comparisons to use GT/LT comparisons
    if cond === :SETGE || cond === :SETUGE
        # X >= MIN --> true
        c1 == min_val && return true
        # X >= C0 --> X > (C0 - 1)
        return (n0, c1 - Int64(1), cond === :SETGE ? :SETGT : :SETUGT)
    end
    if cond === :SETLE || cond === :SETULE
        # X <= MAX --> true
        c1 == max_val && return true
        # X <= C0 --> X < (C0 + 1)
        return (n0, c1 + Int64(1), cond === :SETLE ? :SETLT : :SETULT)
    end
    if cond === :SETLT || cond === :SETULT
        # X < MIN --> false
        c1 == min_val && return false
        # Canonicalize setlt X, Max --> setne X, Max
        c1 == max_val && return (n0, n1, :SETNE)
        # If we have setult X, 1, turn it into seteq X, 0
        c1 == min_val + Int64(1) && return (n0, min_val, :SETEQ)
    end
    if cond === :SETGT || cond === :SETUGT
        # X > MAX --> false
        c1 == max_val && return false
        # Canonicalize setgt X, Min --> setne X, Min
        c1 == min_val && return (n0, n1, :SETNE)
        # If we have setugt X, Max-1, turn it into seteq X, Max
        c1 == max_val - Int64(1) && return (n0, max_val, :SETEQ)
    end
    return nothing
end
