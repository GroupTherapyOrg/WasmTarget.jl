# A DataType's field read from its table by class id (src/code_generator.jl visitInstanceGet, src/julia/classes.jl
# kind_field_table) where the table holds no value: `name` (a TypeName, which no class of the closed world holds),
# `layout` (a host address) and an entry whose state is GAP (a field type no constant of the closed world holds). Each
# is a gap WasmTarget defers to run time: the read reports it, named and located at its statement, and traps, in both
# modules (the fatal arm, src/intrinsics.jl), where native answers. Read by a name only run time knows.
module KindFieldGapsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const W = WasmTarget

module GapCases
# a field type whose type value no constant of the closed world holds, so the `types` entry is GAP: a Type{X} (no
# value's typeof is one) and a UnionAll (Vector)
struct HoldsType; t::Type{Int128}; end
struct HoldsUnionAll; v::Vector; end
@noinline _get(@nospecialize(T::DataType), s::Symbol) = getfield(T, s)
@noinline _type(x::Int64)::DataType = x == 1 ? Int64 : x == 3 ? HoldsType : HoldsUnionAll
name_of(x::Int64)::Int64 = (v = _get(_type(x), x > 0 ? :name : :hash); v isa Core.TypeName ? 1 : 2)
layout_of(x::Int64)::Int64 = (v = _get(_type(x), x > 0 ? :layout : :hash); v isa Ptr{Nothing} ? 1 : 2)
types_of(x::Int64)::Int64 = (v = _get(_type(x), x > 0 ? :types : :hash); v isa Core.SimpleVector ? length(v) : -1)
end

const GC = GapCases

@testset "a DataType field its table holds no value of ends at the fatal arm, named and located" begin
    # native's answers
    @test GC.name_of(1) == 1 && GC.layout_of(1) == 1 && GC.types_of(3) == 1 && GC.types_of(4) == 1
    for (label, f, n, gap) in (("name_of(1)", GC.name_of, 1, "julia/src/julia.h jl_typename_t: a DataType's name, a TypeName"),
                               ("layout_of(1)", GC.layout_of, 1, "julia/src/julia.h:611 jl_datatype_t.layout: a host address"),
                               ("types_of(3)", GC.types_of, 3, "julia/src/julia.h:605 jl_datatype_t.types of a type whose value there no constant of the closed world holds"),
                               ("types_of(4)", GC.types_of, 4, "julia/src/julia.h:605 jl_datatype_t.types of a type whose value there no constant of the closed world holds"))
        local fatal = only(WTChild.run_cases([WTChild.compiled_case("kind_field_gaps/$label", W.compile, f, (Int64(n),))]))
        @test fatal.outcome === :unported || (@info label fatal.outcome fatal.why; false)
        # both modules report it, at the statement: its method, file and line
        @test count(gap, fatal.why) == 2 || (@info label fatal.why; false)
        @test occursin("(at run time, ", fatal.why) && occursin("kind_field_gaps.jl:", fatal.why) && occursin(", statement %", fatal.why)
    end
end

end # module
