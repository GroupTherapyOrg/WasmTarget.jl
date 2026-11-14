# src/julia/show.jl: Julia's text of a MethodInstance, a type and a module (julia_text), Base's own text for Julia's
# own objects, and for a program defined after the compiler's world a text built with no read of the program's
# bindings, so compiling it from the earlier world reads none (Julia 1.12's backdate admonition is the witness).
using Test
using WasmTarget

module JTCases
struct P; x::Int64; end
g(p::P) = p.x + 1
@noinline h(f, x) = f(x)
f(x::Int64) = h(g, P(x))
end

@testset "julia_text: Base's text of Julia's own types and methods" begin
    local W = WasmTarget
    for T in Any[Int64, Vector{Float64}, Matrix{Int64}, Union{Nothing,Int64}, Dict{String,Int64}, Tuple{Int64,Vararg{Int64}},
                 NTuple{5,Int64}, Tuple{}, @NamedTuple{a::Int64, b::Float64}, AbstractVector{<:Real}, Union{}, typeof(+),
                 Type{Int64}, Base.RefValue{Int64}, Pair{Int64,String}, Vector{T} where T<:Integer, Core.SimpleVector,
                 Union{Int64,String,Vector{Int64}}, typeof(Base.unsafe_getindex), Base.Iterators.Rest{String,Int64},
                 GenericMemory{:not_atomic, Int64, Core.AddrSpace{Core}(0x00)}, Val{3}, Val{:a}, UnionAll, DataType]
        @test W.julia_text(T) == string(T)
    end
    for (f, sig) in ((+, (Int64, Int64)), (getindex, (Vector{Float64}, Int64)), (Base.unsafe_getindex, (Vector{Int64}, Int64)),
                     (sum, (Vector{Int64},)), (string, (Int64,)))
        local mi = Base.method_instance(f, sig)
        @test W.julia_text(mi) == string(mi)
    end
    @test W.julia_text(Base.Iterators) == string(Base.Iterators) && W.julia_text(Main) == "Main"
    @test W.julia_text(:sym) == "sym" && W.julia_text(3) == "3"
end

@testset "julia_text: a program's text reads none of its bindings, so its compile at an earlier world reads none" begin
    local W = WasmTarget
    # the program's own function as a type: its type's name (the judge's world has its binding only backdated, which
    # Julia's isconst does not count), its call qualified by its module, as Base prints them at that world
    @test W.julia_text(typeof(JTCases.g)) == "Main.JTCases.var\"#g\""
    @test W.julia_text(Base.method_instance(JTCases.h, (typeof(JTCases.g), JTCases.P))) ==
          "MethodInstance for Main.JTCases.h(::Main.JTCases.var\"#g\", ::Main.JTCases.P)"
    # a program defined after the world the compiler runs at, compiled from that world (test/smoke.jl's judge):
    # Julia 1.12 prints its admonition for a read of a binding before its definition world; none is printed
    local w0 = Base.get_world_counter()
    local m = Core.eval(@__MODULE__, :(module JTLater
        struct Q; x::Int64; end
        k(q::Q) = q.x * 2
        @noinline call(f, x) = f(x)
        run(x::Int64) = call(k, Q(x))
    end))
    # (the function read where it is defined: this block's own world precedes the module)
    local run = Base.invokelatest(getfield, m, :run)
    local log = tempname()
    local bytes = open(log, "w") do io
        redirect_stderr(io) do
            Base.invoke_in_world(w0, W.compile, run, (Int64,); world = Base.get_world_counter())
        end
    end
    @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    @test !occursin("definition world", read(log, String))
    rm(log; force = true)
end
