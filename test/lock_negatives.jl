# Lock negatives: each case plants one mutation in a scratch checkout of this commit, runs the one lock
# that guards it there, sees it fire, and restores the file; then every lock the cases name holds again
# on the restored checkout. A lock counts only once it fires when broken (AGENTS.md), and the check
# lives in the tree, run by the blocking gate's tests stage whenever this file changes.
using Test

const _LN_ROOT = normpath(joinpath(@__DIR__, ".."))

# (lock, path, planted text or a Regex matching it, its replacement, what the plant breaks)
const LOCK_NEGATIVE_CASES = [
    ("L195", "dev/block.jl",
     "    occursin(Regex(\"^\\\\| \" * replace(m[1], \".\" => \"\\\\.\") * \" \\\\|\", \"m\"), base_march) &&",
     "    false &&",
     "a Timing line citing a row the base already has exempts again (A20P26)"),
    ("L195", "dev/block.jl",
     "    n == UPDATE_RUNS || return",
     "    true || return",
     "one record passes as a best's source (A20P25)"),
    ("L195", "dev/block.jl",
     "        if !haskey(out, k) || w < out[k] || k in rerecord\n",
     "        if !haskey(out, k) || w < out[k]\n",
     "a best with no source is re-recorded only when lower (A20P25)"),
    # the [best_from] line by its best's name, whatever source an update last wrote into it (21e36053's
    # re-record replaced the literal this plant named, and nothing ran the plant until this file changed)
    ("L195", "dev/timing_best.toml",
     r"^\"probes@warm\" = \"[^\"\n]*\"\n"m,
     "",
     "a best with no [best_from] entry (A20P20)"),
    ("L195", "dev/block.jl",
     "how === :median && return \"the median of \$src\"",
     "how === :median && return \"median of \$src\"",
     "a best's source loses its form (A20P20)"),
    ("L197", "dev/loop_excuse.sh",
     "return (c - m > t || m - c > t)",
     "return 0",
     "a hand excuse's numbers no longer held to its landing's steps (A25E2)"),
    ("L197", "dev/loop_excuse.sh",
     "        if (e2l <= target || own > target) exit",
     "        exit",
     "an excuse its steps measure is never written, so a hand line is still needed (A25E1)"),
    ("L197", "dev/loop_excuse.sh",
     "        if (e2l <= target || own > target) exit",
     "        if (e2l <= target) exit",
     "a wait no step measures is excused with no hand line (A25E1)"),
    ("L153", "dev/land.sh",
     raw"    echo \"landed $br @ ${head:0:8} on $MARCH\"",
     raw"    git push -q --force origin \"$head:refs/heads/march/$leaf\"" * "\n" * raw"    echo \"landed $br @ ${head:0:8} on $MARCH\"",
     "a landing pushes a second ref beside the march branch (Dale 2026-10-21: no march/<branch> per landing)"),
    ("L197", "dev/land.sh",
     "        ex=\$(bash dev/loop_excuse.sh write",
     "        ex=\$(true",
     "land no longer writes the previous landing's measured excuse (A25E1)"),
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
    # L197 reads the landing machine's log (the main tree's dev/.loop), which this scratch clone, like a
    # CI checkout, does not have: it runs as on CI, its behavior on fixed text the part its plants break
    runlock(id) = id == "L197" ? withenv(() -> Base.invokelatest(lock_fn(id)), "GITHUB_ACTIONS" => "true") :
                                 Base.invokelatest(lock_fn(id))
    for (id, path, old, new, why) in LOCK_NEGATIVE_CASES
        @testset "$id fires: $why" begin
            local f = joinpath(tmp, path)
            local orig = read(f, String)
            @test count(old, orig) == 1   # the plant's target is in this commit, once
            write(f, replace(orig, old => new; count = 1))
            local v = try
                runlock(id)
            finally
                write(f, orig)
            end
            @test v > 0
        end
    end
    @testset "restored: $id holds" for id in unique(first.(LOCK_NEGATIVE_CASES))
        @test runlock(id) == 0
    end
    rm(tmp; recursive = true, force = true)
end
