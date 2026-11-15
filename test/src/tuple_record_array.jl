# A tuple held where its static type is open is its arity's record (src/julia/classes.jl TupleRecord), dart's record
# class of a shape: a class of the closed world, never Julia's type of the tuple. Julia's typeof of a tuple is the tuple
# type of its elements' types (julia/src/builtins.c:946 jl_f_tuple), found in its type cache or made. typeof of a value
# that may be a record answers the record by its own arm (src/intrinsics.jl to_typeof): the one tuple type the operand's
# inferred type holds at the record's arity (src/julia/classes.jl record_typeof), else the world's tuple type of its
# fields' typeofs (src/intrinsics.jl tuple_type_lookup, Julia's cache lookup), else the fatal gap naming the statement,
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
# typeof of an Any that holds a tuple at run time: no type of the operand pins the tuple's, so the record's arm looks it
# up from its fields' typeofs among the world's tuple types (here Tuple{Int64,Int64}, which the program builds). The
# Memory{UInt8} it compares with is a type constant whose Core.AddrSpace parameter brings that class's constant, without
# which any typeof of an Any refuses on Memory{Any} (type_value_unmade), as the corpus's typeof_either does
mutable struct AnySlot; x::Any; end
@noinline any_slot(n::Int64) = AnySlot(n > 2 ? (n, n) : n)
typeof_of_any(n::Int64) = (t = typeof(any_slot(n).x); t === Int64 ? 1 : t === Memory{UInt8} ? 3 : 2)
# the review's program, whose own try around the typeof answered 5 in both modules while the gap was an exception; its
# typeof is answered now, and the catch never runs
@noinline mayfail(n::Int64) = n > 100 ? error("x") : 0
# arity 1 holds two tuple types (Tuple{Int64}, Tuple{Float64}), so the operand pins none: each answered by the lookup
@noinline u3(n::Int64) = n > 5 ? (n,) : n > 2 ? (Float64(n),) : n
c_u3(n::Int64) = typeof(u3(n)) === Tuple{Int64} ? 1 : 2
# a typeof inlined from a helper
h_typeof(x) = typeof(x)
c_inlined(n::Int64) = (T = h_typeof(any_slot(n).x); T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2)   # Memory{UInt8}: as typeof_of_any
d_trycatch(n::Int64) = (try; T = typeof(any_slot(n).x); w = mayfail(n); (T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2) + w; catch; 5; end)
# the lookup of each tuple an Any holds: elements of two classes, a nested tuple (its own record, looked up the same
# way), the empty tuple (Tuple{}'s own entry), elements that are a type value and nothing (Tuple{DataType,Nothing})
@noinline any_tuple(n::Int64) = AnySlot(n == 1 ? (n, 2.0) : n == 2 ? ((n,), n) : n == 3 ? () : n == 4 ? (Int64, nothing) : n)
typeof_any_tuple(n::Int64) = (T = typeof(any_tuple(n).x); T === Tuple{Int64,Float64} ? 1 : T === Tuple{Tuple{Int64},Int64} ? 2 :
                                  T === Tuple{} ? 3 : T === Tuple{DataType,Nothing} ? 4 : T === Memory{UInt8} ? 6 : 5)
# two tuples of one arity and different element types: their types are two canonical constants, === by reference
@noinline any_pair(k::Int64) = AnySlot(k > 3 ? (k, k) : (k, 1.0))
same_type(n::Int64) = (a = any_pair(n).x; b = any_pair(n + 3).x; typeof(a) === typeof(b) ? 1 : typeof(a) === Memory{UInt8} ? 3 : 2)
# a tuple whose type the program never names: a splat of a Vector{Any} holding n and "s" (filled by index, so no
# varargs call names Tuple{Int64,String}) is the record of 2 elements (the world has it, from any_pair's 2-tuples), its
# fields an Int64 and a String, and the world holds no Tuple{Int64,String}: Julia would make the type, so the module
# ends at the fatal gap, named at the statement
@noinline mk_any(v::Vector{Any}) = Core.tuple(v...)
@noinline function int_and_string(n::Int64)
    local v = Vector{Any}(undef, 2)
    v[1] = n
    v[2] = "s"
    return v
