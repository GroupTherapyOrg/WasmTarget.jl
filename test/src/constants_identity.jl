# dart2wasm's constants.dart, ported (src/constants.jl): a mutable Julia object's identity among the program's constants.
# The key of its storage is its ConstantOwner (src/julia/wasm_array.jl), the object by === and the storage, never its
# contents: dev/formal/ObjectIdentity.tla's WriteSeenSameConstant, WriteUnseenDistinctConstants and ConstantDataAgrees.

# makeArrayOf's key: a Julia object's storage literal names its ConstantOwner; a runtime table of dart's has none
module ConstantOwnerKey
using Test
using WasmTarget
const D = WasmTarget.Dart2Wasm
# a collaborator's translator: the options the constants' names read, and nothing else
struct ConstantsNodes <: D.KernelNodes
    options::D.TranslatorOptions
end
_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
@testset "constants.dart: makeArrayOf keys a Julia object's storage by its ConstantOwner" begin
    local cs = D.Constants(ConstantsNodes(D.TranslatorOptions()))
    # a mutable Julia object's storage is keyed by its ConstantOwner (the object by ===, and the storage): two Memories
    # of equal elements are two arrays, one Memory twice one (dev/formal/ObjectIdentity.tla WriteUnseenDistinctConstants,
    # WriteSeenSameConstant; Julia's image writer, src/staticdata.c:1105 jl_queue_for_serialization_); an immutable owns nothing
    local m1, m2 = fill!(Memory{Int32}(undef, 2), Int32(1)), fill!(Memory{Int32}(undef, 2), Int32(1))
    local es = [D.make_wasm_i32(cs, 1), D.make_wasm_i32(cs, 1)]
    local o1 = D.make_array_of(cs, Int32, es; owner = WasmTarget.ConstantOwner(m1, "data"))
    @test o1 === D.make_array_of(cs, Int32, copy(es); owner = WasmTarget.ConstantOwner(m1, "data"))
    @test o1 !== D.make_array_of(cs, Int32, es; owner = WasmTarget.ConstantOwner(m2, "data")) && o1 !== D.make_array_of(cs, Int32, es)
    @test o1 !== D.make_array_of(cs, Int32, es; owner = WasmTarget.ConstantOwner(m1, "data#isSet"))
    local od = Dict{WasmTarget.NirConst,Int}(o1 => 1, D.make_array_of(cs, Int32, es; owner = WasmTarget.ConstantOwner(m2, "data")) => 2)
    @test length(od) == 2 && od[D.make_array_of(cs, Int32, es; owner = WasmTarget.ConstantOwner(m1, "data"))] == 1
    @test _rejection(() -> WasmTarget.ConstantOwner((1, 2), "data")) isa WasmTarget.Internal
end
end

# A mutable object's identity is the object, never its contents (Julia's image writer serializes each object once by its
# address, src/staticdata.c:1105 jl_queue_for_serialization_): two distinct constant Arrays, Dicts, BitVectors, Memories or
# mutable structs with equal contents are two objects, a write through one never read through the other, and `===` of
# the two false; one object reached by any number of paths (two bindings, two structs' fields, a Vector holding it
# twice) is one object, a write through one path read through every other. dart canonicalizes a constant by its value
# (constants.dart:154 constantInfo, Kernel's InstanceConstant ==), its constants deeply immutable; the storage a
# mutable Julia object owns (a Memory's data array) is keyed by its ConstantOwner (src/julia/wasm_array.jl), the
# claims of dev/formal/ObjectIdentity.tla: WriteSeenSameConstant (cases 3, 4, 5, 20), WriteUnseenDistinctConstants
# (the rest; 21 the live copies of two popped Arrays, 22 data#isSet, 23 copyto!) and ConstantDataAgrees (every case). Each case k at n, written then read, its answer and `===` of the pair
# compared with native's in one program's two modules.
module MutableConstantIdentity
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
mutable struct Cell
    x::Int64
end
struct Hold
    v::Vector{Int64}
end
mutable struct MHold
    v::Vector{Int64}
end
struct Pt
    a::Int64
    b::Int64
