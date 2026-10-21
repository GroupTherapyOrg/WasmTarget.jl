#!/usr/bin/env bash
# dev/audit_window.sh — L148's audit window, one program for the ratchet and `dev/land.sh land`.
#
#   bash dev/audit_window.sh <repo>                    # the ratchet (L148): <repo>'s dev/AUDIT.md, to HEAD
#   bash dev/audit_window.sh <repo> <rev> <extra>      # land's preflight: <rev>'s dev/AUDIT.md, to <rev>,
#                                                      # plus <extra> commits (the landing's own)
#
# The last dev/AUDIT.md entry (a `## ` heading) that names the commit it was "audited through", the
# commits past it, merges not counted, and the window's cap: prints "<sha> <count> <cap> <entries>"
# (<entries> the number of `## ` entries, so the next audit is number <entries> + 1). Exits 0 when
# <count> is at most <cap>, 1 when the window is full past it, 2 when no entry names an audited
# commit or that commit is not an ancestor of the counted head (L148 counts that apart, A2P5).
set -euo pipefail
CAP=5
repo=${1:?usage: dev/audit_window.sh <repo> [<rev> <extra>]}
rev=${2:-}
extra=${3:-0}
if [ -z "$rev" ]; then
    text=$(cat "$repo/dev/AUDIT.md")
    head=HEAD
else
    text=$(git -C "$repo" show "$rev:dev/AUDIT.md")
    head=$rev
fi
# each entry's first "audited through <sha>", the last entry naming one wins (L148's reading)
read -r sha entries < <(printf '%s\n' "$text" | awk '
    /^## / { e++; got = 0 }
    e > 0 && !got && match($0, /audited through [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*/) {
        s = substr($0, RSTART + 16, RLENGTH - 16); if (length(s) <= 40) { last = s; got = 1 } }
    END { print (last == "" ? "-" : last), e + 0 }')
[ "$sha" != - ] || { echo "- 0 $CAP $entries"; exit 2; }
git -C "$repo" merge-base --is-ancestor "$sha" "$head" 2>/dev/null || { echo "$sha 0 $CAP $entries"; exit 2; }
count=$(( $(git -C "$repo" rev-list --count --no-merges "$sha..$head") + extra ))
echo "$sha $count $CAP $entries"
[ "$count" -le "$CAP" ]
