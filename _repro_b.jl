using WasmTarget
include(joinpath("test", "fuzz", "harness.jl"));     using .FuzzHarness
include(joinpath("test", "fuzz", "bridge.jl"));      using .FuzzBridge
include(joinpath("test", "fuzz", "bridge_args.jl")); using .FuzzBridgeArgs
include(joinpath("test", "fuzz", "structpool.jl"));  using .FuzzStructPool
FuzzStructPool.build_pool!()
repro(x::Bool) = begin
    v_b = 0 + sum([0, 0, 0])
    try
        begin
            x && error("fz")
            x
        end
    catch
        x
    end
end
_x = true
_c = deepcopy(_x)
_nat = try (:ok, repro(_c)) catch e (:throw, e) end
_rt = Base.widenconst(Base.code_typed(repro, (Bool,))[1][2])
_res = FuzzBridgeArgs.bridge_run_args(repro, (Bool,), [(deepcopy(_x),)]; rettype = _rt)[1]
_pd = FuzzBridgeArgs.ismutable_shape(Bool) ? FuzzBridge.descriptor(Bool)[1] : nothing
_ok = _nat[1] === :throw ? (_res[1] === :trap) :
    (_res[1] === :ok &&
     FuzzBridge.tree_matches(FuzzBridge.descriptor(_rt)[1], _nat[2], _res[2]) &&
     (_pd === nothing || FuzzBridge.tree_matches(_pd, _c, _res[3][1])))
_ok || error("WasmTarget gap @ x=$_x : native=$(_nat[1] === :throw ? :throw : _nat[2]) wasm=$(_res[1]) $(_res[2])")