end
const A = [1, 2, 3]
const B = [1, 2, 3]
const FA = [1.5, 2.5]
const FB = [1.5, 2.5]
const C = [1, 2, 3]
const CD = C                                 # the same Array, a second binding
const SHARED = [7, 8]
const S1 = Hold(SHARED)                      # one Array in two constant structs' fields
const S2 = MHold(SHARED)
const INNER = [1, 2]
const VV = [INNER, INNER]                    # one inner Vector held twice
const VW = [[1, 2], [1, 2]]                  # two equal, distinct inner Vectors
const D1 = Dict(1 => 10, 2 => 20)
const D2 = Dict(1 => 10, 2 => 20)
const M1 = Cell(1)
const M2 = Cell(1)
const R1 = Ref(1)
const R2 = Ref(1)
const I8A = Int8[1, 2]
const I8B = Int8[1, 2]
const BA = [true, false]
const BB = [true, false]
const SA = ["a", "b"]
const SB = ["a", "b"]
const PA = [Pt(1, 2)]
const PB = [Pt(1, 2)]
const E1 = Int64[]
const E2 = Int64[]
const MX = let m = Memory{Any}(undef, 2); m[1] = 1; m[2] = 2; m end
const MY = let m = Memory{Any}(undef, 2); m[1] = 1; m[2] = 2; m end
const BV1 = BitVector([true, false])
const BV2 = BitVector([true, false])
const MAT1 = [1 2; 3 4]
const MAT2 = [1 2; 3 4]
const ST1 = Set([1, 2])
const ST2 = Set([1, 2])
const Q1 = let a = [1, 2, 3]; pop!(a); a end    # two popped Arrays: each its live copy (spec v16 X5)
const Q2 = let a = [1, 2, 3]; pop!(a); a end
const MU1 = let m = Memory{Any}(undef, 2); m[1] = 1; m end   # an #undef slot each: data#isSet, a second storage
const MU2 = let m = Memory{Any}(undef, 2); m[1] = 1; m end
const A14 = [1, 2, 3]                        # copyto! between two equal, distinct Arrays
const B14 = [1, 2, 3]
const SD = Dict(1 => 10, 2 => 20)
const T1 = (SD,)                             # one Dict in two constant tuples
const T2 = (SD, 1)
# `===` at run time: the two operands through a barrier, so Julia folds no comparison of two constants
same(x, y) = Int64(Base.inferencebarrier(x) === Base.inferencebarrier(y))
function ident(k::Int64, n::Int64)::Int64
    k == 1 && return (A[1] = n; B[1] + 10 * same(A, B))
    k == 2 && return (FA[2] = Float64(n); Int64(FB[2] * 2) + 10 * same(FA, FB))
    k == 3 && return (C[1] = n; CD[1] + 10 * same(C, CD))
    k == 4 && return (S1.v[1] = n; S2.v[1] + 10 * same(S1.v, S2.v))
    k == 5 && return (VV[1][1] = n; VV[2][1] + 10 * same(VV[1], VV[2]))
    k == 6 && return (VW[1][1] = n; VW[2][1] + 10 * same(VW[1], VW[2]))
    k == 7 && return (D1[1] = n; D2[1] + 100 * same(D1, D2))
    k == 8 && return (M1.x = n; M2.x + 10 * same(M1, M2))
    k == 9 && return (R1[] = n; R2[] + 10 * same(R1, R2))
    k == 10 && return (I8A[1] = Int8(n); Int64(I8B[1]) + 10 * same(I8A, I8B))
    k == 11 && return (BA[1] = n > 100; Int64(BB[1]) + 10 * same(BA, BB))
    k == 12 && return (SA[1] = n == 5 ? "zzz" : "y"; Int64(ncodeunits(SB[1])) + 10 * same(SA, SB))
    k == 13 && return (PA[1] = Pt(n, n); PB[1].a + 10 * same(PA, PB))
    k == 14 && return (push!(E1, n); Int64(length(E2)) + 10 * same(E1, E2))
    k == 15 && return (MX[1] = n; MY[1]::Int64 + 10 * same(MX, MY))
    k == 16 && return (BV1[1] = n > 100; Int64(BV2[1]) + 10 * same(BV1, BV2))
    k == 17 && return (MAT1[2, 2] = n; MAT2[2, 2] + 10 * same(MAT1, MAT2))
    k == 18 && return (D1[3] = n; Int64(haskey(D2, 3)) + 10 * Int64(length(D2)))
    k == 19 && return (push!(ST1, n); Int64(n in ST2) + 10 * Int64(length(ST2)))
    k == 20 && return (T1[1][1] = n; T2[1][1] + 100 * same(T1[1], T2[1]))
    k == 21 && return (Q1[1] = n; Q2[1] + 10 * same(Q1, Q2))
    k == 22 && return (MU1[2] = n; Int64(isassigned(MU2, 2)) + 10 * same(MU1, MU2))
    k == 23 && return (A14[1] = n; copyto!(B14, 2, A14, 1, 2); B14[1] * 100 + B14[2] * 10 + B14[3])
    return Int64(-1)
