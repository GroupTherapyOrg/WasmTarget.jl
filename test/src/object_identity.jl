# A constant's identity in a module, as Julia's image keeps it (src/julia/runtime/hashing.jl image_slot!,
# image_object_id, over dart's identity hash slot): a constant whose identity the program reads is made with
# its slot -k, IMAGE_IDS's entry k the compiling process's objectid of the Julia object the constant stands
# for (its key's object: a live copy's original, src/julia/classes.jl memory_constant_object). The model:
# dev/formal/ConstantImageIds.tla. Natively no object carries the slot (its read raises), so each compiled
# case's answer is computed in this process: a constant's objectid here, or a sum of comparisons each true.
using Test, WasmTarget, Random
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module ImageIdCases
using WasmTarget: Runtime, image_object_id
mutable struct Cell; x::Int64; end
const K1 = Cell(1)
const K2 = Cell(1)                                          # equal contents, a distinct object
const A = [1, 2, 3]
const B = [1, 2, 3]                                         # equal contents, a distinct Array
const PAIR = (K1, K1)                                       # one constant by two paths
const A3 = let a = [1, 2, 3, 4]; pop!(a); a end             # its Memory longer than its size: a live copy
const A4 = Base.wrap(Array, getfield(A3, :ref).mem, (3,))   # a second Array over that Memory
const DV = let d = Dict{String,Int64}("a" => 1, "b" => 2); delete!(d, "b"); d end   # its vals a live copy
const DT = (DV, DV)                                         # one Dict by two paths
const S = "a String constant"                              # its id its bytes': no image slot
slot(@nospecialize(o)) = Runtime.get_identity_hash_field(o) % Int32
# the id a constant's image keeps, read through its slot (-k selects IMAGE_IDS[k]); -1 for a slot no
# image's (no constant here has the id -1: checked natively below)
img(@nospecialize(o)) = (s = slot(o); s < 0 ? reinterpret(Int64, image_object_id(-Int(s))) : Int64(-1))
mem3(x::Int64) = getfield(x == 1 ? A3 : A4, :ref).mem
function ids(k::Int64, x::Int64)
    k == 1 && return img(K1)
    k == 2 && return img(K2)
    k == 3 && return img(A)
    k == 4 && return img(B)
    k == 5 && return img(mem3(x))                           # the original Memory's id, through either Array
    k == 6 && return img(getfield(DV, :vals))               # the original vals' id, through its live copy
    # distinct constants of equal contents, distinct ids; one constant by two paths, one id and one object
    k == 7 && return Int64(img(K1) != img(K2)) + 2 * Int64(img(A) != img(B)) + 4 * Int64(img(PAIR[1]) == img(PAIR[x])) +
                     8 * Int64(mem3(1) === mem3(2)) + 16 * Int64(getfield(DV, :vals) === getfield(DT[x], :vals))
    # a fresh object's slot is dart's 0; a String's id is its bytes', so a String, made at run time or a
    # constant, holds no image slot
    return Int64(slot(Cell(x)) == 0) + 2 * Int64(slot(string("ab", x)) == 0) + 4 * Int64(slot(S) == 0)
end
end

const C = ImageIdCases
id_of(o) = reinterpret(Int64, objectid(o))
const IMAGE_CASES = (((1, 1), id_of(C.K1)), ((2, 1), id_of(C.K2)), ((3, 1), id_of(C.A)), ((4, 1), id_of(C.B)),
    ((5, 1), id_of(getfield(C.A3, :ref).mem)), ((5, 2), id_of(getfield(C.A3, :ref).mem)), ((6, 1), id_of(getfield(C.DV, :vals))),
    ((7, 1), Int64(31)), ((7, 2), Int64(31)), ((8, 3), Int64(7)))

@testset "runtime/hashing.jl: which values are identities, and int64hash's inverse" begin
    # the identity arm is exactly the image writer's object_id_expected set (julia/src/staticdata.c:1512)
    @test all(WasmTarget.jl_object_id_identity_arm, (C.Cell, Vector{Int}, Memory{Int}, Base.RefValue{Int}, Dict{Int,Int}))
    @test !any(WasmTarget.jl_object_id_identity_arm, (String, Core.SimpleVector, DataType, Core.TypeName, Module, Int64, Tuple{Int}, Symbol))
    local ws = UInt64[0, typemax(UInt64), 1, typemax(Int32), rand(Random.Xoshiro(20261114), UInt64, 1000)...]
    @test filter(w -> WasmTarget.int64hash_inverse(WasmTarget.int64hash(w)) != w, ws) == []
    # an id a serial gives is refused (dev/formal/ConstantImageIds.tla NoCollisionCheck); this file's constants' are not
    @test WasmTarget.image_id_meets_serial(WasmTarget.int64hash(UInt64(5))) && WasmTarget.image_id_meets_serial(WasmTarget.int64hash(UInt64(typemax(Int32))))
    @test !WasmTarget.image_id_meets_serial(WasmTarget.int64hash(UInt64(typemax(Int32)) + 1))
    @test all(o -> !WasmTarget.image_id_meets_serial(objectid(o)) && id_of(o) != -1,
              (C.K1, C.K2, C.A, C.B, getfield(C.A3, :ref).mem, getfield(C.DV, :vals)))
end

@testset "constants' image ids against the compiling process's" begin
    local bytes = WasmTarget.compile(C.ids, (Int64, Int64))
    for r in Main.WTChild.run_cases([Main.WTChild.RunCase("object_identity/ids$a", bytes, a, want) for (a, want) in IMAGE_CASES])
        @test r.ok || (@info r.label r.why; false)
    end
    # natively the slot's read raises: the slot is a module's alone
    @test_throws ErrorException WasmTarget.Runtime.get_identity_hash_field(C.K1)
end

# an observation of today, not the reason the image id is right (the id is the original's whether or not
# a call folds): objectid of an Array's Memory and of a Dict's vals is a run-time call, their fields no const fields
@testset "objectid of a live copy's original is a run-time call today" begin
    for f in (() -> objectid(getfield(C.A3, :ref).mem), () -> objectid(getfield(C.DV, :vals)))
        @test !(only(Base.code_typed(f, ()))[1].code[end].val isa UInt64)
    end
end
