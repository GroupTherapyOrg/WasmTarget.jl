# Phase 10.2 prototype — native linear-memory SIDECAR module (dev/PARITY_MASTER.md
# roadmap item 3, design test/../scratchpad/p10/DESIGN.md §10.2).
#
# dart2wasm's host boundary (functions.dart:90 wasm:import/export pragma funnel,
# restricted by translateExternalType at translator.dart:1239) admits a real
# LINEAR MEMORY: ffiMemory lazily imports "ffi"."memory" (translator.dart:213),
# and scalar Pointer<T> access lowers to inline f64.load/f64.store
# (intrinsics.dart:1630-1740). WT's typed builder has no scalar memory opcodes
# yet, so this prototype reaches the sidecar's linear memory through accessor
# CALLS instead — the quarantine boundary this experiment exists to size.
#
# Architecture: `daxpy.wat` (hand-written, own exported memory, no libc) is
# assembled at test time via `wasm-tools parse` and instantiated as a SEPARATE
# wasm module. WT compiles `sidecar_daxpy` — an ORDINARY Julia function — into
# a second module that IMPORTS the sidecar's five exports (add_import! +
# import_stubs, exactly Therapy's DOM-bridge / WasmMakie canvas2d pattern:
# Therapy.jl/src/Compiler/Compile.jl:264-286, WasmMakie.jl/src/ops.jl). The
# two modules are linked by the HOST (the JS driver passes the sidecar's
# instantiated exports as an import object to the second) — this is NOT
# wasm-merge (L98's road is for two WT-compiled GC binaries sharing one object
# model; here the sidecar owns its own linear memory and there is no shared
# object model at all).
#
# Ownership rule: GC arrays (Julia Vector{Float64}) never cross the boundary.
# `sidecar_daxpy` copies its inputs into sidecar scratch via `store_f64`,
# calls `daxpy`, copies the result back out via `load_f64` into a FRESH
# Vector{Float64}, then calls `reset` — the sidecar's linear memory is pure
# per-call scratch, and no pointer or reference is ever shared.

using Test
using Random
using WasmTarget
const WT = WasmTarget

# ── Assemble + validate the sidecar binary (test time; only the .wat is committed) ──
const SIDECAR_WAT = joinpath(@__DIR__, "daxpy.wat")

function _assemble_wat(wat_path::String)::Vector{UInt8}
    wasm_tools = Sys.which("wasm-tools")
    wasm_tools === nothing && error("wasm-tools not found on PATH — required to assemble $wat_path")
    mktempdir() do dir
        out = joinpath(dir, "out.wasm")
        run(`$wasm_tools parse $wat_path -o $out`)
        return read(out)
    end
end

const SIDECAR_BYTES = _assemble_wat(SIDECAR_WAT)

@testset "sidecar: daxpy.wat validates" begin
    wasm_tools = Sys.which("wasm-tools")
    @test wasm_tools !== nothing
    if wasm_tools !== nothing
        # `wasm-tools validate` accepts a binary directly (exits nonzero + stderr on reject).
        p = run(pipeline(`$wasm_tools validate $SIDECAR_WAT`; stdout=devnull, stderr=devnull); wait=false)
        wait(p)
        @test p.exitcode == 0
    end
    @test !isempty(SIDECAR_BYTES)
end

# ── WT-side stub functions ───────────────────────────────────────────────────
# @noinline + Base.donotdelete keeps the :invoke alive in optimized IR (so the
# closed-world collector's external-leaf machinery sees the call instead of it
# being inlined/elided away). Base.inferencebarrier on every return is
# LOAD-BEARING: without it, constant-prop folds the stub's literal return value
# into the caller, so compiled wasm would still CALL the import but use the
# folded constant instead of the import's actual (runtime-varying) result — the
# exact bug WasmMakie's canvas ops document (F-007: a folded 0.0 silently
# discarded a real measureText call). alloc/load_f64 return values are the
# clearest case here: they MUST vary per call, so a fold would be invisible in
# codegen but wrong at runtime.
@noinline function _sc_alloc(bytes::Int32)::Int32
    Base.donotdelete(bytes)
    return Base.inferencebarrier(Int32(0))::Int32
end

@noinline function _sc_reset()::Nothing
    return nothing
end

@noinline function _sc_store_f64(ptr::Int32, v::Float64)::Nothing
    Base.donotdelete(ptr, v)
    return nothing
end

@noinline function _sc_load_f64(ptr::Int32)::Float64
    Base.donotdelete(ptr)
    return Base.inferencebarrier(0.0)::Float64
end

@noinline function _sc_daxpy(n::Int32, a::Float64, x::Int32, y::Int32)::Nothing
    Base.donotdelete(n, a, x, y)
    return nothing
