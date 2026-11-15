# A mutable object's id in a module (src/julia/runtime/hashing.jl jl_object_id_identity): its identity's,
# the serial dart's lazy fill gives it (src/runtime/common/object_patch.jl Object__object_hash_code, from
# a counter) hashed by int64hash where Julia hashes its address (julia/src/builtins.c:484), or the id an
# image constant keeps (image_object_id). The models: dev/formal/ObjectIdentity.tla and
# dev/formal/ConstantImageIds.tla. Every answer is a comparison, true natively (Base's objectid), or the
# id of a constant, the compiling process's (WTChild.native_answer runs in it). Split from
# test/src/runtime_internals.jl with test/src/objectid_values.jl and test/src/objectid_structs.jl: its
# overlay testset, whose rejection of a mutable object's id this arm replaces by the cases below.
module ObjectIdIdentityTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module IdentityCases
using WasmTarget: Runtime
mutable struct MM; x::Int64; end
struct PM; m::MM; end
const KM = MM(7)
const KM2 = MM(7)                       # equal contents, a distinct object
const KPAIR = (KM, KM)                  # one constant by two paths
# one closure type capturing a mutable: two of it over one object are ===, over two objects not
capture(o::MM) = () -> o.x
# k selects the case (an empty String's Memory, a PersistentDict and a ScopedValue are programs of their
# own, below, so a gap one meets is located to it)
function ident(k::Int64, x::Int64)::Int64
    if k == 1       # two fresh mutables, two ids; one object's id stable; a fresh one's no constant's
        local a, b = MM(x), MM(x)
        local i = objectid(a)
        return Int64(i != objectid(b)) + 2 * Int64(i == objectid(a)) + 4 * Int64(objectid(b) != objectid(KM))
    elseif k == 2   # a constant's id, the compiling process's
        return reinterpret(Int64, objectid(x > 0 ? KM : KM2))
    elseif k == 3   # distinct constants of equal contents, two ids; one constant by two paths, one
        return Int64(objectid(KM) != objectid(KM2)) + 2 * Int64(objectid(KPAIR[1]) == objectid(KPAIR[x]))
    elseif k == 4   # a mutable inside an immutable: its id the mutable's; two such, two ids
        local p = PM(MM(x))
        return Int64(objectid(p) == objectid(PM(p.m))) + 2 * Int64(objectid(p) != objectid(PM(MM(x))))
    elseif k == 5   # one closure type's hash over one mutable and over another (the hold's shape)
        local o, o2 = MM(x), MM(x)
        return Int64(hash(capture(o)) == hash(capture(o))) + 2 * Int64(hash(capture(o)) != hash(capture(o2)))
    else            # an empty Memory made at run time is the type's one empty instance, as natively
        local a, b = Memory{Int64}(undef, 0), Memory{Int64}(undef, x - x)
        return Int64(a === b) + 2 * Int64(objectid(a) == objectid(b))
    end
end
# an empty String's Memory (jl_string_to_genericmemory, julia/src/genericmemory.c:106-107) is
# Memory{UInt8}'s one empty instance, a constant empty String's and one made at run time alike: `===` and
# the ids of each against the Memory memorynew makes of no element
function emptystr(x::Int64)::Int64
    local m0 = Memory{UInt8}(undef, x - x)
    local m1 = unsafe_wrap(Memory{UInt8}, "")
    local m2 = unsafe_wrap(Memory{UInt8}, repeat("a", x - x))
    return Int64(m1 === m0) + 2 * Int64(m2 === m0) + 4 * Int64(objectid(m1) == objectid(m0)) + 8 * Int64(objectid(m2) == objectid(m0))
end
# a ScopedValue, a mutable whose scope is a PersistentDict keyed by its id (julia/base/scopedvalues.jl:82)
const SV = Base.ScopedValues.ScopedValue(1)
scoped(x::Int64)::Int64 = Base.ScopedValues.with(() -> SV[], SV => x)
# Base's PersistentDict, a HAMT with no collision node (julia/base/hamt.jl:205): n fresh mutable keys
function hamt(n::Int64)::Int64
    local ks = [MM(i) for i in 1:n]
    local d = Base.PersistentDict{MM,Int64}()
    for (i, k) in enumerate(ks)
        d = Base.PersistentDict(d, k => i)
    end
    local s = 0
    for k in ks
        s += d[k]
    end
    return s
end
# the counter spent: preset to its last serial but one, an object takes the last, the next raises. Read
# through the runtime's Object__object_hash_code, whose results are kept
function spent(x::Int64)::Int64
    Runtime.Object__hash_code_rnd[] = typemax(Int32) - Int32(1)
    local last = Runtime.Object__object_hash_code(MM(x))
    try
        return -Runtime.Object__object_hash_code(MM(x))
    catch e
        return e isa ErrorException ? last : Int64(-1)
    end
