# Julia's object id against native Julia (src/patch/runtime_internals.jl over src/julia/runtime/hashing.jl
# jl_object_id), compiled, over tuples, structs, a closure and CodeUnits: each case answers as native
# Julia, both modules. Split from test/src/runtime_internals.jl with test/src/objectid_values.jl and
# test/src/objectid_identity.jl, its testset verbatim.
# The types this file declares live in a module made at run time, whose types' hashes differ in every
# process (julia/src/datatype.c:84 from julia/src/module.c:512's build_id); the module folds in the
# compiling process's (src/julia/runtime/hashing.jl datatype_hash). The cases whose answer is the id of a
# value of such a type (p2, p3, pu, pn, empty, clo) equal native Julia because the native answer is
# taken in the compiling process itself (WTChild.answer_cases): equal by that construction, not in any
# other process. The others take Base's types (a String, a Symbol, a bits value, a tuple, CodeUnits) or
# compare two ids (cu), equal to native Julia in every process.
module ObjectIdStructsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module ObjectIdCases
struct P2; a::Int64; b::Int64; end
struct P3; a::Int8; b::Int16; end
struct PU; a::Union{Int8,Float64}; b::Int32; end
struct PS; s::String; n::Int64; t::Tuple{Int32,Float32}; end
struct PN; p::P2; q::PS; end
struct E end
const W = Main.WasmTarget
i128(x::Int64) = reinterpret(Int64, objectid(Int128(x) << 70))
pair(x::Int64) = reinterpret(Int64, objectid((x, x + 1)))
# the id of a value of a type of this module: equal to native Julia in the compiling process alone
p2(x::Int64) = reinterpret(Int64, objectid(P2(x, -x)))
p3(x::Int64) = reinterpret(Int64, objectid(P3(x % Int8, x % Int16)))
pu(x::Int64) = reinterpret(Int64, objectid(isodd(x) ? PU(x % Int8, Int32(1)) : PU(x / 2, Int32(2))))
pn(x::Int64) = reinterpret(Int64, objectid(PN(P2(x, 2), PS(string(x), x, (Int32(x), Float32(x))))))
# a comparison of two ids of Base's CodeUnits: equal to native Julia in every process
cu(x::Int64) = objectid(Base.CodeUnits(string(x))) == objectid(Base.CodeUnits(string(x))) ? Int64(1) : Int64(0)
# the id of a value of a type of this module (a struct, a closure): the compiling process alone
empty(x::Int64) = reinterpret(Int64, objectid(E())) + x
clo(x::Int64) = (f = () -> x; reinterpret(Int64, hash(f)))
end

const C = ObjectIdCases
const OBJECTID_CASES = (
    ("i128", C.i128, (Int64(-5),)), ("pair", C.pair, (Int64(3),)), ("p2", C.p2, (Int64(4),)), ("p3", C.p3, (Int64(-300),)),
    ("pu", C.pu, (Int64(3),)), ("pu", C.pu, (Int64(4),)), ("pn", C.pn, (Int64(9),)), ("cu", C.cu, (Int64(7),)),
    ("empty", C.empty, (Int64(0),)), ("clo", C.clo, (Int64(5),)))

@testset "objectid against native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, args) in OBJECTID_CASES
        local label = "runtime_internals/$name$args"
        # every case compiles, both modules: a rejection is this case's located error, never a pass
        @testset "$label compiles" begin
            append!(runs, first(Main.WTChild.answer_cases(label, WasmTarget.compile, f, args)))
        end
    end
    for r in Main.WTChild.run_cases(runs)
        @test (r.label => r.why) == (r.label => "")
    end
end

end # module
