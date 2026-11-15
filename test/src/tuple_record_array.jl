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
# typeof of an Any that holds a tuple at run time: no type of the operand pins the tuple's, so the module ends at the
# fatal gap, its message reported and named, where native answers (and answers as native where the element is no tuple). The Memory{UInt8} it
# compares with is a type constant whose Core.AddrSpace parameter brings that class's constant, without which any typeof
# of an Any refuses on Memory{Any} (type_value_unmade), as the corpus's typeof_either does
mutable struct AnySlot; x::Any; end
@noinline any_slot(n::Int64) = AnySlot(n > 2 ? (n, n) : n)
typeof_of_any(n::Int64) = (t = typeof(any_slot(n).x); t === Int64 ? 1 : t === Memory{UInt8} ? 3 : 2)
# the gap is fatal, never an exception a catch observes: the review's program, whose own try around the typeof answered
# 5 in both modules where native answers 2 while the gap was an exception
@noinline mayfail(n::Int64) = n > 100 ? error("x") : 0
# arity 1 holds two tuple types (Tuple{Int64}, Tuple{Float64}), so the operand pins none: the fatal gap, never 1 or 2
@noinline u3(n::Int64) = n > 5 ? (n,) : n > 2 ? (Float64(n),) : n
c_u3(n::Int64) = typeof(u3(n)) === Tuple{Int64} ? 1 : 2
# a typeof inlined from a helper: the row names the run-time location of the statement
h_typeof(x) = typeof(x)
c_inlined(n::Int64) = (T = h_typeof(any_slot(n).x); T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2)   # Memory{UInt8}: as typeof_of_any
d_trycatch(n::Int64) = (try; T = typeof(any_slot(n).x); w = mayfail(n); (T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2) + w; catch; 5; end)
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
    push!(cases, WTChild.compiled_case("d_trycatch(1)", W.compile, Cases.d_trycatch, (Int64(1),)))
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # a tuple reaching typeof of an Any: the module reports the gap, named at the statement (its method, file and line),
    # and traps, where native answers 2: unported at run time in both modules, never another value; a try around it, the
    # program's own, runs no catch
    @test Cases.typeof_of_any(3) == 2 && Cases.d_trycatch(3) == 2
    @test Cases.c_u3(7) == 1 && Cases.c_inlined(3) == 2
    for (label, f, n) in (("typeof_of_any(3)", Cases.typeof_of_any, 3), ("d_trycatch(3)", Cases.d_trycatch, 3))
        local fatal = only(WTChild.run_cases([WTChild.compiled_case(label, W.compile, f, (Int64(n),))]))
        @test fatal.outcome === :unported
        @test count("typeof of a tuple held as WasmTarget.TupleRecord{2}", fatal.why) == 2
        @test occursin("(at run time, ", fatal.why) && occursin("tuple_record_array.jl:", fatal.why) && occursin(", statement %", fatal.why)
        # the row parses as the climb keys a rejection (dev/climb/core.py:417 UNPORTED_RE = r"unported: the
        # (dart|Julia-only) definition (.*)"), to the hold a compile-time rejection of the same definition names
        local m = match(r"unported: the (dart|Julia-only) definition (.*)", fatal.why)
        @test m !== nothing && m.captures[1] == "Julia-only" && startswith(m.captures[2], "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: ")
    end
    # an operand holding two tuple types of one arity, and a typeof inlined from a helper: unported in both modules
    for (label, f, n) in (("c_u3(7)", Cases.c_u3, 7), ("c_inlined(3)", Cases.c_inlined, 3))
        local fatal = only(WTChild.run_cases([WTChild.compiled_case(label, W.compile, f, (Int64(n),))]))
        @test fatal.outcome === :unported && occursin("(at run time, ", fatal.why)
        local m = match(r"unported: the (dart|Julia-only) definition (.*)", fatal.why)
        @test m !== nothing && startswith(m.captures[2], "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: ")
    end
    # the row, the one text the arm reports
    @test W.record_typeof_message(W.TupleRecord{2}) ==
          "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: typeof of a tuple held as WasmTarget.TupleRecord{2}, whose type, the tuple type of its elements' types, is not made at run time (audit A68S3)"
end

rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

module BoxCases
# a tuple of a concrete type held at the top type is boxed into its arity's record, though the operand's classes list
# the tuple's own class (the review of the typeof move: the record's null table entry trapped in one module, and the
# wasm-opt'd one answered 2, where native answers 1); each record answers the type the operand pins at its arity
@noinline ui(n::Int64) = n > 2 ? (n,) : n
@noinline us(n::Int64) = n > 2 ? (n, n) : "s"
@noinline un2(n::Int64) = n > 5 ? (n,) : n > 2 ? (n, 1.0) : nothing
mutable struct USlot; x::Union{Nothing,Tuple{Int64}}; end
@noinline uslot(n::Int64) = USlot(n > 2 ? (n,) : nothing)
c_ui(n::Int64) = typeof(ui(n)) === Tuple{Int64} ? 1 : 2
c_us(n::Int64) = typeof(us(n)) === Tuple{Int64,Int64} ? 1 : 2
c_un2(n::Int64) = (T = typeof(un2(n)); T === Tuple{Int64} ? 1 : T === Tuple{Int64,Float64} ? 2 : 3)
c_uslot(n::Int64) = typeof(uslot(n).x) === Tuple{Int64} ? 1 : 2
end

@testset "typeof of a tuple boxed at the top: its record's arm, the type the operand pins" begin
    local cases = WTChild.RunCase[]
    for (f, ns) in ((BoxCases.c_ui, (3, 1)), (BoxCases.c_us, (3, 1)), (BoxCases.c_un2, (7, 3, 1)), (BoxCases.c_uslot, (3, 1)))
        for n in ns
            push!(cases, WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (Int64(n),)))
        end
    end
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
end

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