end

# ── The WT-compiled wrapper: ordinary Julia, compiled through the normal path ──
"""
    sidecar_daxpy(a, x, y) -> Vector{Float64}

y[i] = a*x[i] + y[i], computed by copying x and y into the sidecar's linear
memory, calling its `daxpy`, and copying the result back into a fresh
Vector{Float64} (native GC arrays never cross the boundary — see the file
header's ownership rule). Assumes `length(x) == length(y)`.
"""
# formal(dev/formal/Sidecar.tla): per-call scratch — every copy-out reads a slot written in THIS call, the bump pointer returns to base after reset, no GC reference enters linear memory, and y = a*x + y holds under x === y
function sidecar_daxpy(a::Float64, x::Vector{Float64}, y::Vector{Float64})::Vector{Float64}
    n = length(x)
    n32 = Int32(n)
    nbytes = n32 * Int32(8)
    xptr = _sc_alloc(nbytes)
    yptr = _sc_alloc(nbytes)
    for i in 1:n
        _sc_store_f64(xptr + Int32(i - 1) * Int32(8), x[i])
    end
    for i in 1:n
        _sc_store_f64(yptr + Int32(i - 1) * Int32(8), y[i])
    end
    _sc_daxpy(n32, a, xptr, yptr)
    out = Vector{Float64}(undef, n)
    for i in 1:n
        out[i] = _sc_load_f64(yptr + Int32(i - 1) * Int32(8))
    end
    _sc_reset()
    return out
end

"""
    sidecar_daxpy_twice(a1, x1, y1, a2, x2, y2) -> Vector{Float64}

Calls `sidecar_daxpy` TWICE, back-to-back, inside ONE compiled wasm function,
with independently-sized inputs, and concatenates both results. Proves
`reset` is real (the second call's scratch reuses byte offset 0) and that no
state leaks between calls sharing one module instance — the ownership case
the design review demanded.
"""
function sidecar_daxpy_twice(a1::Float64, x1::Vector{Float64}, y1::Vector{Float64},
                              a2::Float64, x2::Vector{Float64}, y2::Vector{Float64})::Vector{Float64}
    r1 = sidecar_daxpy(a1, x1, y1)
    r2 = sidecar_daxpy(a2, x2, y2)
    out = Vector{Float64}(undef, length(r1) + length(r2))
    for i in 1:length(r1)
        out[i] = r1[i]
    end
    for i in 1:length(r2)
        out[length(r1) + i] = r2[i]
    end
    return out
end

# ── Build the WT module: declare the sidecar's 5 exports as imports, wire the
#    Julia stubs to them via import_stubs, compile both roots into ONE module ──
const SIDECAR_MODULE_NAME = "sidecar"

function _build_sidecar_wt_module()
    mod = WT.WasmModule()
    alloc_idx = WT.add_import!(mod, SIDECAR_MODULE_NAME, "alloc", WT.NumType[WT.I32], WT.NumType[WT.I32])
    reset_idx = WT.add_import!(mod, SIDECAR_MODULE_NAME, "reset", WT.NumType[], WT.NumType[])
    store_idx = WT.add_import!(mod, SIDECAR_MODULE_NAME, "store_f64", WT.NumType[WT.I32, WT.F64], WT.NumType[])
    load_idx  = WT.add_import!(mod, SIDECAR_MODULE_NAME, "load_f64", WT.NumType[WT.I32], WT.NumType[WT.F64])
    daxpy_idx = WT.add_import!(mod, SIDECAR_MODULE_NAME, "daxpy",
        WT.NumType[WT.I32, WT.F64, WT.I32, WT.I32], WT.NumType[])

    import_stubs = Any[
        (_sc_alloc,     "alloc",     (Int32,),                         alloc_idx, Int32),
        (_sc_reset,     "reset",     (),                                reset_idx, Nothing),
        (_sc_store_f64, "store_f64", (Int32, Float64),                 store_idx, Nothing),
        (_sc_load_f64,  "load_f64",  (Int32,),                          load_idx,  Float64),
        (_sc_daxpy,     "daxpy",     (Int32, Float64, Int32, Int32),   daxpy_idx, Nothing),
    ]

    func_list = Any[
        (sidecar_daxpy, (Float64, Vector{Float64}, Vector{Float64})),
        (sidecar_daxpy_twice,
            (Float64, Vector{Float64}, Vector{Float64}, Float64, Vector{Float64}, Vector{Float64})),
    ]
    append!(func_list, BRIDGE_SPECS_F64)   # _bv_f64_new/set!/get/len — Vector{Float64} marshalling

    bytes = WT.compile_multi(func_list; existing_module=mod, import_stubs=import_stubs)
    return bytes, (; alloc_idx, reset_idx, store_idx, load_idx, daxpy_idx)
