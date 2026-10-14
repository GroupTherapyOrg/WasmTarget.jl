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

# R40: a compile's state is its own (its Translator's and its module's registries), never process
# state. A compile run inside another compile's link_roots hook leaves the outer compile's module
# objects alone: the outer module's RNG globals and perf_now import, made before its hook runs, are
# still the ones its code reads, and the outer ledger receives none of the inner compile's
# diagnostics. A compile does not inherit the options an earlier compile read: compile_module,
# called directly, reads its own environment (a process-wide options Ref left the registration
# log of an earlier, logging compile on). On the base (process state) the inner compile reset the
# RNG globals and perf_now import the outer compile had made, and compile_module logged; the
# ledger check passed there too (the process-wide sink was set and restored around each compile),
# so it is a regression check, not R40's evidence.
@noinline _ds3_outer(x::Int64) = Int64(rand(Int64) % 7) + Int64(time_ns() % UInt64(2)) + x
@noinline _ds3_inner(x::Int64) = Int64(rand(Int64) % 3) + Int64(time_ns() % UInt64(2)) + x
_ds3_plain(x::Int64) = x * 5
_ds_bad3(x::Any) = Int64(x) + 3
@testset "a compile inside another's hook, and after another's options, shares no state (R40)" begin
    local inner_bytes = UInt8[]
    m = WasmTarget.compile_module(Any[(_ds3_outer, (Int64,), "outer")];
        link_roots=(lm, roots, _) -> (inner_bytes = WasmTarget.compile(_ds3_inner, (Int64,)); nothing))
    @test !isempty(inner_bytes)
    # the outer ledger receives none of a rejected inner compile's diagnostics
    outer_sink = WasmTarget.WasmDiagnostic[]
    inner_sink = WasmTarget.WasmDiagnostic[]
    WasmTarget.compile_multi(Any[(_ds3_plain, (Int64,), "plain")]; diagnostics_sink=outer_sink,
        link_roots=(lm, roots, _) -> (try; WasmTarget.compile(_ds_bad3, (Any,); diagnostics_sink=inner_sink); catch e; e isa WasmTarget.WasmCompileError || rethrow(); end; nothing))
    @test !isempty(inner_sink)
    @test isempty(outer_sink)
    count_import(mod, f) = count(imp -> imp.module_name == "env" && imp.field_name == f, mod.imports)
    @test count_import(m, "random_i64") == 1 && count_import(m, "perf_now") == 1
    bytes = WasmTarget.to_bytes(m)
    status, val = WasmRunner.run_wasm_single(bytes, "outer", "3n")
    local v = val isa AbstractDict ? parse(Int, val["__bigint__"]) : val   # an i64 result crosses as a BigInt
    @test status === :ok && v isa Integer && -3 <= v <= 10
    # a logging compile, then compile_module called directly with no log asked: only the first logs
    local log_path = tempname()
    open(log_path, "w") do io
        redirect_stderr(io) do
            withenv("WT_LOG_REGISTRY" => "1") do
                WasmTarget.compile(_ds3_plain, (Int64,))
            end
            println(stderr, "--- the second compile")
            WasmTarget.compile_module(Any[(_ds3_plain, (Int64,), "plain")])
        end
    end
    local log = read(log_path, String)
    local first_part, second_part = split(log, "--- the second compile"; limit=2)
    @test occursin("WTREG", first_part)
    @test !occursin("WTREG", second_part)
end
