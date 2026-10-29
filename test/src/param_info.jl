# dart2wasm's param_info.dart, ported (src/param_info.jl, dev/MARCH.md 1.D): a member's parameter
# info, each answer Julia's own signature.
using Test
using WasmTarget

const DP = WasmTarget.Dart2Wasm

module ParamCases
f(x::Int32) = x + Int32(1)
g(a::Int, b::Float64, c::Bool) = c ? a : b
make(k::Int) = (y::Int -> y + k)
end

_mi(f, T) = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, T)))

@testset "param_info.dart: ParameterInfo of a Julia member" begin
    # a positional, required parameter per argument after the callee, as Julia's signature gives
    local pf = DP.ParameterInfo_from_member(_mi(ParamCases.f, (Int32,)), false)
    @test pf.type_param_count == 0 && pf.positional == [nothing] && isempty(pf.named) && DP.param_count(pf) == 1
    local pg = DP.ParameterInfo_from_member(_mi(ParamCases.g, (Int, Float64, Bool)), false)
    @test DP.param_count(pg) == length(fieldtypes(Base.signature_type(ParamCases.g, (Int, Float64, Bool)))) - 1 == 3
    # the callee is the context unless it is a singleton: a closure's captured struct is not
    @test !pf.takes_context_or_receiver && Base.issingletontype(typeof(ParamCases.f))
    local clo = ParamCases.make(2)
    @test !Base.issingletontype(typeof(clo))
    @test DP.ParameterInfo_from_member(_mi(clo, (Int,)), false).takes_context_or_receiver
    # no named parameters: names and their indices are empty
    @test isempty(pf.names[]) && isempty(pf.name_index[])
end

_pc(x) = WasmTarget.NirConst(Core.Const(x))
_pinfo(pos, named = Pair{String,Any}[]) = DP.ParameterInfo__(true, 0, Union{Nothing,WasmTarget.NirConst}[pos...],
    (m = WasmTarget.LinkedHashMap{String,Union{Nothing,WasmTarget.NirConst}}(); foreach(((k, v),) -> (m[k] = v), named); m))

@testset "param_info.dart: a local function, and merging an override group" begin
    # a closure: its specialization's arguments after the callee, all required, its context taken
    local clo = ParamCases.make(2)
    local world = WasmTarget.build_nir(WasmTarget.check_subset(clo, (Int,), "param_info"), "param_info")
    local body = only(b for b in world if b.ci.def.specTypes == Tuple{typeof(clo),Int})
    local pl = DP.ParameterInfo_from_local_function(body)
    @test pl.takes_context_or_receiver && pl.type_param_count == 0 && pl.positional == [nothing] && isempty(pl.named)
    # merge: a required slot takes the other's default, equal defaults stay, differing ones meet the
    # sentinel, a constant equal to no program value
    local s = DP.ParameterInfo_default_value_sentinel[]
    @test s === DP.ParameterInfo_default_value_sentinel[] && s != _pc(Symbol("Default value sentinel"))
    local a = _pinfo([nothing, _pc(1), _pc(2)], ["x" => _pc(:a), "y" => nothing])
    DP.merge(a, _pinfo([_pc(0), _pc(1), _pc(3), _pc(4)], ["x" => _pc(:b), "y" => _pc(5), "z" => nothing]))
    @test a.positional == Union{Nothing,WasmTarget.NirConst}[_pc(0), _pc(1), s, _pc(4)]
    @test a.named["x"] === s && a.named["y"] === _pc(5) && a.named["z"] === nothing && collect(keys(a.named)) == ["x", "y", "z"]
    local e = try; DP.merge(a, DP.ParameterInfo__(false, 0, Union{Nothing,WasmTarget.NirConst}[],
        WasmTarget.LinkedHashMap{String,Union{Nothing,WasmTarget.NirConst}}())); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
end