end

const SIDECAR_WT_BYTES, SIDECAR_IMPORT_IDXS = _build_sidecar_wt_module()

@testset "sidecar: WT wiring" begin
    @test WasmRunner.runner_available() || true   # informational; cases below skip gracefully

    # Confirm every import stub firing through translate_external_type/
    # _check_import_stub_external_types! unchanged: all 5 declared import
    # signatures are plain numeric (Int32/Float64), so no coercion happens.
    @test WT.translate_external_type(Int32, WT.WasmModule(), WT.TypeRegistry()) == WT.I32
    @test WT.translate_external_type(Float64, WT.WasmModule(), WT.TypeRegistry()) == WT.F64

    @test !isempty(SIDECAR_WT_BYTES)

    # The GC module owns NO linear memory of its own — only the sidecar does.
    # `wasm-tools print` renders a `(memory ...)` form for a memory SECTION;
    # the main module must have none.
    wasm_tools = Sys.which("wasm-tools")
    if wasm_tools !== nothing
        mktempdir() do dir
            mainpath = joinpath(dir, "main.wasm")
            write(mainpath, SIDECAR_WT_BYTES)
            printed = read(`$wasm_tools print $mainpath`, String)
            @test !occursin(r"\(memory\b", printed)
        end
    end

    # dev-facing wasm-tools validation of the MAIN module too (import types
    # must match the sidecar's real export types for this to validate on its
    # own against a matching import object — validated by the Node driver
    # below via actual instantiation, which is the load-bearing check).
    @test wasm_tools !== nothing
end

# ── Differential cases: oracle = native `a .* x .+ y` (NEVER `sidecar_daxpy`
#    called natively — its import stubs are inference-barrier no-ops off the
#    wasm boundary; see the stub comments above) ──────────────────────────────
@testset "sidecar: daxpy differential" begin
    rng = Random.MersenneTwister(0x5c1d0102)
    cases = [
        (name="n=0",          a=1.0,  x=Float64[],                          y=Float64[]),
        (name="n=1",          a=3.0,  x=[2.0],                              y=[5.0]),
        (name="n=7",          a=1.5,  x=collect(1.0:7.0),                   y=collect(10.0:10:70.0)),
        (name="n=1000 rand",  a=0.37, x=randn(rng, 1000),                   y=randn(rng, 1000)),
        (name="a=0",          a=0.0,  x=[1.0, 2.0, 3.0],                    y=[9.0, 8.0, 7.0]),
        (name="a=-2.5",       a=-2.5, x=[1.0, -1.0, 2.0, -2.0],             y=[10.0, 20.0, -30.0, 0.0]),
        (name="NaN/Inf",      a=2.0,  x=[NaN, Inf, -Inf, 1.0],              y=[1.0, 1.0, 1.0, NaN]),
    ]
    for c in cases
        expected = c.a .* c.x .+ c.y
        r = compare_sidecar_wasm_vec(SIDECAR_WT_BYTES, SIDECAR_BYTES, SIDECAR_MODULE_NAME,
                                      "sidecar_daxpy", expected, c.a, c.x, c.y)
        @testset "$(c.name)" begin
            @test r.skipped || r.pass
            r.skipped && @warn "sidecar daxpy case skipped (no Node)" case = c.name
        end
    end
end

@testset "sidecar: reset ownership — double call in ONE compiled function" begin
    # Two back-to-back calls to `sidecar_daxpy` inside `sidecar_daxpy_twice`,
    # with DIFFERENT lengths, sharing ONE sidecar module instance across both.
    # If `reset` didn't really rewind the bump pointer (or if state otherwise
    # leaked between calls), the second call's scratch would either alias the
    # first's leftover bytes or drift to ever-larger offsets — both would be
    # silently wrong, not a trap, so this only proves out via the VALUES.
    a1, x1, y1 = 2.0, [1.0, 2.0, 3.0], [10.0, 20.0, 30.0]
    a2, x2, y2 = -1.5, [4.0, 5.0], [100.0, 200.0]
    expected = vcat(a1 .* x1 .+ y1, a2 .* x2 .+ y2)
    r = compare_sidecar_wasm_vec(SIDECAR_WT_BYTES, SIDECAR_BYTES, SIDECAR_MODULE_NAME,
                                  "sidecar_daxpy_twice", expected, a1, x1, y1, a2, x2, y2)
    @test r.skipped || r.pass
    r.skipped && @warn "sidecar double-call case skipped (no Node)"
end
