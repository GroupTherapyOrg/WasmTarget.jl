# The caller-facing diagnostics ledger (compile(...; diagnostics_sink=...)) — the surface
# Snapshot.jl's failure cards read. Contract: fatal errors carry the FULL ledger on
# `err.all`; the sink mirrors every recorded diagnostic; the Ref is always restored.
@testset "diagnostics sink (caller-facing ledger)" begin
    _ds_bad(x::Any) = Int64(x) + 1          # unresolved dynamic call on the entry
    sink = WasmTarget.WasmDiagnostic[]
    err = try
        WasmTarget.compile(_ds_bad, (Any,); diagnostics_sink=sink)
        nothing
    catch e
        e
    end
    @test err isa WasmTarget.WasmCompileError
    @test !isempty(err.all)
    @test err.diag in err.all
    @test !isempty(sink)
    @test err.diag.kind === :unsupported_method
    @test occursin("dynamic", err.diag.construct)
    @test WasmTarget.DIAGNOSTICS_SINK[] === nothing       # restored after the call

    # success path: no worries recorded, sink untouched but valid
    _ds_good(x::Int64) = x + 1
    sink2 = WasmTarget.WasmDiagnostic[]
    bytes = WasmTarget.compile(_ds_good, (Int64,); diagnostics_sink=sink2)
    @test !isempty(bytes)
    @test WasmTarget.DIAGNOSTICS_SINK[] === nothing

    # back-compat: 1-arg WasmCompileError constructor still works
    d = WasmTarget.WasmDiagnostic(:unsupported_method, "f", "x", nothing, nothing)
    e1 = WasmTarget.WasmCompileError(d)
    @test e1.all == [d]
end
