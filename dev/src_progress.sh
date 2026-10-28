#!/usr/bin/env bash
# dev/src_progress.sh — the rebuild's src progress, which `dev/ship.sh` prints after every landing
# (L208; dev/LEDGER.md D40, Dale 2026-10-21: "how are things going? still in setup or actually building
# the src code??"). One source: L208 runs this program in the landing's check, and ship prints its line.
#
#   bash dev/src_progress.sh                      this tree: the dart definitions src/ ports, read
#                                                 from WasmTarget's @parity registry (A35S1), and the
#                                                 landings (commits) since src/ last changed
#   bash dev/src_progress.sh <anchored> <ported> <since>   the line for planted numbers (L208's negative)
#
# Until legacy/ exists, src/ is still WT1's (1.A2c moves it), so the rebuild's src counts none and
# every landing since the rebuild began (REBUILD_START) is a src-less one. An anchored definition is
# a dart definition dev/skeleton.jl counts in scope (several Julia definitions may name one: a struct
# and its constructor; an enum's values and a field's accessors are parts of theirs), a ported one a
# counted definition src fills with no @unported stub left at its anchor; the generator anchors every
# in-scope definition (its `diff`), so the anchored count is its total.
# Intent: a status leads with src progress, so setup never passes for building. Band: from the
# NOTE_AFTER-th consecutive landing that changes nothing under src/, a note, never a failure.
set -euo pipefail
NOTE_AFTER=5
REBUILD_START=e2371eca08605231256dd5f3ee97609d6fc019a4   # chore(land): the march branch is wt2
cd "$(git rev-parse --show-toplevel)"
started=1
if [ $# -eq 3 ]; then
    anchored=$1; ported=$2; since=$3
else
    if [ -d legacy ]; then
        # the worktree's private depot (dev/depot.sh), never the shared compiled cache another tree can
        # replace mid-run; and every entry of the package's modules (WasmBuilder, Dart2Wasm and theirs),
        # not the root module's alone, where no port lives
        . dev/depot.sh; wt_depot_export "$PWD"
        # the anchored count is the generator's in-scope total, each definition dev/skeleton.jl counts
        # (an enum's values and a field's accessors are parts of their definition, not more); a ported
        # one is a counted anchor src fills, no @unported entry left at it
        counts=$(julia --project=. --startup-file=no -e 'using WasmTarget
            include("dev/skeleton.jl")
            S = Skeleton.read_scope()
            counted = Set(Skeleton.anchor(f, d) for f in Skeleton.scope() for d in S.decls[f] if Skeleton.counted(d))
            e = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget) && x.anchor in counted]
            stubbed = Set(x.anchor for x in e if !x.ported)
            println(length(counted), " ", length(setdiff(Set(x.anchor for x in e), stubbed)))') ||
            { echo "src: WasmTarget did not load, so its @parity registry gives no count"; exit 1; }
        read -r anchored ported <<< "$counts"
        last=$(git log -1 --format=%H -- src)
    else
        anchored=0; ported=0; last=$REBUILD_START; started=0
    fi
    since=$(git rev-list --count --no-merges "$last"..HEAD)
fi
line="src: $ported of $anchored anchored dart definitions ported (every definition of each dart file src loads, dev/skeleton.jl); $since landing(s) since src/ last changed"
[ $started -eq 1 ] || line="$line (the rebuild's src/ not started: WT1 holds src/ until 1.A2c)"
echo "$line"
if [ "$since" -ge "$NOTE_AFTER" ]; then
    echo "src: note: $since consecutive landings changed nothing under src/; the rebuild needs a lane porting compiler src (D40)"
fi
exit 0
