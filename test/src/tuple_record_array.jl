# A tuple held where its static type is open is its arity's record (src/julia/classes.jl TupleRecord), dart's record
# class of a shape: a class of the closed world, never Julia's type of the tuple. Julia's typeof of a tuple is the tuple
# type of its elements' types (julia/src/builtins.c:946 jl_f_tuple), found in its type cache or made. typeof of a value
# that may be a record answers the record by its own arm (src/intrinsics.jl to_typeof): the one tuple type the operand's
# inferred type holds at the record's arity (src/julia/classes.jl record_typeof), else a raise naming the statement,
# since WasmTarget makes no type at run time (audit A68S3). The empty tuple's class is Tuple{} itself, its type.

module TupleRecordArrayTest

using Test
using WasmTarget

const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild

module Cases
# Julia keeps typeof a builtin call on a Union of tuple types (1.12.7: `builtin typeof(%1)::Union{Type{Tuple{Int64}},
# Type{Tuple{Int64,Float64}}}`); the value is held as the records of arities 1 and 2. At origin 9700a11c the module read
# the record's own table entry and answered 2 at f(3), where native answers 1; each arity here pins one tuple type
@noinline u(n::Int64) = n > 2 ? (n,) : (n, 1.0)
typeof_of_union(n::Int64) = typeof(u(n)) === Tuple{Int64} ? 1 : 2
# typeof of an Any that holds a tuple at run time: no type of the operand pins the tuple's, so the module raises, named
# and located, where native answers (and answers as native where the element is no tuple). The Memory{UInt8} it
# compares with is a type constant whose Core.AddrSpace parameter brings that class's constant, without which any typeof
# of an Any refuses on Memory{Any} (type_value_unmade), as the corpus's typeof_either does
mutable struct AnySlot; x::Any; end
@noinline any_slot(n::Int64) = AnySlot(n > 2 ? (n, n) : n)
typeof_of_any(n::Int64) = (t = typeof(any_slot(n).x); t === Int64 ? 1 : t === Memory{UInt8} ? 3 : 2)
# a Union of plain classes keeps its typeof: each member's type value is its canonical constant
struct A end
struct B end
@noinline ab(n::Int64) = n > 2 ? A() : B()
typeof_of_classes(n::Int64) = typeof(ab(n)) === A ? 1 : 2
end

@testset "typeof of a tuple record: the type the operand pins, else a raise naming the statement" begin
    # Julia keeps the builtin call (not folded, not union-split away)
    @test any(s -> Meta.isexpr(s, :call) && s.args[1] isa GlobalRef && s.args[1].name === :typeof, Base.code_typed(Cases.typeof_of_union, (Int64,))[1][1].code)
    # the answer the operand's inferred type pins at each record's arity, Julia's own; none where it pins none
    @test W.record_typeof(Union{Tuple{Int64},Tuple{Int64,Float64}}, W.TupleRecord{1}) === Tuple{Int64}
    @test W.record_typeof(Union{Tuple{Int64},Tuple{Int64,Float64}}, W.TupleRecord{2}) === Tuple{Int64,Float64}
    @test W.record_typeof(Tuple{Vararg{Int64}}, W.TupleRecord{2}) === Tuple{Int64,Int64}
    @test W.record_typeof(Any, W.TupleRecord{1}) === nothing && W.record_typeof(Tuple{Any,Any}, W.TupleRecord{2}) === nothing
    @test W.record_typeof_unmade(W.TupleRecord{1}) && W.record_typeof_unmade(W.TupleRecord{2})
    @test !W.record_typeof_unmade(Tuple{}) && !W.record_typeof_unmade(Cases.A) && !W.record_typeof_unmade(Tuple{Int64})
    # the probe and the Union of plain classes answer as native, in codegen's module and wasm-opt's
    local cases = WTChild.RunCase[]
    for f in (Cases.typeof_of_union, Cases.typeof_of_classes), n in Int64[3, 1]
        push!(cases, WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (n,)))
    end
    push!(cases, WTChild.compiled_case("typeof_of_any(1)", W.compile, Cases.typeof_of_any, (Int64(1),)))
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # a tuple reaching typeof of an Any: the module raises the named error, located at the statement, where native
    # answers 2; never another type
    @test Cases.typeof_of_any(3) == 2
    local raised = only(WTChild.run_cases([WTChild.compiled_case("typeof_of_any(3)", W.compile, Cases.typeof_of_any, (Int64(3),))]))
    @test !raised.ok && occursin("throws a wasm exception", raised.why) && occursin("where native Julia answers 2", raised.why)
    # the raise's message, the one text the arm passes (the runner reads a wasm exception's tag, not its message, and Julia
    # proves typeof never throws, so no program can catch it to read it)
    @test W.record_typeof_message(W.TupleRecord{2}, "f: Julia's typeof on Any") ==
          "WasmTarget: typeof of a tuple held as WasmTarget.TupleRecord{2}, at f: Julia's typeof on Any: its type, the tuple type of its elements' types, is not made at run time (audit A68S3)"
end

rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

module SplatCases
# Core.tuple(v...), a tuple whose length only run time knows; no concrete tuple type of 7 elements in this program (an
# isa against NTuple{7,Int64} would bring that class and its record: a hit)
@noinline mk(v::Vector{Int64}) = Core.tuple(v...)
miss(n::Int64) = (t = mk(collect(1:n)); nfields(t) * 100 + t[n])
# a 3-tuple literal brings its arity's record: the splat's 3 elements are that record, === the literal
hit(n::Int64) = mk(fill(n, 3)) === (n, n, n) ? 1 : 2
# a splat into a function that is not the tuple builtin, none of which WasmTarget ports
@noinline mksvec(v::Vector{Int64}) = Core.svec(v...)
other(n::Int64) = length(mksvec(collect(1:n)))
end

