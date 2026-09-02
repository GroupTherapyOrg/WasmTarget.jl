# Byte-identity probe lane (dev/MARCH.md §4 Phase 1 item 4, §5 "byte identity").
#
# Purpose: a fast, deterministic fingerprint of a fixed probe corpus so any PURE
# restructuring (Phase 2 bloat nuke, Phase 4 duplication collapse, etc.) can be
# checked for byte-for-byte identical codegen output in seconds, without running
# the full differential suite. This is NOT a soundness or parity gate — it only
# proves "nothing observable changed"; dart2wasm structural parity and the native
# differential remain the real oracles (see dev/PARITY_MASTER.md).
#
# Each probe compiles with `WasmTarget.compile_multi([(f, argtypes, name)]; validate=false)`
# — the explicit export NAME matters: `compile(f, …)` exports `string(nameof(f))`, and for an
# anonymous closure that is Julia's session-global gensym (`#17`), which advances whenever any
# closure is defined in the process, so the bytes would depend on corpus order, not codegen.
# (unoptimized IR, no wasm-tools double-check — module bytes only) and is
# fingerprinted with `bytes2hex(SHA.sha256(bytes))`. SHA is a Julia stdlib
# (always on LOAD_PATH regardless of the active Project.toml), so `using SHA`
# resolves under plain `--project=.` with no extra dependency wiring.
#
# Usage:
#   julia --project=. test/probe_bytes.jl            # compare against the baseline
#   WT_PROBE_RECORD=1 julia --project=. test/probe_bytes.jl   # rewrite the baseline
#
# On mismatch: prints every changed probe name (baseline hash vs new hash) and
# exits 1. On a clean run: prints a one-line summary and exits 0.

using WasmTarget
using SHA

const _PROBE_DIR = @__DIR__
const _BASELINE_PATH = joinpath(_PROBE_DIR, "probe_baseline.txt")
include("probe_corpus.jl")

function main()
    hashes = Dict{String,String}()
    for (name, (f, argtypes)) in CASES
        bytes = WasmTarget.compile_multi([(f, argtypes, name)]; validate=false)
        hashes[name] = bytes2hex(SHA.sha256(bytes))
        # WT_PROBE_DUMP=<name>:<path> writes one probe's binary for cross-process diffing
        dump = get(ENV, "WT_PROBE_DUMP", "")
        if dump != "" && startswith(dump, name * ":")
            write(dump[length(name)+2:end], bytes)
        end
    end

    if get(ENV, "WT_PROBE_RECORD", "") == "1"
        _write_baseline(_BASELINE_PATH, hashes)
        println("probe_bytes: recorded $(length(hashes)) probes to $(_BASELINE_PATH)")
        return 0
    end

    baseline = _load_baseline(_BASELINE_PATH)
    if isempty(baseline)
        println("probe_bytes: no baseline at $(_BASELINE_PATH) — run with WT_PROBE_RECORD=1 first")
        return 1
    end

    changed = String[]
    for name in sort(collect(keys(hashes)))
        old = get(baseline, name, nothing)
        new = hashes[name]
        if old === nothing
            println("  NEW probe (not in baseline): ", name, " => ", new)
            push!(changed, name)
        elseif old != new
            println("  CHANGED: ", name, "  ", old, " -> ", new)
            push!(changed, name)
        end
    end
    for name in sort(collect(keys(baseline)))
        if !haskey(hashes, name)
            println("  MISSING probe (in baseline, not in corpus): ", name)
            push!(changed, name)
        end
    end

    println("probe_bytes: $(length(hashes)) probes, $(length(changed)) changed")
    return isempty(changed) ? 0 : 1
end

exit(main())
