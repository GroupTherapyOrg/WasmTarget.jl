# A DataType's own field named at run time or by a constant (src/code_generator.jl visitInstanceGet, jl_f_getfield,
# julia/src/builtins.c:1023): the fields its type value's layout holds (`parameters`) read directly, the others from
# their tables by class id (src/julia/classes.jl kind_field_table, formal(dev/formal/KindFieldTable.tla)): `hash`,
# `flags`, `super`, `types` and `instance`, #undef raising UndefRefError as Julia's jl_get_nth_field_checked does.
# Each case's answer is native Julia's, compared in both modules.
module KindFieldTableTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module KindCases
struct Two; a::Int64; b::Float64; end
@noinline _get(@nospecialize(T::DataType), s::Symbol) = getfield(T, s)
@noinline _type(x::Int64)::DataType = x == 1 ? Int64 : x == 2 ? Float64 : x == 3 ? Nothing : Two
# Julia's stored hash (an Int32) of the type x picks, its own value in the compiling process (Base's types keep it in
# every process)
function hash_of(x::Int64)::Int64
    local v = _get(_type(x), x > 0 ? :hash : :flags)
    return v isa Int32 ? Int64(v) : -1
end
function flags_of(x::Int64)::Int64
    local v = _get(_type(x), x > 0 ? :flags : :hash)
    return v isa UInt16 ? Int64(v) : -1
end
# the supertype, compared with Julia's own
function super_of(x::Int64)::Int64
    local s = _get(_type(x), x > 0 ? :super : :name)
    return s === Signed ? 1 : s === AbstractFloat ? 2 : s === Any ? 3 : 4
end
# a singleton's instance (Nothing's is `nothing`); a type that is no singleton's is #undef: UndefRefError
function instance_of(x::Int64)::Int64
    try
        local v = _get(_type(x), x > 0 ? :instance : :name)
        return v === nothing ? 1 : 2
    catch e
        return e isa UndefRefError ? -1 : -2
    end
end
# the field types: Two's two, a primitive type's none
function types_of(x::Int64)::Int64
    local v = _get(_type(x), x > 0 ? :types : :name)
    return v isa Core.SimpleVector ? length(v) * 10 + (length(v) == 2 && v[1] === Int64 ? 1 : 0) : -1
end
# the parameters the type value holds itself
function parameters_of(x::Int64)::Int64
    local v = _get(x > 2 ? Vector{Int64} : _type(x), x > 0 ? :parameters : :name)
    return v isa Core.SimpleVector ? length(v) : -1
end
# the same fields named by a constant, each read on a DataType receiver (as _get takes it): getfield(T, :super), Base's
# supertype, :instance, :hash; the one read, from the same tables by class id
@noinline _super(@nospecialize(T::DataType)) = getfield(T, :super)
@noinline _instance(@nospecialize(T::DataType)) = getfield(T, :instance)
@noinline _hash(@nospecialize(T::DataType)) = getfield(T, :hash)
const_super(x::Int64)::Int64 = (s = _super(_type(x)); s === Signed ? 1 : s === AbstractFloat ? 2 : s === Any ? 3 : 4)
supertype_of(x::Int64)::Int64 = (s = supertype(_type(x)); s === Signed ? 1 : s === AbstractFloat ? 2 : s === Any ? 3 : 4)
const_instance(x::Int64)::Int64 = try; (_instance(_type(x)) === nothing ? 1 : 2); catch e; e isa UndefRefError ? -1 : -2; end
const_hash(x::Int64)::Int64 = (v = _hash(_type(x)); v isa Int32 ? Int64(v) : -1)
end

const KC = KindCases

@testset "a DataType's field named at run time is Julia's, from its table by class id" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((KC.hash_of, (1, 2, 4)), (KC.flags_of, (1, 3, 4)), (KC.super_of, (1, 2, 3)),
                    (KC.instance_of, (1, 3)), (KC.types_of, (1, 4)), (KC.parameters_of, (1, 3)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("kind_field_table/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers that do not depend on the process: the supertypes, the instances, the field types, the parameters
    @test [c.native for c in cases][7:end] == [1, 2, 3, -1, 1, 0, 21, 0, 2]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

@testset "a DataType's field named by a constant is read from the same table by class id" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((KC.const_super, (1, 2, 4)), (KC.supertype_of, (1, 2, 3)), (KC.const_instance, (1, 3)), (KC.const_hash, (1, 2)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("kind_field_table/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers that do not depend on the process: the supertypes and the instances
    @test [c.native for c in cases][1:8] == [1, 2, 3, 1, 2, 3, -1, 1]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
