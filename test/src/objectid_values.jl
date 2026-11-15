# Julia's object id against native Julia (src/patch/runtime_internals.jl over src/julia/runtime/hashing.jl
# jl_object_id), the values the runtime answers by content: Base's objectid calls the runtime's
# jl_object_id through a ccall, and the overlay calls the runtime's function ported. Natively the port
# answers as the runtime over many values; compiled, each case answers as native Julia, both modules. A
# mutable object's id, its identity's, is test/src/objectid_identity.jl's; natively that arm raises,
# Base's own objectid the answer. Split from test/src/runtime_internals.jl with
# test/src/objectid_structs.jl and test/src/objectid_identity.jl: every testset verbatim but the native
# one's list, which no longer holds a mutable object (its arm is a module's alone).
# The types this file declares live in a module made at run time, whose types' hashes differ in every
# process (julia/src/datatype.c:84 from julia/src/module.c:512's build_id); the module folds in the
# compiling process's (src/julia/runtime/hashing.jl datatype_hash). The cases here take Base's types (a
# String, a Symbol, a bits value), equal to native Julia in every process.
module ObjectIdValuesTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module ObjectIdCases
struct P2; a::Int64; b::Int64; end
struct P3; a::Int8; b::Int16; end
struct PU; a::Union{Int8,Float64}; b::Int32; end
struct PS; s::String; n::Int64; t::Tuple{Int32,Float32}; end
struct PN; p::P2; q::PS; end
struct E end
mutable struct MM; x::Int64; end
struct PM; m::MM; end
# each case's answer the id itself, as a signed integer
str(x::Int64) = reinterpret(Int64, objectid(string("ab", x)))
# a Symbol only run time knows, chosen from constants (a Symbol made of a String at run time is
# jl_symbol_n's, Symbol(::String), apart from the id)
syms(x::Int64) = (:a, :ab, :héllo, :a_longer_symbol_of_more_than_sixteen_bytes)[x]
sym(x::Int64) = reinterpret(Int64, objectid(syms(x)))
symhash(x::Int64) = reinterpret(Int64, hash(syms(x)))
symdict(x::Int64) = (d = Dict{Symbol,Int64}(:a => x, :b => 2); d[syms(1)] * 10 + d[:b])
i8(x::Int64) = reinterpret(Int64, objectid(x % Int8))
i16(x::Int64) = reinterpret(Int64, objectid(x % Int16))
f32(x::Int64) = reinterpret(Int64, objectid(Float32(x) / 3.0f0))
f64(x::Float64) = reinterpret(Int64, objectid(x))
end

const C = ObjectIdCases
const OBJECTID_CASES = (
    ("str", C.str, (Int64(1),)), ("str", C.str, (Int64(123456789),)), ("sym", C.sym, (Int64(1),)), ("sym", C.sym, (Int64(3),)),
    ("sym", C.sym, (Int64(4),)), ("symhash", C.symhash, (Int64(2),)), ("symdict", C.symdict, (Int64(7),)),
    ("i8", C.i8, (Int64(-3),)), ("i8", C.i8, (Int64(100),)), ("i16", C.i16, (Int64(-2),)), ("i16", C.i16, (Int64(300),)),
    ("f32", C.f32, (Int64(1),)), ("f64", C.f64, (-0.0,)), ("f64", C.f64, (NaN,)), ("f64", C.f64, (reinterpret(Float64, 0x7ff8000000000123),)),)

@testset "runtime/hashing.jl: Julia's object id, ported, natively equal to the runtime's" begin
    local vals = Any[Int8(-3), Int8(100), Int16(-2), UInt16(7), Int32(-9), 1.5f0, -0.0, 0.0, NaN,
        reinterpret(Float64, 0x7ff8000000000123), Inf, Int64(0), Int64(-1), typemax(Int64), Int128(-5), UInt128(2)^100,
        true, false, 'a', 'λ', Float16(2.5), nothing, C.E(), missing, :a, :ab, Symbol("héllo"), Symbol(""),
        (1, 2), (Int32(1), 2.0), (1, "a"), ("a", :b), ((1, 2), (3, 4)), C.P2(1, 2), C.P3(1, 2), C.PU(Int8(1), 3),
        C.PU(2.5, 3), C.PS("q", 4, (Int32(1), 2f0)), C.PN(C.P2(3, 4), C.PS("r", 5, (Int32(0), -0f0))),
        () -> 3, sin, Base.CodeUnits("ab"), Some(1), Some("x"), 1 => 2, "a" => :b, 1:3, 1.0:0.5:2.0,
        Complex(1.0, -0.0), 1//3, Val(3), ntuple(i -> UInt8(i), 33), Ptr{Int}(16), Int, Vector{Int}, Union{Int,String}]
    @test filter(v -> WasmTarget.jl_object_id(v) != objectid(v), vals) == []
    # every byte length 0..64 and a few long ones: a String, a Symbol of it (no NUL, which no Symbol's name
    # holds), and a tuple of as many bytes
    local lens = [0:64; 100; 1000; 4097]
    @test filter(n -> (local s = String(UInt8[(31j + n) % 255 + 1 for j in 1:n]);
        WasmTarget.jl_object_id(s) != objectid(s) || WasmTarget.jl_object_id(Symbol(s)) != objectid(Symbol(s))), lens) == []
    @test filter(n -> (local t = ntuple(i -> UInt8((7i + n) % 256), n); WasmTarget.jl_object_id(t) != objectid(t)), 0:64) == []
    # a field's storage, jl_field_isptr's: a String and a mutable by reference, a bits and an immutable inline
    @test WasmTarget.jl_field_isptr(C.PS, 1) && !WasmTarget.jl_field_isptr(C.PS, 2) && !WasmTarget.jl_field_isptr(C.PS, 3)
    @test !WasmTarget.jl_field_isptr(C.PN, 2) && WasmTarget.jl_field_isptr(C.PM, 1) && !WasmTarget.jl_field_isptr(C.PU, 1)
    # a mutable object's id is its identity's, a module's alone: natively the arm raises (Base's objectid answers)
    @test_throws ErrorException WasmTarget.jl_object_id(C.MM(2))
    @test_throws ErrorException WasmTarget.jl_object_id(C.PM(C.MM(1)))
end

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
