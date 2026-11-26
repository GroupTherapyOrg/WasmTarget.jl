# Core's UnionAll(v, t) in a module: Julia's inliner makes it the foreign call jl_type_unionall
# (Compiler/src/ssair/inlining.jl:1745), which the code generator lowers to the runtime's port
# (src/julia/runtime/rtutils.jl jl_type_unionall, julia/src/jltypes.c:907): each arm is Julia's own, read against
# native, the body only run time knows (taken from an Any vector). The arm that makes a new UnionAll allocates it
# (jl_new_unionall), its fields read back, and its `===` is Julia's structural egal_types (julia/src/builtins.c:167,
# jl_egal_unionall): up to renaming of the variable, its name kept, two DataTypes of one TypeName compared by their
# parameters. The walk jl_has_typevar asks (dev/formal/HasBoundTypevars.tla) meets a type variable, a DataType's
# parameters, a Union's members and a UnionAll's bounds and body.
module JlTypesTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module JlTypesCases
const TV = TypeVar(:T)
const TV_S = TypeVar(:S, Integer)
const TV_W = TypeVar(:W)
@noinline ua(v::TypeVar, @nospecialize(b)) = UnionAll(v, b)
# k selects the body: S itself (`S where S<:Integer` is Integer), then bodies in which T does not occur (Int64; a
# Union; a tuple type holding a Union, its parameters walked; another type variable; Vector, a UnionAll binding its
# own T, its bounds and body walked), then a value that is no type (Julia's TypeError, its fields read)
function arms(k::Int64)::Int64
    local b = Any[TV_S, Int64, Union{Int64,Nothing}, Tuple{Int64,Union{Int8,Nothing}}, TV_W, Vector, 5][k]
    local v = k == 1 ? TV_S : TV
    try
        local r = ua(v, b)
        return r === Integer ? 1 : r === b ? 2 : 3
    catch e
        e isa TypeError || return 5
        return 4 + 10 * Int64(e.func === :UnionAll) + 100 * Int64(e.expected === Type) + 1000 * Int64(e.got === 5)
    end
end
# Vector's own variable over its own body: a body that mentions the variable, Julia's new UnionAll, egal to Vector
function rewrapped(k::Int64)::Int64
    local t = Any[Vector, Int64][k]
    t isa UnionAll || return 0
    return ua(t.var, t.body) === Vector ? 1 : 2
end
# the new UnionAll's parts, its kind and its fields (each body taken from an Any vector: a type literal with a free
# variable as an operand of === is makeType's own gap, src/types.jl)
function made_parts(k::Int64)::Int64
    local b = Any[Vector{TV}, Int64][k]
    local u = ua(TV, b)
    u isa UnionAll || return 0
    return Int64(u.var === TV) + 2 * Int64(u.body === b) + 4 * Int64(typeof(u) === UnionAll)
end
# two new UnionAlls over distinct variables: egal where the variables' names agree (renaming, the bodies two
# DataTypes of one TypeName whose parameters are the paired variables), not where they differ
const TV_T2 = TypeVar(:T)
const TV_U = TypeVar(:U)
function made_egal(k::Int64)::Int64
    local w = Any[TV_T2, TV_U, TV][k]::TypeVar
    local bodies = Any[Vector{TV}, Vector{TV_T2}, Vector{TV_U}]
    local a = ua(TV, bodies[1])
    local b = ua(w, bodies[Int64[2, 3, 1][k]])
    return Int64(a === b) + 2 * Int64(a === Vector) + 4 * Int64(b === Vector)
end
end

const JC = JlTypesCases

@testset "UnionAll(v, t) is jl_type_unionall's answer" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(JC.arms, (Int64(1),))
    local cases = [Main.WTChild.RunCase("jltypes/arms$k", plain, (Int64(k),), Main.WTChild.native_answer(JC.arms, (Int64(k),)); optimized = opt) for k in 1:7]
    @test [c.native for c in cases] == [1, 2, 2, 2, 2, 2, 1114]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # the new object: a UnionAll egal to Vector, its parts, and egal by renaming
    local made = Main.WTChild.RunCase[]
    for (f, ks) in ((JC.rewrapped, 1:2), (JC.made_parts, 1:2), (JC.made_egal, 1:3))
        local (p, o) = both(f, (Int64(1),))
        append!(made, [Main.WTChild.RunCase("jltypes/$(nameof(f))$k", p, (Int64(k),), Main.WTChild.native_answer(f, (Int64(k),)); optimized = o) for k in ks])
    end
    # natively: Vector rewrapped is Vector; renaming keeps egal where the names agree (made_egal 7, 2, 7)
    @test [c.native for c in made][[1, 2, 5, 6, 7]] == [1, 0, 7, 2, 7]
    for r in Main.WTChild.run_cases(made)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
