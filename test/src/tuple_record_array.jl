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

end