world_of(f, at) = W.closed_world_classes(W.build_nir(W.check_subset(f, at, "tuple_record_array", Base.get_world_counter()), "tuple_record_array"), "tuple_record_array")

# Core.tuple(v...): jl_f__apply_iterate's buffer and jl_f_tuple's lookup by the arity (src/intrinsics.jl apply_iterate):
# the world's record where it has one, else the array class; the corpus's runtime_length_tuple cases run it against
# native (test/corpus/runtime_length_tuple_splat.jl)
@testset "a splat into a tuple: its arity's record where the world has one, else the array class" begin
    # the miss: a world with the array class and no record of 7 elements, so the splat's 7-tuple is the array class
    local miss = world_of(SplatCases.miss, (Int64,))
    @test W.TupleRecordArray in miss && Tuple{} in miss && !(W.TupleRecord{7} in miss)
    # the hit: the literal's record is in the world beside the array class
    local hit = world_of(SplatCases.hit, (Int64,))
    @test W.TupleRecord{3} in hit && W.TupleRecordArray in hit
    local cases = WTChild.RunCase[]
    for (f, n) in ((SplatCases.miss, Int64(7)), (SplatCases.miss, Int64(6)), (SplatCases.hit, Int64(3)))
        push!(cases, WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (n,)))
    end
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # a splat into another function rejects at the statement, located
    local e = rejection(() -> W.compile(SplatCases.other, (Int64,); optimize = false))
    @test e !== nothing && occursin("julia/src/builtins.c:661 jl_f__apply_iterate", sprint(showerror, e))
end

# the module a match is loaded into, to show a match missing an arm refuses its load
module ExhaustiveProbe
using WasmTarget: @exhaustive, RecordArity, FixedArity
end

# The record arity is a closed sum (src/julia/classes.jl RecordArity): a record of a fixed arity, or the array class,
# TupleRecordArray, a tuple whose arity only run time knows and no record covers (Julia's type cache's miss, jltypes.c:1133
# lookup_typevalue); every consumer matches it @exhaustive. The array class holds an open tuple type exactly where the
# type admits an arity no record of the closed world covers (dev/formal/TupleRecordSplat.tla IsaAgrees, HoldsOmitsArray).
@testset "the record arity is a closed sum, its array class held where no record covers an arity" begin
    @test W.tuple_record_arity(W.TupleRecord{3}) === W.FixedArity(3) && W.tuple_record_arity(Tuple{}) === W.FixedArity(0)
    @test W.tuple_record_arity(W.TupleRecordArray) === W.RunTimeArity()
    @test W.tuple_record_arity(Tuple{Int64}) === nothing && W.tuple_record_arity(Int64) === nothing
    @test W.record_arities(DataType[W.TupleRecord{2}, Tuple{}, Int64, W.TupleRecordArray, Tuple{Int64}]) == Set([0, 2])
    local covered = Set([0, 2])
    # a Vararg member admits every arity, so always one no record covers
    @test W.open_tuple_holds(Tuple{Vararg{Int64}}, W.TupleRecordArray, covered)
    @test W.open_tuple_holds(Tuple{Int64,Vararg{Int64}}, W.TupleRecordArray, covered)
    @test W.open_tuple_holds(NTuple{N,Int64} where N, W.TupleRecordArray, covered)
    # a fixed open type: the array class exactly where its arity has no record
    @test W.open_tuple_holds(NTuple{7,Any}, W.TupleRecordArray, covered)
    @test !W.open_tuple_holds(NTuple{2,Any}, W.TupleRecordArray, covered)
    @test W.open_tuple_holds(Union{NTuple{2,Any},NTuple{7,Any}}, W.TupleRecordArray, covered)
    @test !W.open_tuple_holds(Union{Tuple{},NTuple{2,Any}}, W.TupleRecordArray, covered)
    # a record of a fixed arity, as before: the arities the type admits
    @test W.open_tuple_holds(Tuple{Vararg{Int64}}, W.TupleRecord{2}, covered) && !W.open_tuple_holds(NTuple{7,Any}, W.TupleRecord{2}, covered)
    @test !W.open_tuple_holds(Tuple{Vararg{Int64}}, Int64, covered)
    # the array class's typeof is its elements' type, made at run time: refused as every record's
    @test W.record_typeof_unmade(W.TupleRecordArray) && W.record_typeof(Tuple{Vararg{Int64}}, W.TupleRecordArray) === nothing
    # its one field, the argument buffer jl_f__apply_iterate fills: a mutable array of top-typed elements
    @test [(f.name, f.type, f.mutable) for f in W.class_instance_fields(W.TupleRecordArray, "tuple_record_array")] == [("data", W.WasmArray{Any}, false)]
    # a match over the sum without the array class's arm, or with a wildcard, refuses its load, located (D8)
    local missing = try
        Core.eval(ExhaustiveProbe, :(missing_arm(r) = @exhaustive r::RecordArity begin
            (x::FixedArity) => x.n
        end))
        nothing
    catch x
        x
    end
    @test missing !== nothing && occursin("the kind RunTimeArity of RecordArity has no arm", sprint(showerror, missing))
    local wildcard = try
        Core.eval(ExhaustiveProbe, :(wildcard_arm(r) = @exhaustive r::RecordArity begin
            (x::FixedArity) => x.n
            _ => 0
        end))
        nothing
    catch x
        x
    end
    @test wildcard !== nothing && occursin("wildcard", sprint(showerror, wildcard))
end

end
