# x isa T for an open tuple type T and a tuple held in its record (a tuple of an open static type, built by a
# splat), through an operand typed Any: Julia's isa tests each element (julia/src/subtype.c:1348 subtype_tuple, the
# length first, then each field). Where the record member tests cannot serve T (an element type its value's class
# does not tell, Type{Int}), the test must still read the elements, never the record's class alone, or reject, located.
# Each case's answer is native Julia's, compared in both modules.
module OpenTupleIsaTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module IsaCases
# a tuple of run-time arity, held in its record (TupleRecord{n}, or the array class past the covered arities)
@noinline splat(v::Vector{Int})::Any = (v...,)
@noinline splat_mixed(n::Int)::Any = n > 0 ? ((Any[1, "a"])...,) : ((Any[1, 2.0])...,)
@noinline splat_types(n::Int)::Any = ((Any[Int for _ in 1:n])...,)
# the record member tests cannot serve an element type Type{Int}: the record's class alone does not tell it
types_isa(n::Int)::Int = splat(collect(1:n)) isa Tuple{Vararg{Type{Int}}} ? 1 : 0
types_isa_of_types(n::Int)::Int = splat_types(n) isa Tuple{Vararg{Type{Int}}} ? 1 : 0
# controls, which the record member tests serve: Ints against Int, mixed elements against Int
ints_isa(n::Int)::Int = splat(collect(1:n)) isa Tuple{Vararg{Int}} ? 1 : 0
mixed_isa(n::Int)::Int = splat_mixed(n) isa Tuple{Vararg{Int}} ? 1 : 0
mixed_isa_head(n::Int)::Int = splat_mixed(n) isa Tuple{Int, Vararg{Int}} ? 1 : 0
end

const IC = IsaCases

@testset "x isa an open tuple type tests a record's elements, as Julia's subtype_tuple, or rejects, located" begin
    local cases = Main.WTChild.RunCase[]
    local rejected = Symbol[]
    for (f, xs) in ((IC.types_isa, (0, 1, 2, 3)), (IC.types_isa_of_types, (0, 1, 2)), (IC.ints_isa, (0, 2, 3)),
                    (IC.mixed_isa, (1, -1)), (IC.mixed_isa_head, (1, -1)))
        # the test of a record against Tuple{Vararg{Type{Int}}} is the runtime's subtype test, which a Vararg tuple
        # type's run-time length leaves a gap (src/julia/runtime/rtutils.jl run_time_type_gap): a rejection, located,
        # never the class table's answer
        local mods = try
            Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        catch e
            e isa WasmTarget.RejectionError || rethrow()
            @test e.rejection isa WasmTarget.Unquarantined && occursin("Tuple{Vararg{Type{Int64}}}", sprint(showerror, e))
            push!(rejected, nameof(f))
            continue
        end
        for x in xs
            push!(cases, Main.WTChild.RunCase("open_tuple_isa/$(nameof(f))($x)", mods[1], (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = mods[2]))
        end
    end
    # only the Type{Int} tests may reject; the member tests serve the rest
    @test issubset(rejected, [:types_isa, :types_isa_of_types])
    # native's answers: a tuple's isa reads its type, its elements' types (Int's is DataType): Tuple{Vararg{Type{Int}}}
    # holds the empty tuple alone; Ints are Ints
    @test [IC.types_isa(x) for x in 0:3] == [1, 0, 0, 0] && [IC.types_isa_of_types(x) for x in 0:2] == [1, 0, 0]
    @test [c.native for c in cases if startswith(c.label, "open_tuple_isa/ints") || startswith(c.label, "open_tuple_isa/mixed")] == [1, 1, 1, 0, 0, 0, 0]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
