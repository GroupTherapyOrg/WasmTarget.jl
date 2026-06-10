using WasmTarget
include(joinpath("test", "fuzz", "harness.jl"));     using .FuzzHarness
include(joinpath("test", "fuzz", "bridge.jl"));      using .FuzzBridge
include(joinpath("test", "fuzz", "bridge_args.jl")); using .FuzzBridgeArgs
include(joinpath("test", "fuzz", "structpool.jl"));  using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(v::Vector{Int64}) = maximum(v)
_x = Int64[]
_c = deepcopy(_x)
_nat = try (:ok, repro(_c)) catch e (:throw, e) end
_rt = Base.widenconst(Base.code_typed(repro, (Vector{Int64},))[1][2])
_res = FuzzBridgeArgs.bridge_run_args(repro, (Vector{Int64},), [(deepcopy(_x),)]; rettype = _rt, opt=:size)[1]
_pd = FuzzBridgeArgs.ismutable_shape(Vector{Int64}) ? FuzzBridge.descriptor(Vector{Int64})[1] : nothing
_ok = _nat[1] === :throw ? (_res[1] === :trap) :
    (_res[1] === :ok &&
     FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
     (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
_ok || error("WasmTarget gap (wasm-opt size) @ x=$_x : native=$(_nat[1] === :throw ? :throw : _nat[2]) wasm=$(_res[1]) $(_res[2])")
