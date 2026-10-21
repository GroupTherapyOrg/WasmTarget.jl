# Byte-identity probes: a fixed corpus (test/probe_corpus.jl) compiled with WasmTarget.compile and
# fingerprinted by `bytes2hex(SHA.sha256(bytes))` against test/probe_baseline.txt, so a pure
# restructuring is checked byte for byte in seconds. Not a soundness or parity gate: it proves only
# that nothing observable changed.
#
#   julia --project=. test/probe_bytes.jl            # compare against the baseline
#   WT_PROBE_RECORD=1 julia --project=. test/probe_bytes.jl   # rewrite the baseline
#   WT_PROBE_ONLY="<name> ..." julia --project=. test/probe_bytes.jl   # exactly those probes (a
#       name the corpus lacks fails the run): dev/block.jl's probe core and the change's own probes.
#       A selection never records.
#
# On a mismatch it prints every changed probe and exits 1; on a clean run, a one-line summary.

using WasmTarget
using SHA

const _BASELINE_PATH = joinpath(@__DIR__, "probe_baseline.txt")
include("probe_corpus.jl")

function main()
    hashes = Dict{String,String}()
    local names = first.(CASES)
    local mine = Set(names)
    local only = split(get(ENV, "WT_PROBE_ONLY", ""))
    if !isempty(only)
        get(ENV, "WT_PROBE_RECORD", "") == "1" &&
            (println("probe_bytes: WT_PROBE_ONLY records nothing: a baseline is recorded by a whole run"); return 1)
        local unknown = filter(n -> !(n in names), only)
        isempty(unknown) || (println("probe_bytes: WT_PROBE_ONLY names no probe ", join(unknown, ", ")); return 1)
        intersect!(mine, only)
    end
    for (name, (f, argtypes)) in CASES
        name in mine || continue
        hashes[name] = bytes2hex(SHA.sha256(WasmTarget.compile(f, argtypes)))
    end
    if get(ENV, "WT_PROBE_RECORD", "") == "1"
        _write_baseline(_BASELINE_PATH, hashes)
        println("probe_bytes: recorded $(length(hashes)) probes to $(_BASELINE_PATH)")
        return 0
    end
    baseline = _load_baseline(_BASELINE_PATH)
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
        # a selection checks its own probes, and every baseline name the corpus lacks
        (name in mine || !(name in names)) || continue
        if !haskey(hashes, name)
            println("  MISSING probe (in baseline, not in corpus): ", name)
            push!(changed, name)
        end
    end
    println("probe_bytes: $(length(hashes)) probes$(isempty(only) ? "" : " (of $(length(names)))"), $(length(changed)) changed")
    return isempty(changed) ? 0 : 1
end

exit(main())
