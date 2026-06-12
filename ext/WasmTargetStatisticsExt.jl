# WasmTargetStatisticsExt — Statistics stdlib integration.
#
# Statistics compiles almost entirely from its REAL implementations (mean,
# var, std, cor, middle, median!, quantile! need no stdlib-specific code —
# the pilot's fixes all landed in the core compiler). This extension only
# carries the 1.13-gated wrapper reroutes below.
module WasmTargetStatisticsExt

using WasmTarget
using Statistics
using Base.Experimental: @overlay

# On 1.13, the `median(v)` / `quantile(v, p)` WRAPPER specializations inline
# into an IR shape that hits a known generator limitation (a dead-coded
# boundscheck arm interacting with an intra-range jump target — see the
# stdlib-statistics branch notes). Their LITERAL definitions compile
# correctly, so reroute through them; semantically identical by definition.
@static if VERSION >= v"1.13-"
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.median(v::AbstractVector) =
        Statistics.median!(copy(v))
    @overlay WasmTarget.WASM_METHOD_TABLE Statistics.quantile(v::AbstractVector, p::Real) =
        Statistics.quantile!(copy(v), p)
end

end # module
