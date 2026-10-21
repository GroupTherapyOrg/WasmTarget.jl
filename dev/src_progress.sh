#!/usr/bin/env bash
# dev/src_progress.sh — the rebuild's src progress, which `dev/land.sh land` prints after every landing
# (L208; dev/LEDGER.md D40, Dale 2026-10-21: "how are things going? still in setup or actually building
# the src code??"). One source: land prints this line and L208 runs this program.
#
#   bash dev/src_progress.sh                      this tree: the parity( anchors under src/ and the
#                                                 landings (commits) since src/ last changed
#   bash dev/src_progress.sh <anchors> <since>    the line for planted numbers (L208's negative)
#
# Until legacy/ exists, src/ is still WT1's (1.A2c moves it), so the rebuild's src counts 0 anchors
# and every landing since the rebuild began (REBUILD_START) is a src-less one. The in-scope total of
# dart definitions is 1.A3's to define; the line names it once it exists.
# Intent: a status leads with src progress, so setup never passes for building. Band: from the
# NOTE_AFTER-th consecutive landing that changes nothing under src/, a note, never a failure.
set -euo pipefail
NOTE_AFTER=5
REBUILD_START=e2371eca08605231256dd5f3ee97609d6fc019a4   # chore(land): the march branch is wt2
cd "$(git rev-parse --show-toplevel)"
started=1
if [ $# -eq 2 ]; then
    anchors=$1; since=$2
else
    if [ -d legacy ]; then
        anchors=$(grep -rho 'parity(' src --include='*.jl' 2>/dev/null | wc -l | tr -d ' ')
        last=$(git log -1 --format=%H -- src)
    else
        anchors=0; last=$REBUILD_START; started=0
    fi
    since=$(git rev-list --count --no-merges "$last"..HEAD)
fi
line="src: $anchors parity( anchors under src/ (the in-scope total: 1.A3's, not yet defined); $since landing(s) since src/ last changed"
[ $started -eq 1 ] || line="$line (the rebuild's src/ not started: WT1 holds src/ until 1.A2c)"
echo "$line"
if [ "$since" -ge "$NOTE_AFTER" ]; then
    echo "src: note: $since consecutive landings changed nothing under src/; the rebuild needs a lane porting compiler src (D40)"
fi
exit 0
