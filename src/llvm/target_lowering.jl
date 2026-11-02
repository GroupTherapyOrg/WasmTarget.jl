# LLVM's target lowering's DAG simplifications the type legalizer's expansions call
# (llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp), over SDValues as src/julia/machine.jl records
# them (sd_get): a constant half an Int64, any other value the local holding it.

# Try to simplify a setcc built with the specified operands and cc: a Bool where the compare is
# decided, the operands and condition of an equal compare it rewrites to, or nothing. Ported: the
# block on a constant right operand (:5292-:5381), over a half's 64 bits: X >= MIN and X <= MAX true,
# X < MIN and X > MAX false; X >= C rewritten X > C-1 and X <= C rewritten X < C+1; X < MAX and
# X > MIN rewritten !=, and X < MIN+1, X > MAX-1 rewritten == to the bound. Each rewrite is taken as
# the expansions call it, before operation legalization (DAGCombinerInfo at AfterLegalizeTypes), of a
# constant that is not opaque. Not ported, each reading a fact of a DAG that Julia's IR does not build:
# DAG.FoldSetCC of two constants and the canonicalization of a constant to the right (:4810-:4827),
# which need a constant left operand, a compare Julia decides or the int128 arm moves right before the
# legalizer; the folds through the operands' own nodes (a sub, a shift, an and, a zero or sign
# extension, an or of halves, :4829-:5290 and the equality block from :5383); and the folds past the
# constant block, which read known bits
@parity "llvm/lib/CodeGen/SelectionDAG/TargetLowering.cpp:4800 TargetLowering::SimplifySetCC" function simplify_set_cc(n0::Union{WasmBuilder.IR.Local,Int64}, n1::Union{WasmBuilder.IR.Local,Int64}, cond::Symbol)::Union{Bool,Tuple{Union{WasmBuilder.IR.Local,Int64},Int64,Symbol},Nothing}
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
