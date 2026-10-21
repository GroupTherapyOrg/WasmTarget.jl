# Lock negatives: each case plants one mutation in a scratch checkout of this commit, runs the one lock
# that guards it there, sees it fire, and restores the file; then every lock the cases name holds again
# on the restored checkout. A lock counts only once it fires when broken (AGENTS.md), and the check
# lives in the tree, run by the blocking gate's tests stage whenever this file changes.
using Test

const _LN_ROOT = normpath(joinpath(@__DIR__, ".."))

# (lock, path, planted text, its replacement, what the plant breaks)
const LOCK_NEGATIVE_CASES = [
    ("L195", "dev/block.jl",
     "    occursin(Regex(\"^\\\\| \" * replace(m[1], \".\" => \"\\\\.\") * \" \\\\|\", \"m\"), base_march) &&",
     "    false &&",
     "a Timing line citing a row the base already has exempts again (A20P26)"),
    ("L195", "dev/block.jl",
     "    all(r -> r.factor <= CALIBRATION_FACTOR, runs) ||\n",
     "    true ||\n",
     "the update records from runs the calibration in force reads past 1.05 (A28E1)"),
    ("L195", "dev/block.jl",
     "        gitok(\"merge-base\", \"--is-ancestor\", m[1], landed_ref()) ||\n",
     "        true ||\n",
     "a best's source may name a commit origin's march branch does not hold (A28E1)"),
    ("L195", "dev/block.jl",
     "    n == UPDATE_RUNS || return",
     "    true || return",
     "one record passes as a best's source (A20P25)"),
    ("L195", "dev/block.jl",
     "        if !haskey(out, k) || w < out[k] || k in rerecord\n",
     "        if !haskey(out, k) || w < out[k]\n",
     "a best with no source is re-recorded only when lower (A20P25)"),
    ("L195", "dev/timing_best.toml",
     "\"probes@warm\" = \"one run, record 850ac1fb-3 on 963425c6 at machine factor 1.14\"\n",
     "",
     "a best with no [best_from] entry (A20P20)"),
    ("L195", "dev/block.jl",
     "how === :median && return \"the median of \$src\"",
     "how === :median && return \"median of \$src\"",
     "a best's source loses its form (A20P20)"),
]

@testset "lock negatives: each planted mutation fires its lock" begin
    local tmp = mktempdir()
    local head = readchomp(`git -C $_LN_ROOT rev-parse HEAD`)
    run(`git clone -q --shared --no-checkout $_LN_ROOT $tmp`)
    run(`git -C $tmp checkout -q --detach $head`)
    local was = get(ENV, "WT_RATCHET_INCLUDED", nothing)
    ENV["WT_RATCHET_INCLUDED"] = "1"
    local M = Module(:LockNegatives)
    try
        Base.include(M, joinpath(tmp, "test", "parity_ratchet.jl"))
    finally
        was === nothing ? delete!(ENV, "WT_RATCHET_INCLUDED") : (ENV["WT_RATCHET_INCLUDED"] = was)
    end
    local locks = Base.invokelatest(getglobal, getglobal(M, :ParityRatchet), :LOCKS)
    lock_fn(id) = only(last(last(p)) for p in locks if startswith(first(p), id * "_"))
    for (id, path, old, new, why) in LOCK_NEGATIVE_CASES
        @testset "$id fires: $why" begin
            local f = joinpath(tmp, path)
            local orig = read(f, String)
            @test count(old, orig) == 1   # the plant's target is in this commit, once
            write(f, replace(orig, old => new; count = 1))
            local v = try
                Base.invokelatest(lock_fn(id))
            finally
                write(f, orig)
            end
            @test v > 0
        end
    end
    @testset "restored: $id holds" for id in unique(first.(LOCK_NEGATIVE_CASES))
        @test Base.invokelatest(lock_fn(id)) == 0
    end
    rm(tmp; recursive = true, force = true)
end
