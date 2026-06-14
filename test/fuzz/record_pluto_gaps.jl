# Record PlutoIslands-featured-corpus-derived WT gaps into the ledger.
# Each reproducer is verified to THROW (gap present) before recording.
#
# Run:  julia --project=test/fuzz test/fuzz/record_pluto_gaps.jl

const FUZZ_DIR = @__DIR__
include(joinpath(FUZZ_DIR, "harness.jl")); using .FuzzHarness
include(joinpath(FUZZ_DIR, "ledger.jl"));  using .Ledger

# (id-less) gap specs: (category, construct, location, arg_types, reproducer, diag)
gaps = Tuple[]

# ── string(::Complex{Float64}) — fractals Julia-set label "0.9 + 0.4im" ──
push!(gaps, (
    :runtime_trap,
    "string(::Complex{Float64}) traps/exec-errors in wasm (PlutoIslands fractals label `0.9 + 0.4im`); downstream of string(::Float64)/Ryu gap 19d59e9a61b3",
    "PlutoIslands featured corpus (fractals.jl)",
    "(Int64,)",
    """
using WasmTarget
include(joinpath("test", "fuzz", "harness.jl")); using .FuzzHarness
repro(x::Int64) = string(complex(0.9, 0.4 + Float64(x)))

_nat = try (true, repro(Int64(0))) catch; (false, nothing) end
_r = FuzzHarness.compile_and_run_vec(repro, (Int64,), [(Int64(0),)])[1]
_ok = _nat[1] ? (_r[1] === :ok && _nat[2] == _r[2]) : (_r[1] === :trap)
_ok || error("WasmTarget gap: native=\$(_nat[1] ? _nat[2] : :throw) wasm=\$_r")
""",
    "native=\"0.9 + 0.4im\"  wasm=exec_error (Complex display routes through string(::Float64) → Ryu)",
))

for (cat, construct, loc, argt, repro, diag) in gaps
    # verify the reproducer THROWS (gap present) before recording
    present = try
        include_string(Main, repro); false
    catch
        true
    end
    if !present
        println("SKIP (reproducer did not throw — gap not present?): ", construct)
        continue
    end
    g = Ledger.Gap(cat, cat, construct, loc, "repro", argt, repro, diag)
    id = Ledger.record_gap!(g; run_id = "pluto-corpus-2026-06-13")
    println("recorded gap ", id, " — ", construct)
end

Ledger.regenerate_index!()
println("DONE — index regenerated")