end
@testset "a mutable constant is its object: equal contents never share storage, one object reached twice is one" begin
    # every module compiled before any native call writes a constant
    local own = WasmTarget.compile(ident, (Int64, Int64))
    local plain = WasmTarget.compile(ident, (Int64, Int64); optimize = false)
    local cases = [WTChild.RunCase("ident$k", plain, (Int64(k), Int64(5)), WTChild.native_answer(ident, (Int64(k), Int64(5))); optimized = own)
                   for k in 1:23]
    # native: a write through one of two equal objects is never read through the other; through one object, always
    @test [c.native for c in cases][1:6] == [1, 5, 5 + 10, 5 + 10, 5 + 10, 1]
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 23 && all(r -> r.ok, results)
end
end

# A Dict's own storage held as a constant of its own (getfield(d, :vals)) is the Dict's Memory: one Julia object, one
# module object by every path, whichever the compile meets first (the plain module keeps the statements' order: the
# Dict first, or its Memory first), as _array_live_ref's rule gives an Array's memory when its owner leaves nothing out.
# An isbits key Memory whose dead slot keeps a deleted key's bytes is no value of the Dict's live copy, so the Memory
# and the copy cannot be one object: refused, located, in either order (dev/formal/ObjectIdentity.tla
# WriteSeenSameConstant; never two objects for one Memory)
module DictStorageIdentity
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
same(x, y) = Int64(Base.inferencebarrier(x) === Base.inferencebarrier(y))
const D9 = Dict{Int64,Any}(1 => 10)
const DV9 = getfield(D9, :vals)
vsum(v::Memory{Any}) = (s = Int64(0); for i in eachindex(v); isassigned(v, i) && (s += v[i]::Int64); end; s)
dict_first(n::Int64) = (D9[1] = n; vsum(DV9) + 1000 * same(getfield(D9, :vals), DV9))
memory_first(n::Int64) = (v = DV9; D9[1] = n; vsum(v) + 1000 * same(v, getfield(D9, :vals)))
const DK = let d = Dict{Int64,Int64}(1 => 10, 7 => 70); delete!(d, 7); d end   # key 7's bytes stay in a dead slot
const KK = getfield(DK, :keys)
keys_dict_first(n::Int64) = (DK[n] = 1; Int64(length(KK)) + n)
keys_memory_first(n::Int64) = (k = KK; DK[n] = 1; Int64(length(k)) + n)
refusal(f) = try; WasmTarget.compile(f, (Int64,); optimize = false); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
@testset "a Dict's storage held as a constant of its own is the Dict's, in either order; never two objects" begin
    @test !Base.isslotfilled(DK, findfirst(==(7), DK.keys))   # the deleted key's bytes, in a slot the Dict does not fill
    local mods = [(f, WasmTarget.compile(f, (Int64,); optimize = false), WasmTarget.compile(f, (Int64,))) for f in (dict_first, memory_first)]
    local cases = [WTChild.RunCase(string(nameof(f)), plain, (Int64(5),), WTChild.native_answer(f, (Int64(5),)); optimized = own) for (f, plain, own) in mods]
    @test [c.native for c in cases] == [1005, 1005]
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 2 && all(r -> r.ok, results)
    for f in (keys_dict_first, keys_memory_first)
        local r = refusal(f)
        @test r isa WasmTarget.ProgramError
    end
end
end
