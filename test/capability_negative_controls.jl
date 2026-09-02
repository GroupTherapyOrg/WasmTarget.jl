using Test

# ============================================================================
# Capability negative controls (dev/MARCH.md Phase 6.3) — dart2wasm's two-tier
# diagnostics model: a construct WT cannot represent must reject through
# record_unsupported! (a classified WasmCompileError with source location), NEVER
# via an internal invariant like StackImbalanceError leaking out to the caller.
#
# Each control below is a trip-wire, not just a smoke test: it asserts BOTH the
# exception TYPE and the exact blocker STRING, so a moved/renamed diagnostic goes
# red instead of silently drifting. `rand()` is the one POSITIVE control — it must
# keep compiling (WT provides host entropy via an import), proving the negative
# controls are testing capability boundaries, not "everything host-ish rejects".
# ============================================================================

# D1 (positive control): host entropy — compiles via an import, no rejection.
_wt_nc_rand(x::Float64) = x + rand()

# D2: wall clock — libc foreigncall with no lowering.
_wt_nc_time(x::Float64) = x + time()

# D3: stdin read. readline's IOStream path takes a reentrant lock that compares
# `current_task()` against `lock.locked_by` — outside the ONE safe consumption
# pattern (`rand()`'s rngState0..3 field access) that `jl_get_current_task`'s
# phantom-value handling assumes. Regression for the internal
# `StackImbalanceError` this used to surface as (calls.jl `_compile_call_egaleq`,
# "expected EqRef, found I32").
_wt_nc_readline(x::Float64) = x + parse(Float64, readline(stdin))

# D4: raw ccall to an unoverlaid libc symbol.
_wt_nc_ccall(x::Float64) = x + ccall(:getpid, Cint, ())

# D5: Threads.@spawn — task/scheduler creation.
function _wt_nc_threads_spawn(x::Float64)
    t = Threads.@spawn x + 1.0
    return fetch(t)
end

# D6: dlopen — a dynamic call WT cannot devirtualize.
function _wt_nc_dlopen(x::Float64)
    h = Base.Libc.dlopen("libc")
    return x
end

# D7: filesystem write.
_wt_nc_fs(x::Float64) = (write("/tmp/wt_negctl_probe.txt", "hi"); x)

# D8: Base.Threads.Atomic — a raw pointer escapes the storage-relative algebra.
function _wt_nc_atomic(x::Float64)
    a = Threads.Atomic{Int}(0)
    Threads.atomic_add!(a, 1)
    return x + a[]
end

# D9: eval — dynamic world-age reflection. Regression for the internal
# `StackImbalanceError` this used to surface as (invoke.jl compile_invoke!,
# "expected F64, found I64" on the outer `x + eval(ex)` add — eval's `:invoke`
# target was recursed into instead of rejected at the call site).
function _wt_nc_eval(x::Float64)
    ex = :(1 + 1)
    return x + eval(ex)
end

# D10: @async — task/scheduler creation (same foreigncall as Threads.@spawn).
function _wt_nc_async(x::Float64)
    t = @async x + 1.0
    return fetch(t)
end

_wt_nc_compile_err(f, argtypes) = try
    WasmTarget.compile(f, argtypes)
    nothing
catch caught
    caught
end

@testset "capability negative controls (dev/MARCH.md Phase 6.3)" begin
    @testset "rand() DOES compile — positive control (host entropy import)" begin
        bytes = WasmTarget.compile(_wt_nc_rand, (Float64,))
        @test bytes isa Vector{UInt8}
        @test !isempty(bytes)
    end

    @testset "time() rejects — no libc clock lowering" begin
        err = _wt_nc_compile_err(_wt_nc_time, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("foreigncall `jl_clock_now` (no lowering)", sprint(showerror, err))
    end

    @testset "readline(stdin) rejects — current_task() used outside the RNG pattern" begin
        err = _wt_nc_compile_err(_wt_nc_readline, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test !(err isa WasmTarget.StackImbalanceError)
        @test occursin(
            "current_task() (Task identity / scheduler state) used outside the rand() RNG-state field pattern",
            sprint(showerror, err))
    end

    @testset "ccall(:getpid) rejects — unoverlaid libc" begin
        err = _wt_nc_compile_err(_wt_nc_ccall, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("foreigncall `getpid` (no lowering)", sprint(showerror, err))
    end

    @testset "Threads.@spawn rejects — task/scheduler creation" begin
        err = _wt_nc_compile_err(_wt_nc_threads_spawn, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("foreigncall `jl_new_task` (no lowering)", sprint(showerror, err))
    end

    @testset "dlopen rejects — dynamic dispatch WT cannot lower" begin
        err = _wt_nc_compile_err(_wt_nc_dlopen, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("unresolved dynamic call `Base.getglobal`", sprint(showerror, err))
    end

    @testset "filesystem write rejects — no host filesystem import" begin
        err = _wt_nc_compile_err(_wt_nc_fs, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("foreigncall `ios_get_writable` (no lowering)", sprint(showerror, err))
    end

    @testset "Threads.Atomic rejects — pointer escapes storage-relative algebra" begin
        err = _wt_nc_compile_err(_wt_nc_atomic, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        # 1.12 lowers Atomic through jl_value_ptr pointer algebra; 1.13 through the
        # :invoke_modify IR head (atomic modifyfield!). Both must reject loudly —
        # the pre-p53 tree let :invoke_modify fall through and compiled the
        # function with an empty statement (the 1.13 CI red at 3cfa1269).
        msg = sprint(showerror, err)
        @test occursin("jl_value_ptr escapes storage-relative WasmGC operations", msg) ||
              occursin("IR head `:invoke_modify` has no lowering", msg)
    end

    @testset "eval rejects — dynamic world-age reflection" begin
        err = _wt_nc_compile_err(_wt_nc_eval, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test !(err isa WasmTarget.StackImbalanceError)
        # The quoted expression's :copyast statement precedes the eval call in
        # IR order, so the unknown-head reject (p53) fires first; the eval-specific
        # diagnostic remains the reason when no :copyast is present.
        msg = sprint(showerror, err)
        @test occursin("eval (dynamic world-age reflection is outside WT's closed-world compilation target)", msg) ||
              occursin("IR head `:copyast` has no lowering", msg)
    end

    @testset "@async rejects — task/scheduler creation" begin
        err = _wt_nc_compile_err(_wt_nc_async, (Float64,))
        @test err isa WasmTarget.WasmCompileError
        @test occursin("foreigncall `jl_new_task` (no lowering)", sprint(showerror, err))
    end
end
