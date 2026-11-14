# Julia's object id against native Julia (src/patch/runtime_internals.jl over src/julia/runtime/hashing.jl
# jl_object_id): Base's objectid calls the runtime's jl_object_id through a ccall, and the overlay calls
# the runtime's function ported. Natively the port answers as the runtime over many values; compiled, each
# case answers as native Julia, both modules. A mutable object's id (its address's hash) stays Base's
# ccall, a located rejection.
# The types this file declares live in a module made at run time, whose types' hashes differ in every
# process (julia/src/datatype.c:84 from julia/src/module.c:512's build_id); the module folds in the
# compiling process's (src/julia/runtime/hashing.jl datatype_hash). The cases whose answer is the id of a
# value of such a type (p2, p3, pu, pn, empty, clo) equal native Julia because the native answer is
# taken in the compiling process itself (WTChild.answer_cases): equal by that construction, not in any
# other process. The others take Base's types (a String, a Symbol, a bits value, a tuple, CodeUnits) or
# compare two ids (cu), equal to native Julia in every process.
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
const W = Main.WasmTarget
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
mut(x::Int64) = reinterpret(Int64, objectid(PM(MM(x))))
end

const C = ObjectIdCases
const OBJECTID_CASES = (
    ("str", C.str, (Int64(1),)), ("str", C.str, (Int64(123456789),)), ("sym", C.sym, (Int64(1),)), ("sym", C.sym, (Int64(3),)),
    ("sym", C.sym, (Int64(4),)), ("symhash", C.symhash, (Int64(2),)), ("symdict", C.symdict, (Int64(7),)),
    ("i8", C.i8, (Int64(-3),)), ("i8", C.i8, (Int64(100),)), ("i16", C.i16, (Int64(-2),)), ("i16", C.i16, (Int64(300),)),
    ("f32", C.f32, (Int64(1),)), ("f64", C.f64, (-0.0,)), ("f64", C.f64, (NaN,)), ("f64", C.f64, (reinterpret(Float64, 0x7ff8000000000123),)),
    ("i128", C.i128, (Int64(-5),)), ("pair", C.pair, (Int64(3),)), ("p2", C.p2, (Int64(4),)), ("p3", C.p3, (Int64(-300),)),
    ("pu", C.pu, (Int64(3),)), ("pu", C.pu, (Int64(4),)), ("pn", C.pn, (Int64(9),)), ("cu", C.cu, (Int64(7),)),
    ("empty", C.empty, (Int64(0),)), ("clo", C.clo, (Int64(5),)))

@testset "runtime/hashing.jl: Julia's object id, ported, natively equal to the runtime's" begin
    local vals = Any[Int8(-3), Int8(100), Int16(-2), UInt16(7), Int32(-9), 1.5f0, -0.0, 0.0, NaN,
        reinterpret(Float64, 0x7ff8000000000123), Inf, Int64(0), Int64(-1), typemax(Int64), Int128(-5), UInt128(2)^100,
        true, false, 'a', 'λ', Float16(2.5), nothing, C.E(), missing, :a, :ab, Symbol("héllo"), Symbol(""),
        (1, 2), (Int32(1), 2.0), (1, "a"), ("a", :b), ((1, 2), (3, 4)), C.P2(1, 2), C.P3(1, 2), C.PU(Int8(1), 3),
        C.PU(2.5, 3), C.PS("q", 4, (Int32(1), 2f0)), C.PN(C.P2(3, 4), C.PS("r", 5, (Int32(0), -0f0))),
        () -> 3, sin, Base.CodeUnits("ab"), Some(1), Some("x"), 1 => 2, "a" => :b, 1:3, 1.0:0.5:2.0,
        Complex(1.0, -0.0), 1//3, Val(3), ntuple(i -> UInt8(i), 33), C.PM(C.MM(1)), C.MM(2), Ptr{Int}(16), Int, Vector{Int}, Union{Int,String}]
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

# objectid is the overlay over WasmTarget's overlay table; a mutable object's id, its address's hash, which no
# module holds, reaches Base's ccall of jl_object_id and rejects at the foreign call, located
@testset "objectid takes the overlay; a mutable object's id rejects, located" begin
    @test Base._which(Tuple{typeof(objectid), Any};
        method_table = Core.Compiler.OverlayMethodTable(Base.get_world_counter(), WasmTarget.METHOD_TABLE)).method.module === WasmTarget
    local e = try; WasmTarget.compile(C.mut, (Int64,)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && occursin("nir_foreign_import", sprint(showerror, e)) && occursin("jl_object_id", sprint(showerror, e))
end
