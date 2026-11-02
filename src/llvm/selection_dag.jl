# LLVM's SelectionDAG builders the type legalizer's expansions make their nodes with
# (llvm/include/llvm/CodeGen/SelectionDAG.h), each node emitted as the wasm instruction LLVM's
# WebAssembly instruction selection makes of it (WebAssemblyInstrInteger.td's patterns: a SETCC of
# two i64 the i64 compare of its condition, a SELECT wasm's select), its value a new local of the
# function being written: an SDValue as src/julia/machine.jl records it (sd_get).
# What has no counterpart: SelectionDAG::getNode's folds (a constant compare decided, x ^ 0 read as
# x), which only spare a node whose value the emitted instruction computes the same.

# Helper function to make it easier to build SetCC's if you just have an ISD::CondCode: the i32 local
# holding LHS `cond` RHS, two i64 halves compared by the condition's i64 compare
@parity "llvm/include/llvm/CodeGen/SelectionDAG.h:1380 SelectionDAG::getSetCC" function get_set_cc(b::WasmBuilder.InstructionsBuilder, lhs::Union{WasmBuilder.IR.Local,Int64}, rhs::Union{WasmBuilder.IR.Local,Int64}, cond::Symbol)::WasmBuilder.IR.Local
    local r = WasmBuilder.add_local(b, WasmBuilder.IR.NumType_i32)
    sd_get(b, lhs); sd_get(b, rhs)
    if cond === :SETEQ
        WasmBuilder.i64_eq(b)
    elseif cond === :SETNE
        WasmBuilder.i64_ne(b)
    elseif cond === :SETLT
        WasmBuilder.i64_lt_s(b)
    elseif cond === :SETLE
        WasmBuilder.i64_le_s(b)
    elseif cond === :SETGT
        WasmBuilder.i64_gt_s(b)
    elseif cond === :SETGE
        WasmBuilder.i64_ge_s(b)
    elseif cond === :SETULT
        WasmBuilder.i64_lt_u(b)
    elseif cond === :SETULE
        WasmBuilder.i64_le_u(b)
    elseif cond === :SETUGT
        WasmBuilder.i64_gt_u(b)
    elseif cond === :SETUGE
        WasmBuilder.i64_ge_u(b)
    else
        reject!(Internal("llvm/include/llvm/CodeGen/SelectionDAG.h:1380 SelectionDAG::getSetCC: $cond is no integer condition code"), "SelectionDAG::getSetCC")
    end
    WasmBuilder.local_set(b, r)
    return r
end

# Helper function to make it easier to build Select's if you just have operands that don't need to
# be legalized: the local of type `vt` holding `cond` ? LHS : RHS
@parity "llvm/include/llvm/CodeGen/SelectionDAG.h:1410 SelectionDAG::getSelect" function get_select(b::WasmBuilder.InstructionsBuilder, vt::WasmBuilder.IR.ValueType, cond::WasmBuilder.IR.Local, lhs::Union{WasmBuilder.IR.Local,Int64}, rhs::Union{WasmBuilder.IR.Local,Int64})::WasmBuilder.IR.Local
    local r = WasmBuilder.add_local(b, vt)
    sd_get(b, lhs); sd_get(b, rhs); WasmBuilder.local_get(b, cond)
    WasmBuilder.select(b, vt)
    WasmBuilder.local_set(b, r)
    return r
end
