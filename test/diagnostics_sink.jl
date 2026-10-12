# The caller-facing diagnostics ledger (compile(...; diagnostics_sink=...)) — the surface
# Snapshot.jl's failure cards read. Contract: fatal errors carry the FULL ledger on
# `err.all`; the sink mirrors every recorded diagnostic; the ledger is the compile's own (its
# Translator's), never process state, so no compile sees another's (R40).
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

    # success path: no worries recorded, sink untouched but valid
    _ds_good(x::Int64) = x + 1
    sink2 = WasmTarget.WasmDiagnostic[]
    bytes = WasmTarget.compile(_ds_good, (Int64,); diagnostics_sink=sink2)
    @test !isempty(bytes)
    @test isempty(sink2)

    # back-compat: 1-arg WasmCompileError constructor still works
    d = WasmTarget.WasmDiagnostic(:unsupported_method, "f", "x", nothing, nothing)
    e1 = WasmTarget.WasmCompileError(d)
    @test e1.all == [d]
end

# R40: a compile's state is its own. Two compiles in one process, with different options and
# different ledgers: the second sees none of the first's state (its ledger, its options), and
# the first's module is the same as a fresh compile's.
@testset "two compiles in one process share no state (R40)" begin
    _ds2_bad(x::Any) = Int64(x) + 2
    _ds2_good(x::Int64) = x * 3
    _ds2_rng(x::Int64) = rand(Int64) % 2 + x   # the module's RNG globals (registry state)
    sink_a = WasmTarget.WasmDiagnostic[]
    err = try; WasmTarget.compile(_ds2_bad, (Any,); diagnostics_sink=sink_a); nothing; catch e; e; end
    @test err isa WasmTarget.WasmCompileError && !isempty(sink_a)
    sink_b = WasmTarget.WasmDiagnostic[]
    first_bytes = WasmTarget.compile(_ds2_good, (Int64,); diagnostics_sink=sink_b)
    @test isempty(sink_b)                                  # none of the first compile's diagnostics
    @test length(sink_a) == length(err.all)                # the first ledger unchanged by the second
    # a compile with the WT_TRACE option set and one without: each reads its own environment
    withenv("WT_LOG_REGISTRY" => "1") do
        @test !isempty(WasmTarget.compile(_ds2_good, (Int64,)))
    end
    @test WasmTarget.compile(_ds2_good, (Int64,)) == first_bytes
    # the module's RNG globals and perf_now import are per module: two modules, each its own
    r1 = WasmTarget.compile(_ds2_rng, (Int64,))
    r2 = WasmTarget.compile(_ds2_rng, (Int64,))
    @test r1 == r2
    @test WasmTarget.compile(_ds2_good, (Int64,)) == first_bytes
end
