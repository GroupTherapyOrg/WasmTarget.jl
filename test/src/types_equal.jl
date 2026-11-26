# Base's `==` of two types (julia/base/operators.jl:295), libjulia's jl_types_equal (julia/src/subtype.c:2353), in a
# module: split at compile time over the keys the operands can hold (src/julia/classes.jl types_equal_cache), each key
# answered by Julia's own jl_types_equal, an operand typed DataType keyed by its remainder where Julia's
# obviously_unequal answers by identity (subtype.c:436), run by the bool_cases arm (src/intrinsics.jl). The model:
# dev/formal/TypesEqualSplit.tla (Total, Agrees). Julia's equality is no identity: two distinct types can be equal.
# The walk of the program's type values (check_run_time_type_values) meets the Dict's #undef key slots.
module TypesEqualTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module TypesEqualCases
struct TeA end
struct TeC{T} end
const TE_DICT = Dict{DataType,Int64}(TeA => 1, Function => 2, TeC{Int64} => 3)
# narrow operands: Type{Union{Nothing,Int64}}, whose values are every type equal to the union (no unique
# representation, Compiler/src/typeutils.jl:12 hasuniquerep), each its call's one member, answered by Julia's
# jl_types_equal at compile time; te_eq is specialized per Type{X} at each split call
@noinline te_eq(a::Type{A}, b::Type{B}) where {A,B} = a == b
function narrow(x::Int64)::Int64
    local a = x == 1 ? Union{Nothing,Int64} : Int64
    local b = x == 2 ? Int64 : Union{Int64,Nothing}
    return Int64(te_eq(a, b)) + 2 * Int64(te_eq(a, Int64)) + 4 * Int64(te_eq(Union{Nothing,Int64}, b))
end
# an operand typed DataType against a literal of the identity premise: a struct, a parametric struct's instance,
# an abstract type of no parameter, each compared with a DataType read from a constant Vector; and a Dict
# constant read, whose key slots the walk of the program's type values meets, most of them #undef
const TE_KEYS = DataType[TeA, Function, TeC{Int64}]
function wide(x::Int64)::Int64
    local n = 0
    for i in 1:length(TE_KEYS)
        local k = TE_KEYS[i]
        n += i * (Int64(k == TeA) + 10 * Int64(k == Int64) + 100 * Int64(Function == k))
    end
    return n + 1000 * Int64(TE_KEYS[x] == TeC{Int64}) + 10000 * length(TE_DICT)
end
# two operands typed DataType, no key splits them: the run-time port, by identity and the identity premise (read
# from a vector: two type values an argument's split would fold to constants, Julia's concrete evaluation)
both(x::Int64)::Int64 = Int64(TE_KEYS[x] == TE_KEYS[x + 1]) + 2 * Int64(TE_KEYS[x] == TE_KEYS[x])
# a literal tuple type, of no premise, against an operand typed DataType whose values have it
tuple_wide(x::Int64)::Int64 = Int64(Tuple{Int64} == TE_KEYS[x])
# a Dict keyed by DataTypes looked up by one read from a vector, Base's ht_keyindex comparing keys by ==
dict_get(x::Int64)::Int64 = TE_DICT[TE_KEYS[x]]
# two distinct tuple types, neither of the premise: Julia answers by subtyping, the run-time port's fatal gap
const TE_TUPLES = DataType[Tuple{Int64}, Tuple{Int8}]
tuple_gap(x::Int64)::Int64 = Int64(TE_TUPLES[x] == TE_TUPLES[3 - x])
end

const TC = TypesEqualCases

@testset "Base's == of two types is Julia's jl_types_equal" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (np, no) = both(TC.narrow, (Int64(1),))
    local cases = [Main.WTChild.RunCase("types_equal/narrow($x)", np, (x,), Main.WTChild.native_answer(TC.narrow, (x,)); optimized = no) for x in Int64.(1:3)]
    # native: the union equal to itself, Int64 to Int64, Int64 against the union unequal
    @test [c.native for c in cases] == [5, 3, 6]
    local (wp, wo) = both(TC.wide, (Int64(1),))
    for x in (Int64(1), Int64(3))
        push!(cases, Main.WTChild.RunCase("types_equal/wide($x)", wp, (x,), Main.WTChild.native_answer(TC.wide, (x,)); optimized = wo))
    end
    @test [c.native for c in cases[end-1:end]] == [30201, 31201]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # the run-time port: identity and the identity premise, against native
    local rt = Main.WTChild.RunCase[]
    for (f, xs) in ((TC.both, 1:2), (TC.tuple_wide, 1:3), (TC.dict_get, 1:3))
        local (p, o) = both(f, (Int64(1),))
        append!(rt, [Main.WTChild.RunCase("types_equal/$(nameof(f))($x)", p, (x,), Main.WTChild.native_answer(f, (x,)); optimized = o) for x in Int64.(xs)])
    end
    @test [c.native for c in rt] == [2, 2, 0, 0, 0, 1, 2, 3]
    for r in Main.WTChild.run_cases(rt)
        @test r.ok || (@info r.label r.why; false)
    end
    # two distinct tuple types: the fatal gap, named, read as unported
    local g = only(Main.WTChild.run_cases([Main.WTChild.compiled_case("types_equal/tuple_gap", WasmTarget.compile, TC.tuple_gap, (Int64(1),))]))
    @test g.outcome === :unported
end

end # module
