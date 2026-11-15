# A Memory's data id in a module (src/patch/genericmemory.jl dataids): its data owner's identity hash field, read
# by codegen's data-owner reader (src/intrinsics.jl's lowering of the jl_genericmemory_owner ccall over a byte
# Memory's `data#owner`, src/julia/classes.jl _memory_instance_fields) and filled from the one identity counter
# (src/runtime/common/object_patch.jl Object__object_hash_code) through the data owner's arm (src/julia/runtime/
# hashing.jl jl_genericmemory_owner_arm), where Julia reads the data's address (julia/base/abstractarray.jl:1591).
# The model: dev/formal/ObjectIdentity.tla (DataIdsExact, StringSlotDataOnly). Every answer is a comparison, true
# natively, so each case's native answer is every bit set; the arms' own cases are the module's alone.
module DataIdsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module DataIdsCases
using WasmTarget
using WasmTarget: Runtime
const KS = "hello"
const KV = Int64[1, 2, 3]
# k selects the case
function ids(k::Int64, x::Int64)::Int64
    if k == 1       # two Memories over one String's bytes: one data id; a Memory memorynew makes: its own; the two
                    # wraps are two objects
        local s = repeat("ab", x)
        local m1, m2 = unsafe_wrap(Memory{UInt8}, s), unsafe_wrap(Memory{UInt8}, s)
        local m3 = Memory{UInt8}(undef, 2x)
        return Int64(Base.dataids(m1) == Base.dataids(m2)) + 2 * Int64(Base.dataids(m1) != Base.dataids(m3)) +
               4 * Int64(objectid(m1) != objectid(m2)) + 8 * Int64(Base.dataids(m3) == Base.dataids(m3))
    elseif k == 2   # two wraps of one constant String: one data id; a String of equal bytes made at run time: another
        local m1 = unsafe_wrap(Memory{UInt8}, KS)
        local m2 = unsafe_wrap(Memory{UInt8}, x > 0 ? KS : "other")
        local m3 = unsafe_wrap(Memory{UInt8}, string("hel", repeat("l", x), "o"))
        return Int64(Base.dataids(m1) == Base.dataids(m2)) + 2 * Int64(Base.dataids(m1) != Base.dataids(m3))
    elseif k == 3   # mightalias of an Array and a view of it, a copy, a reshape of it
        local a = collect(1:x)
        return Int64(Base.mightalias(a, view(a, 1:2))) + 2 * Int64(!Base.mightalias(a, collect(1:x))) +
               4 * Int64(Base.mightalias(a, reshape(a, 2, 2)))
    elseif k == 4   # a constant Array: one data id by two reads, another than its copy's
        local c = copy(KV)
        return Int64(Base.mightalias(KV, KV)) + 2 * Int64(!Base.mightalias(KV, c)) +
               4 * Int64(Base.dataids(KV.ref.mem) == Base.dataids(KV.ref.mem))
    else            # a Memory of another element type, memorynew's, each its own data
        local a, b = Memory{Int64}(undef, x), Memory{Int64}(undef, x)
        return Int64(Base.dataids(a) != Base.dataids(b)) + 2 * Int64(Base.dataids(a) == Base.dataids(a))
    end
end
# a broadcast into an Array from a reversed view of it, which unaliases through dataids (the hold's shape)
function bcast(x::Int64)::Int64
    local v = collect(1:x)
    v .= @view v[end:-1:1]
    return v[1] * 1000 + v[2] * 100 + v[3] * 10 + v[4]
end
# a byte Vector over a String's bytes (StringVector, julia/base/iobuffer.jl:168, its Memory sharing the String's
# bytes), written through, then taken as a String (julia/base/strings/string.jl:65 String(::Vector{UInt8}),
# jl_genericmemory_to_string): k 1 takes the whole Memory, Julia's branch returning the owning String
# (julia/src/genericmemory.c:203-207), which holds the bytes written; k 2 a Memory longer than the Vector, Julia's
# other branch where the module copies the first bytes. The answer: the length, the three bytes, the Vector emptied
function taken(k::Int64, x::Int64)::Int64
    local v = Base.StringVector(k == 1 ? 3 : 5)
    v[1] = 0x61
    v[2] = 0x62
    v[3] = UInt8(0x60 + x)
    k == 1 || resize!(v, 3)
    local s = String(v)
    return Int64(isempty(v)) * 10^10 + Int64(ncodeunits(s)) * 10^9 +
           Int64(codeunit(s, 1)) * 10^6 + Int64(codeunit(s, 2)) * 10^3 + Int64(codeunit(s, 3))
end
# a String's identity hash field written through the data owner's arm: admitted, the module's first serial
owner_write(x::Int64)::Int64 = Runtime.Object__object_hash_code(repeat("a", x), WasmTarget.set_owner_identity_hash_field)
# and through objectid's arm: refused, located
objectid_write(x::Int64)::Int64 = Runtime.Object__object_hash_code(repeat("a", x), Runtime.set_identity_hash_field)
end

const DC = DataIdsCases

@testset "dataids of a Memory is its data owner's id" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(DC.ids, (Int64(1), Int64(4)))
    local args = [(Int64(1), Int64(3)), (Int64(2), Int64(1)), (Int64(3), Int64(4)), (Int64(4), Int64(1)), (Int64(5), Int64(2))]
    local cases = [Main.WTChild.RunCase("dataids/ids$a", plain, a, Main.WTChild.native_answer(DC.ids, a); optimized = opt) for a in args]
    # each comparison is true natively
    @test [c.native for c in cases] == [15, 3, 7, 7, 3]
    push!(cases, Main.WTChild.compiled_case("dataids/bcast", WasmTarget.compile, DC.bcast, (Int64(4),)))
    @test cases[end].native == 4321
    # the taken String holds the bytes written through the Memory: the whole Memory and a longer one
    local (tp, to) = both(DC.taken, (Int64(1), Int64(3)))
    for a in [(Int64(1), Int64(3)), (Int64(2), Int64(4))]
        push!(cases, Main.WTChild.RunCase("dataids/taken$a", tp, a, Main.WTChild.native_answer(DC.taken, a); optimized = to))
    end
    @test [c.native for c in cases[end-1:end]] == [13_097_098_099, 13_097_098_100]
    # the data owner's arm admits a String: never run natively (the field is the module's), the module's first serial
    local (wp, wo) = both(DC.owner_write, (Int64(2),))
    push!(cases, Main.WTChild.RunCase("dataids/owner_write", wp, (Int64(2),), Int64(1); optimized = wo))
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # objectid's arm refuses a String, located: its id is its bytes', never the field
    local e = try; WasmTarget.compile(DC.objectid_write, (Int64,)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && occursin("whose id Julia answers by its own hash or content", sprint(showerror, e))
    # the two arms, one definition each: a String owns data, and is no identity
    @test WasmTarget.jl_genericmemory_owner_arm(String) && !WasmTarget.jl_object_id_identity_arm(String)
    @test all(WasmTarget.jl_genericmemory_owner_arm, (Memory{UInt8}, Memory{Int64}, Base.RefValue{Int}))
    @test !any(WasmTarget.jl_genericmemory_owner_arm, (Symbol, Core.SimpleVector, Int64, Tuple{Int}))
end

end # module
