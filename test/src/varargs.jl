# A varargs method's trailing arguments reach its body as one tuple (src/julia/nir.jl NirVarargPacking),
# its type Julia's own, Core.Compiler.va_process_argtypes: a specialization of a fixed count takes each
# argument as a parameter and packs them at entry (Julia's specsig, codegen.cpp's emit_new_struct); one
# of an open count takes the tuple as one parameter, which the call packs from its operands (Julia's
# jl_f_tuple over the argument array, moved to the caller, a wasm function's arity being fixed), and
# its body reads it by nfields and a position over the tuple's run-time class.

module VarargsTest

using Test
using WasmTarget

const W = WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTRunner = Main.WTRunner

module Cases
# Julia leaves a varargs call's count open unless the method names it (Vararg{T,N} where N)
@noinline g(a::Int, xs::Int...) = a + length(xs) + xs[1]
@noinline gn(a::Int, xs::Vararg{Int,N}) where {N} = a + N + xs[1] * xs[2]
h(x::Int) = g(x, 2, 3) + gn(x, 2, 3)
# a fixed count: gn's tail packed at its entry into the Tuple{Int,Int} its body reads
fixed(x::Int) = gn(x, x + 1, 3)
# an open count: g's tail packed by the call into the Tuple{Int,Int} passed as its one parameter
open_count(x::Int) = g(x, 2, 3)
cat3(a::String, b::String, c::String) = string(a, b, c)
# string(a, b, c) read back as numbers: its length and its bytes at both ends
function cat3_read(n::Int64)::Int64
    local s = cat3(n > 0 ? "x" : "yy", "-", n > 1 ? "zzzé" : "w")
    return Int64(ncodeunits(s)) * 1_000_000 + Int64(codeunit(s, 1)) * 1000 + Int64(codeunit(s, ncodeunits(s)))
end
end

world_of(f, at) = W.build_nir(W.check_subset(f, at, "varargs"), "varargs")
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

@testset "varargs: Julia's packing of a varargs method's trailing arguments" begin
    # a specialization of a fixed count (gn names its count): each argument its own parameter, packed at entry
    local hw = world_of(Cases.h, (Int,))
    local gn = only(b.ci.def for b in hw if b.ci.def.def.name === :gn)
    local gp = W.nir_vararg_packing(gn)
    @test gp.first == 3 && gp.packed === Tuple{Int,Int} && gp.at_entry
    @test W.nir_parameter_types(gn) == Type[typeof(Cases.gn), Int, Int, Int]
    @test W.nir_argument_type(gn, W.NirArgument(3)) === Tuple{Int,Int} && W.nir_method_nargs(gn) == 3
    # g leaves its count open: its trailing arguments one packed parameter, Julia's tuple type
    local g = only(b.ci.def for b in hw if b.ci.def.def.name === :g)
    local gt = W.nir_parameter_types(g)
    @test length(gt) == 3 && gt[2] === Int && Base.isvatuple(gt[3]) && !W.nir_vararg_packing(g).at_entry
    # string(a, b, c) calls Base._string of an open count: the packed parameter Julia's own tuple type
    local cw = world_of(Cases.cat3, (String, String, String))
    local open = [b.ci.def for b in cw if (local p = W.nir_vararg_packing(b.ci.def); p !== nothing && !p.at_entry)]
    @test !isempty(open)
    for mi in open
        local m = mi.def::Method
        local p = W.nir_vararg_packing(mi)
        local julia = Core.Compiler.widenconst(Core.Compiler.va_process_argtypes(Core.Compiler.fallback_lattice,
            Core.Compiler.most_general_argtypes(m, mi.specTypes), UInt(m.nargs), true)[m.nargs])
        @test p.first == m.nargs && p.packed === julia
        @test last(W.nir_parameter_types(mi)) === julia && length(W.nir_parameter_types(mi)) == m.nargs
    end
    # a method with no varargs packs nothing
    @test W.nir_vararg_packing(only(b.ci.def for b in hw if b.ci.def.def.name === :h)) === nothing
end

@testset "varargs: a fixed count packs at entry and answers as native Julia" begin
    local f = Cases.fixed
    local bytes = W.compile(f, (Int,))
    for r in WTRunner.run_cases([WTRunner.RunCase("fixed$(a)", bytes, a, f(a...)) for a in [(1,), (0,), (-7,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end

@testset "varargs: an open count packs at the call and its body reads the tuple, answering as native Julia" begin
    # the call packs the operands' concrete tuple; the body reads the abstract Tuple{Vararg{Int}} by
    # nfields and a position, each a class-id switch over the closed world's tuple classes below it,
    # as Julia's codegen reads the value's own type (emit_datatype_nfields, emit_bounds_check)
    for (f, args) in ((Cases.open_count, [(1,), (0,), (-9,)]), (Cases.cat3_read, [(Int64(0),), (Int64(1),), (Int64(2),)]))
        local bytes = W.compile(f, (Int64,))
        for r in WTRunner.run_cases([WTRunner.RunCase("$(nameof(f))$(a)", bytes, a, f(a...)) for a in args])
            @test r.ok || (@info r.label r.why; false)
        end
    end
end

# an open count's tuple whose elements' classes only run time knows (A70S3): InexactError(::Symbol, ::Any,
# ::Vararg{Any}) packs Tuple{Type, UInt64}, which Julia's codegen types by its values at run time
# (jl_f_tuple); the call switches on each open element's class among the closed world's tuple classes
# below it (tuple_classes), each checked conversion that can raise now compiling; past Julia's
# max_union_splitting the classes reject, located
module OpenTupleCases
const KEYS = ["k$i" for i in 1:4]
const ANYS = Any[1, "s"]
function open_tuple(k::Int64, n::Int64)
    k == 1 && return UInt(n) % Int64                                    # InexactError for n < 0
    k == 2 && return Int64(UInt8(n))                                    # InexactError past 255
    k == 3 && return (hash(KEYS[1], UInt(n)) % UInt(1000003)) % Int64   # a String hash under UInt(n)
    local d = Dict{Int64,Int64}()
    for i in 1:n; d[i] = Int64(UInt16(i)); end
    return length(d)
end
over(n::Int64) = throw(InexactError(:over, Int64, ANYS[n]))
end
@testset "varargs: a tuple of open elements packs as jl_f_tuple, by its elements' classes, within max_union_splitting" begin
    local f = OpenTupleCases.open_tuple
    local bytes = W.compile(f, (Int64, Int64); optimize = false)
    local argsets = [(1, 5), (1, -1), (2, 7), (2, 300), (3, 2), (3, -3), (4, 10)]
    local cases = [WTRunner.RunCase("open_tuple$(a)", bytes, Int64.(a), WTRunner.native_answer(f, Int64.(a))) for a in argsets]
    @test count(c -> c.native == WTRunner.Throws(InexactError), cases) == 3
    for r in WTRunner.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    # Tuple{Type{Int64}, Any}: one class times every class the closed world has, past the bound
    local e = try; W.compile(OpenTupleCases.over, (Int64,); optimize = false); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("max_union_splitting", e.rejection.row)
end

end
