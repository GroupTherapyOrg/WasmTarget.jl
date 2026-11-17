# LLVM's expandSADDSUBO, ported (src/llvm/target_lowering.jl expand_saddsubo; dev/LEDGER.md D42):
# Julia's checked_sadd_int and checked_ssub_int (Base.add_with_overflow, Base.sub_with_overflow), the
# SADDO and SSUBO of llvm.sadd.with.overflow and llvm.ssub.with.overflow (julia/src/intrinsics.cpp:1563),
# as LegalizeDAG expands each on wasm, where no scalar SADDSAT or SSUBSAT is legal: the sum or difference
# and the xor of two signed compares. Each result and overflow flag, of an i64 and an i32, a register
# right operand and a literal one, against native; an 8- or 16-bit operand's promotion
# (PromoteIntRes_SADDSUBO) is not ported and rejects, located, by its name.
module LLVMSaddsuboTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module CheckedAddSubCases
o(t::Tuple{Integer,Bool}) = Int64(t[1] % Int64) * 3 + Int64(t[2])
function addsubo(a::Int64, b::Int64)
    local a32, b32 = a % Int32, b % Int32
    return o(Base.add_with_overflow(a, b)) + 5 * o(Base.sub_with_overflow(a, b)) +
        7 * o(Base.add_with_overflow(a32, b32)) + 11 * o(Base.sub_with_overflow(a32, b32)) +
        13 * o(Base.add_with_overflow(a, Int64(1))) + 17 * o(Base.sub_with_overflow(a, Int64(1))) +
        19 * o(Base.add_with_overflow(a, Int64(-1))) + 23 * o(Base.sub_with_overflow(a, typemin(Int64))) +
        29 * o(Base.add_with_overflow(a32, typemax(Int32))) + 31 * o(Base.sub_with_overflow(a32, Int32(-7)))
end
narrow(a::Int8, b::Int8) = Base.add_with_overflow(a, b)[2]
end

@testset "TargetLowering.cpp: expandSADDSUBO, checked_sadd_int and checked_ssub_int, result and overflow, against native" begin
    local bytes = W.compile(CheckedAddSubCases.addsubo, (Int64, Int64); optimize = false)
    local edge = Int64[0, 1, -1, 2, -2, 1 << 31, -(1 << 31), (1 << 31) - 1, 1 << 32, typemax(Int64), typemin(Int64), typemax(Int64) - 1, typemin(Int64) + 1]
    queue_native!("addsubo", bytes, CheckedAddSubCases.addsubo, [(a, b) for a in edge for b in edge])
end

@testset "LegalizeIntegerTypes.cpp: an 8-bit checked_sadd_int's promotion is not ported, rejected by its name" begin
    local e = rejection(() -> W.compile(CheckedAddSubCases.narrow, (Int8, Int8); optimize = false))
    @test e !== nothing && e.rejection isa W.Unported &&
          e.rejection.anchor == "llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp:1397 DAGTypeLegalizer::PromoteIntRes_SADDSUBO"
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
