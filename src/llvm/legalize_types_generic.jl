# The type legalizer's expansions that do not care what type is being expanded
# (llvm/lib/CodeGen/SelectionDAG/LegalizeTypesGeneric.cpp), over SDValues as src/julia/machine.jl
# records them (sd_get): a constant half an Int64, any other value the local holding it.

# A SELECT of an expanded integer: each half selected by the one condition. A vector condition's
# split (WidenVSELECTMask, SplitVector) and VP_SELECT's explicit vector length have no counterpart:
# Julia's scalar integers make neither
@parity "llvm/lib/CodeGen/SelectionDAG/LegalizeTypesGeneric.cpp:524 DAGTypeLegalizer::SplitRes_Select" function split_res_select(b::WasmBuilder.InstructionsBuilder, cond::WasmBuilder.IR.Local, l::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}}, r::Tuple{Union{WasmBuilder.IR.Local,Int64},Union{WasmBuilder.IR.Local,Int64}})::Tuple{WasmBuilder.IR.Local,WasmBuilder.IR.Local}
    local i64 = WasmBuilder.IR.NumType_i64
    local (ll, lh), (rl, rh) = l, r
    return (get_select(b, i64, cond, ll, rl), get_select(b, i64, cond, lh, rh))
end
