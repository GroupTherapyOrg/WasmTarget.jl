# Shadow-compile recorder and comparator (PARITY_MASTER item 5, §10.3)
#
# Purpose: run_frontend(frontend::Symbol, cases; out::String) — compile a
# bounded corpus through a frontend (`:current` | `:unified`) and record
# module bytes + diagnostics (sha256 or WasmCompileError) to TSV;
# compare_runs(a::String, b::String) — diff two runs, print names that differ,
# exit 1 if any mismatch.
#
# Status (2026-09-02): UnifiedIR is absent in Base.Compiler on Julia 1.12.7
# and 1.13.0-rc1; the RFC is JuliaLang/julia#62334 (open, draft, unmerged).
# `:unified` is documented as a one-line extension point; :current is operative.
#
# Extension point for future frontends: add a method of `record_frontend`
# for its Symbol that produces the same TSV output; do not add a gated stub.
#
# Usage:
#   julia --project=. test/shadow_compile.jl record current /tmp-scratch/current.tsv
#   julia --project=. test/shadow_compile.jl compare /tmp-scratch/run1.tsv /tmp-scratch/run2.tsv
#
# NB: Do not include in test/runtests.jl — this is a manual experiment tool.

using WasmTarget
using SHA

include("probe_corpus.jl")

# ─────────────────────────────────────────────────────────────────────────────
# Shadow compiler: record module bytes (sha256) or compile error per case
# ─────────────────────────────────────────────────────────────────────────────

"""
    record_frontend(frontend::Symbol, cases; out::String)

Compile all cases through the given frontend, recording sha256(bytes) or
REJECTED:<error> per case to TSV file.

Only WasmCompileError is caught; other errors propagate (harness error).
"""
function record_frontend(frontend::Symbol, cases; out::String)
    rows = Pair{String,String}[]

    if frontend === :current
        for (name, (f, argtypes)) in cases
            try
                bytes = WasmTarget.compile_multi([(f, argtypes, name)]; validate=false)
                sha = bytes2hex(SHA.sha256(bytes))
                push!(rows, name => sha)
            catch err
                if err isa WasmTarget.WasmCompileError
                    # Extract first line of error message
                    msg = sprint(showerror, err)
                    first_line = split(msg, '\n')[1]
                    push!(rows, name => "REJECTED:$first_line")
                else
                    rethrow()
                end
            end
        end
    else
        error("shadow_compile: frontend $frontend is not available; see the extension point comment")
    end

    open(out, "w") do io
        for (name, result) in rows
            println(io, name, '\t', result)
        end
    end

    println("shadow_compile: recorded $(length(rows)) cases to $out")
end

# ─────────────────────────────────────────────────────────────────────────────
# Comparator: diff two TSV runs
# ─────────────────────────────────────────────────────────────────────────────

function _read_tsv(path::String)::Dict{String,String}
    result = Dict{String,String}()
    isfile(path) || error("$path does not exist")
    for line in eachline(path)
        isempty(line) && continue
        parts = split(line, '\t'; limit=2)
        length(parts) == 2 || continue
        result[parts[1]] = parts[2]
    end
    return result
end

"""
    compare_runs(a::String, b::String)

Load two TSV files and compare per-case results. Print diffs.
Exit 1 if any differ, 0 if all match.
"""
function compare_runs(a::String, b::String)
    run_a = _read_tsv(a)
    run_b = _read_tsv(b)

    all_names = sort(collect(union(keys(run_a), keys(run_b))))
    diffs = String[]

    for name in all_names
        val_a = get(run_a, name, nothing)
        val_b = get(run_b, name, nothing)

        if val_a === nothing
            println("  MISSING in run_a: $name")
            push!(diffs, name)
        elseif val_b === nothing
            println("  MISSING in run_b: $name")
            push!(diffs, name)
        elseif val_a == val_b
            # Match — no output
        elseif startswith(val_a, "REJECTED:") && startswith(val_b, "REJECTED:")
            # Both rejected, check if same text
            if val_a != val_b
                println("  BOTH REJECTED (different text): $name")
                println("    a: $val_a")
                println("    b: $val_b")
                push!(diffs, name)
            end
        else
            # Bytes differ or one rejected
            println("  DIFFER: $name")
            println("    a: $(val_a[1:8])...")
            println("    b: $(val_b[1:8])...")
            push!(diffs, name)
        end
    end

    println("compare_runs: $(length(all_names)) cases, $(length(diffs)) differ")
    return isempty(diffs) ? 0 : 1
end

# ─────────────────────────────────────────────────────────────────────────────
# CLI dispatcher
# ─────────────────────────────────────────────────────────────────────────────

function main(args::Vector{String})
    if length(args) < 2
        println("Usage:")
        println("  julia test/shadow_compile.jl record <frontend> <out.tsv>")
        println("  julia test/shadow_compile.jl compare <run_a.tsv> <run_b.tsv>")
        return 1
    end

    cmd = args[1]
    if cmd == "record"
        if length(args) < 3
            println("Usage: julia test/shadow_compile.jl record <frontend> <out.tsv>")
            return 1
        end
        frontend_sym = Symbol(args[2])
        out_path = args[3]
        record_frontend(frontend_sym, CASES; out=out_path)
        return 0
    elseif cmd == "compare"
        if length(args) < 3
            println("Usage: julia test/shadow_compile.jl compare <run_a.tsv> <run_b.tsv>")
            return 1
        end
        path_a = args[2]
        path_b = args[3]
        return compare_runs(path_a, path_b)
    else
        println("Unknown command: $cmd")
        return 1
    end
end

exit(main(ARGS))
