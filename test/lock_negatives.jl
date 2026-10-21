# Lock negatives: each case plants one mutation in a scratch checkout of this commit, runs the one lock
# that guards it there, sees it fire, and restores the file; then every lock the cases name holds again
# on the restored checkout. A lock counts only once it fires when broken (AGENTS.md), and the check
# lives in the tree, run by the blocking gate's tests stage whenever this file changes.
using Test

const _LN_ROOT = normpath(joinpath(@__DIR__, ".."))

# (lock, path, planted text or a Regex matching it, its replacement, what the plant breaks)
const LOCK_NEGATIVE_CASES = [
    ("L194", "dev/land.sh",
     raw"    if [ -n \"$(git diff --name-only \"$tip\" HEAD -- legacy/)\" ] && [ -n \"$(git log -1 --format=%H \"$tip\" -- legacy)\" ] && [ -n \"$(git ls-tree -d HEAD legacy)\" ]; then",
     "    if false; then",
     "an edit to legacy/ lands: WT1, the agreement oracle, is no longer frozen (dev/MARCH.md 1.G)"),
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
    ("L197", "dev/land.sh",
     raw"    ks=$(bash dev/kaimon_session.sh \"$W\")",
     raw"    ks=$(true)",
     "land lands from a worktree with no live Kaimon session"),
    ("L197", "dev/kaimon_session.sh",
     "    if not p or os.path.realpath(p) != wt:\n",
     "    if not p:\n",
     "a Kaimon session of another tree counts as the worktree's"),
    ("L197", "dev/land.sh",
     raw"\"$start\" \"${LAND_HOLD_WAIT:-0}\" \"${LAND_OWN_RED:-0}\")",
     raw"\"$start\" 0 \"${LAND_OWN_RED:-0}\")",
     "a landing's own time counts its wait for another landing's hold (A30E1)"),
    ("L197", "dev/land.sh",
     "if (k[i] == \"own\") t += ",
     "if (1) t += ",
     "a red on L197 alone counts as the change's own time (A33E4)"),
    ("L197", "dev/land.sh",
     "               gate_state=cold-after-warm\n",
     "               gate_state=cold\n",
     "a cold gate after a warm-up of the change is no longer told apart"),
    ("L197", "dev/block_runner.jl",
     "        istaskfailed(task) || (ran_on[key] = version[])\n",
     "        ran_on[key] = version[]\n",
     "a killed warm-up counts its check as warm"),
    ("L197", "dev/loop_excuse.sh",
     "return (c - m > t || m - c > t)",
     "return 0",
     "a hand excuse's numbers no longer held to its landing's steps (A25E2)"),
    ("L194", "dev/block.jl",
     "    e.head === :macrocall && length(e.args) == 4 && e.args[1] == GlobalRef(Core, Symbol(\"@doc\")) ? drop_docs(e.args[4]) :",
     "    false ? drop_docs(e.args[4]) :",
     "a docstring's change counts as a change of code, so a docstring edit moves a piece (A30E5)"),
    ("L148", "dev/audit_window.sh",
     "CAP=5\n",
     "CAP=6\n",
     "the audit window takes a sixth commit, so land's preflight lands into a full window"),
    ("L148", "dev/audit_window.sh",
     raw"            text=$otext" * "\n",
     "            :\n",
     "land's preflight reads origin's last entry for a landing that adds the next one, so a full window refuses the audit entry that empties it (A31E1)"),
    ("L148", "dev/land.sh",
     raw"    if ! win=$(bash dev/audit_window.sh \"$W\" \"origin/$MARCH\"",
     raw"    if ! win=$(true \"$W\" \"origin/$MARCH\"",
     "land no longer reads the audit window before its hold"),
    ("L153", "dev/land.sh",
     raw"    echo \"landed $br @ ${head:0:8} on $MARCH\"",
     raw"    git push -q --force origin \"$head:refs/heads/march/$leaf\"" * "\n" * raw"    echo \"landed $br @ ${head:0:8} on $MARCH\"",
     "a landing pushes a second ref beside the march branch (Dale 2026-10-21: no march/<branch> per landing)"),
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