end
# a module's first serial: 1, its counter starting at 0 (natively the slot's read raises)
first_serial(x::Int64)::Int64 = Runtime.Object__object_hash_code(MM(x))
# the identity hash field of a value Julia boxes fresh: refused, located
boxed(x::Int64)::Int64 = Runtime.get_identity_hash_field(x)
end

const IC = IdentityCases

@testset "objectid takes the overlay; a mutable object's id is its identity's" begin
    @test Base._which(Tuple{typeof(objectid), Any};
        method_table = Core.Compiler.OverlayMethodTable(Base.get_world_counter(), WasmTarget.METHOD_TABLE)).method.module === WasmTarget
    # each program's two modules, codegen's and wasm-opt's (test/verdict.jl _modules), each case read from both
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(IC.ident, (Int64(1), Int64(1)))
    local args = [(Int64(1), Int64(3)), (Int64(2), Int64(1)), (Int64(2), Int64(-1)), (Int64(3), Int64(1)), (Int64(3), Int64(2)),
                  (Int64(4), Int64(5)), (Int64(5), Int64(6)), (Int64(6), Int64(4))]
    local cases = [Main.WTChild.RunCase("objectid_identity/ident$a", plain, a, Main.WTChild.native_answer(IC.ident, a); optimized = opt) for a in args]
    # each comparison is true natively, so the answers are 7, 3, 3, 3, 3 and 3 (their native answers above)
    @test [c.native for c in cases][[1, 4, 5, 6, 7, 8]] == [7, 3, 3, 3, 3, 3]
    # an empty String's Memory, its own program: natively each of its four comparisons true, 15
    push!(cases, Main.WTChild.compiled_case("objectid_identity/emptystr", WasmTarget.compile, IC.emptystr, (Int64(3),)))
    @test cases[end].native == 15
    # a ScopedValue read in its scope, its own program: Julia's trim verifier refuses it, located (with's
    # PersistentDict{ScopedValue,Any} reaches HashState over its abstract key, an unresolved call,
    # julia/base/hamt.jl:205), before any id is asked
    local se = try; WasmTarget.compile(IC.scoped, (Int64,)); nothing; catch x; x; end
    @test se isa WasmTarget.RejectionError && occursin("outside the strict subset", sprint(showerror, se)) &&
          occursin("HashState", sprint(showerror, se))
    # a PersistentDict of fresh mutable keys, its own program: it stops at a gap of its own, located, the type
    # HashState{K} as a value, a class the closed world does not number (src/constants.jl
    # _makeInterfaceTypeConstant), before any id is asked
    local he = try; WasmTarget.compile(IC.hamt, (Int64,)); nothing; catch x; x; end
    @test he isa WasmTarget.RejectionError && occursin("HashState", sprint(showerror, he)) &&
          occursin("a class the closed world does not number", sprint(showerror, he))
    # the spent counter: never run natively (it would write the compiling process's counter), its answer
    # the last serial given, 2^31 - 1, returned once the next raises
    local (sp, so) = both(IC.spent, (Int64(1),))
    push!(cases, Main.WTChild.RunCase("objectid_identity/spent", sp, (Int64(1),), Int64(typemax(Int32)); optimized = so))
    local (fp, fo) = both(IC.first_serial, (Int64(1),))
    push!(cases, Main.WTChild.RunCase("objectid_identity/first_serial", fp, (Int64(1),), Int64(1); optimized = fo))
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # natively the identity arm raises: Base's own objectid is the answer there
    @test_throws ErrorException WasmTarget.jl_object_id(IC.MM(2))
    # the module's counter is the compiling process's cell, which must hold 0: one a native run wrote (here
    # preset, restored after) is refused, located, never a module whose first serial is its successor
    local saved = WasmTarget.Runtime.Object__hash_code_rnd[]
    try
        WasmTarget.Runtime.Object__hash_code_rnd[] = Int32(5)
        local ce = try; WasmTarget.compile(IC.first_serial, (Int64,)); nothing; catch x; x; end
        @test ce isa WasmTarget.RejectionError && occursin("identity counter", sprint(showerror, ce))
    finally
        WasmTarget.Runtime.Object__hash_code_rnd[] = saved
    end
    @test WasmTarget.Runtime.Object__hash_code_rnd[] == 0
    # a value Julia boxes fresh has no identity hash field that lasts: refused, located
    local e = try; WasmTarget.compile(IC.boxed, (Int64,)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && occursin("boxes fresh", sprint(showerror, e))
end

end # module
