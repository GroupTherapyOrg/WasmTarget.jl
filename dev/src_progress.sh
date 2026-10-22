#!/usr/bin/env bash
# dev/src_progress.sh — the rebuild's src progress, which `dev/land.sh land` prints after every landing
# (L208; dev/LEDGER.md D40, Dale 2026-10-21: "how are things going? still in setup or actually building
# the src code??"). One source: land prints this line and L208 runs this program.
#
#   bash dev/src_progress.sh                      this tree: the dart definitions src/ ports, read
#                                                 from WasmTarget's @parity registry (A35S1), and the
#                                                 landings (commits) since src/ last changed
#   bash dev/src_progress.sh <anchored> <ported> <since>   the line for planted numbers (L208's negative)
#
# Until legacy/ exists, src/ is still WT1's (1.A2c moves it), so the rebuild's src counts none and
# every landing since the rebuild began (REBUILD_START) is a src-less one. An anchored definition is
# an @parity entry, a ported one an entry that is no @unported stub; the in-scope total of dart
# definitions is 1.A4's generator's to define; the line names it once it exists.
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
        counts=$(julia --project=. --startup-file=no -e 'using WasmTarget
            e = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget)]
            println(length(e), " ", count(x -> x.ported, e))') ||
            { echo "src: WasmTarget did not load, so its @parity registry gives no count"; exit 1; }
        read -r anchored ported <<< "$counts"
        last=$(git log -1 --format=%H -- src)
    else
        anchored=0; ported=0; last=$REBUILD_START; started=0
    fi
    since=$(git rev-list --count --no-merges "$last"..HEAD)
fi
line="src: $ported of $anchored anchored dart definitions ported (the in-scope total: 1.A4's, not yet defined); $since landing(s) since src/ last changed"
[ $started -eq 1 ] || line="$line (the rebuild's src/ not started: WT1 holds src/ until 1.A2c)"
echo "$line"
if [ "$since" -ge "$NOTE_AFTER" ]; then
    echo "src: note: $since consecutive landings changed nothing under src/; the rebuild needs a lane porting compiler src (D40)"
fi
exit 0
