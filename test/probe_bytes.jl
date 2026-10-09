# Byte-identity probe lane (dev/MARCH.md §4 Phase 1 item 4, §5 "byte identity").
#
# Purpose: a fast, deterministic fingerprint of a fixed probe corpus so any PURE
# restructuring (Phase 2 bloat nuke, Phase 4 duplication collapse, etc.) can be
# checked for byte-for-byte identical codegen output in seconds, without running
# the full differential suite. This is NOT a soundness or parity gate — it only
# proves "nothing observable changed"; dart2wasm structural parity and the native
# differential remain the real oracles (see AGENTS.md).
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

# Exception handling is dart's legacy form (L155): a printed probe module holds none of the
# instructions dart2wasm does not emit. Its text, as wasm-tools prints it, is read.
const _NON_DART_EH = r"\b(try_table|throw_ref|delegate|catch_all)\b"
_non_dart_eh(printed::String)::Bool = occursin(_NON_DART_EH, printed)

# The names the module's name section gives its globals (subsection 7), read from its bytes.
function _global_names(bytes::Vector{UInt8})::Vector{String}
    local uleb(i) = (r = 0; s = 0; while true; x = bytes[i]; i += 1; r |= Int(x & 0x7f) << s; s += 7; x < 0x80 && return (r, i); end)
    local names = String[]
    local i = 9
    while i <= length(bytes)
        local id = bytes[i]
        local size, j = uleb(i + 1)
        local stop = j + size
        if id == 0x00
            local nlen, k = uleb(j)
            if String(bytes[k:k + nlen - 1]) == "name"
                k += nlen
                while k < stop
                    local sub = bytes[k]
                    local ssize, m = uleb(k + 1)
                    if sub == 0x07
                        local count, q = uleb(m)
                        for _ in 1:count
                            local _, q2 = uleb(q)
                            local len, q3 = uleb(q2)
                            push!(names, String(bytes[q3:q3 + len - 1]))
                            q = q3 + len
                        end
                    end
                    k = m + ssize
                end
            end
        end
        i = stop
    end
    return names
end
# every global the module names is named in its printed text (`(global $<name>`), as dart's
# NameSection writes each global's name (sections.dart:844): the global names its writer wrote
_unnamed_globals(bytes::Vector{UInt8}, printed::String)::Int =
    count(n -> !occursin("(global \$" * n * " ", printed), _global_names(bytes))

function main()
    hashes = Dict{String,String}()
    non_dart_eh = String[]
    unnamed = String[]
    for (name, (f, argtypes)) in CASES
        bytes = WasmTarget.compile_multi([(f, argtypes, name)]; validate=false)
        hashes[name] = bytes2hex(SHA.sha256(bytes))
        printed = read(pipeline(`wasm-tools print`; stdin=IOBuffer(bytes)), String)
        _non_dart_eh(printed) && push!(non_dart_eh, name)
        _unnamed_globals(bytes, printed) == 0 || push!(unnamed, name)
        # WT_PROBE_DUMP=<name>:<path> writes one probe's binary for cross-process diffing
        dump = get(ENV, "WT_PROBE_DUMP", "")
        if dump != "" && startswith(dump, name * ":")
            write(dump[length(name)+2:end], bytes)
        end
    end

    if !isempty(unnamed)
        for name in unnamed
            println("  A NAMED GLOBAL NOT PRINTED BY ITS NAME: ", name)
        end
        println("probe_bytes: $(length(unnamed)) of $(length(hashes)) probes name a global the printed module does not")
        return 1
    end

    if !isempty(non_dart_eh)
        for name in non_dart_eh
            println("  NOT DART'S EXCEPTION HANDLING (try_table, throw_ref, delegate or catch_all): ", name)
        end
        println("probe_bytes: $(length(non_dart_eh)) of $(length(hashes)) probes hold exception handling dart2wasm does not emit")
        return 1
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