end
never_named(n::Int64) = (s = AnySlot(n > 0 ? mk_any(int_and_string(n)) : any_pair(n).x); T = typeof(s.x); T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2)
# a tuple of the array class, whose arity only run time knows (no record of 7 elements in this world): no row is its type
@noinline mk_int(v::Vector{Int64}) = Core.tuple(v...)
@noinline splat_held(n::Int64) = AnySlot(mk_int(collect(1:n)))
array_typeof(n::Int64) = (s = splat_held(n); T = typeof(s.x); T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2)
# the same tuple where Julia forwards the field, so typeof's operand is a Tuple{Vararg{Int64}}: it pins NTuple{k,Int64}
# at each record of k elements, a type the table holds no entry of where the program builds no such tuple, so the arm
# looks it up as an unpinned one (it compiled to a rejection of that type's constant before); the array class's arm is
# the fatal gap
array_forwarded(n::Int64) = (s = AnySlot(mk_int(collect(1:n))); T = typeof(s.x); T === Int64 ? 1 : T === Memory{UInt8} ? 3 : 2)
# a Memory as a tuple's element: its class's own entry (Memory{UInt8}, whose type constant the program names)
@noinline mem_pair(n::Int64) = AnySlot(n > 0 ? (Memory{UInt8}(undef, 1), n) : n)
mem_elem(n::Int64) = (T = typeof(mem_pair(n).x); T === Tuple{Memory{UInt8},Int64} ? 1 : T === Int64 ? 2 : T === Memory{UInt8} ? 3 : 4)
# a forwarded Tuple{Vararg{Int64}} operand in a world where Tuple{Int64,Int64} is a row for another reason (any_pair's
# (k, k)): the record of 2 answers exactly Tuple{Int64,Int64}
o_vararg(n::Int64) = (w = any_pair(n + 3); s = AnySlot(mk_int(collect(1:n))); T = typeof(s.x);
                      (T === Tuple{Int64,Int64} ? 1 : T === Tuple{Int64,Float64} ? 2 : T === Memory{UInt8} ? 3 : 4) + 10 * (w.x::Tuple{Int64,Int64})[1])
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
    # a tuple reaching typeof of an Any, and the review's try around it: answered from the tuple's fields, 2 as native,
    # the catch never run (5 would be its answer); an operand holding two tuple types of one arity, and a typeof inlined
    # from a helper, answered as native
    @test Cases.typeof_of_any(3) == 2 && Cases.d_trycatch(3) == 2
    @test Cases.c_u3(7) == 1 && Cases.c_u3(3) == 2 && Cases.c_inlined(3) == 2
    for (label, f, n) in (("typeof_of_any(3)", Cases.typeof_of_any, 3), ("d_trycatch(3)", Cases.d_trycatch, 3),
                          ("c_u3(7)", Cases.c_u3, 7), ("c_u3(3)", Cases.c_u3, 3), ("c_inlined(3)", Cases.c_inlined, 3))
        push!(cases, WTChild.compiled_case(label, W.compile, f, (Int64(n),)))
    end
    # each tuple an Any holds, by its type: elements of two classes, a nested tuple, the empty tuple, a type value and
    # nothing; and two tuples of one arity compared by their types
    @test [Cases.typeof_any_tuple(n) for n in 1:5] == [1, 2, 3, 4, 5] && Cases.same_type(1) == 2 && Cases.same_type(4) == 1
    for n in 1:5
        push!(cases, WTChild.compiled_case("typeof_any_tuple($n)", W.compile, Cases.typeof_any_tuple, (Int64(n),)))
    end
    for n in (1, 4)
        push!(cases, WTChild.compiled_case("same_type($n)", W.compile, Cases.same_type, (Int64(n),)))
    end
    # a Memory element, and the forwarded operand answering exactly Tuple{Int64,Int64}
    @test Cases.mem_elem(1) == 1 && Cases.o_vararg(2) == 51
    push!(cases, WTChild.compiled_case("mem_elem(1)", W.compile, Cases.mem_elem, (Int64(1),)))
    push!(cases, WTChild.compiled_case("o_vararg(2)", W.compile, Cases.o_vararg, (Int64(2),)))
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # a tuple whose type the program never names (a record whose fields' types are no row of the world), and a tuple of
    # the array class: the module reports the gap, named at the statement (its method, file and line), and traps, where
    # native answers 2: unported at run time in both modules, never another value
    @test Cases.never_named(1) == 2 && Cases.array_typeof(7) == 2 && Cases.array_forwarded(7) == 2
    for (label, f, n, record) in (("never_named(1)", Cases.never_named, 1, "WasmTarget.TupleRecord{2}"),
                                  ("array_typeof(7)", Cases.array_typeof, 7, "WasmTarget.TupleRecord{WasmTarget.RunTimeArity()}"),
                                  ("array_forwarded(7)", Cases.array_forwarded, 7, "WasmTarget.TupleRecord{WasmTarget.RunTimeArity()}"))
        local fatal = only(WTChild.run_cases([WTChild.compiled_case(label, W.compile, f, (Int64(n),))]))
        @test fatal.outcome === :unported
        @test count("typeof of a tuple held as $record", fatal.why) == 2
        @test occursin("(at run time, ", fatal.why) && occursin("tuple_record_array.jl:", fatal.why) && occursin(", statement %", fatal.why)
        # the row parses as the climb keys a rejection (dev/climb/core.py:417 UNPORTED_RE = r"unported: the
        # (dart|Julia-only) definition (.*)"), to the hold a compile-time rejection of the same definition names
        local m = match(r"unported: the (dart|Julia-only) definition (.*)", fatal.why)
        @test m !== nothing && m.captures[1] == "Julia-only" && startswith(m.captures[2], "julia/src/jltypes.c:2477 jl_inst_arg_tuple_type: ")
    end
    # the rows of the lookup: the world's concrete tuple types of the arity among the table's entries, in its order; a
    # Type{X} element, or one the table holds no entry of, is the type of no tuple of the world
    local entries = Union{Nothing,DataType}[nothing, Int64, Tuple{Int64,Int64}, Float64, Tuple{Int64,Float64}, Tuple{Int64},
                                            Tuple{Type{Int64},Int64}, Tuple{Int64,String}, DataType, Tuple{DataType,Int64}, nothing]
    @test W.tuple_type_rows(entries, 2) == [Tuple{Int64,Int64}, Tuple{Int64,Float64}, Tuple{DataType,Int64}]
    @test W.tuple_type_rows(entries, 1) == [Tuple{Int64}] && isempty(W.tuple_type_rows(entries, 3))
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
