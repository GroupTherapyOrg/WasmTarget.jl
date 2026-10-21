#!/usr/bin/env bash
# dev/land_queue.sh — the landing queue: one total order of the lanes' landings, so no two lanes wait
# on each other in a cycle (ledger D13; precedent: bors and GitHub's merge queue, one ordered queue the
# only source of truth for who lands next).
#
#   bash dev/land_queue.sh <queue> <hold> add <lane> <sha>   # appends `<lane> <sha>`, or updates the
#                                                            # lane's sha in place (a lane is queued once)
#   bash dev/land_queue.sh <queue> <hold> may <lane>         # exit 0 when the queue is empty or <lane>
#                                                            # heads it, else 1, saying who is ahead
#   bash dev/land_queue.sh <queue> <hold> head               # the head line, or nothing
#   bash dev/land_queue.sh <queue> <hold> pop <lane>         # removes the lane's line
#   bash dev/land_queue.sh <queue> <hold> list               # the queue, head first
#
# <queue> is the main tree's dev/.loop/QUEUE (git-ignored), one line per lane, `<lane> <sha>`, head
# first; the orchestrator edits it, and a lane appends itself (`bash dev/land.sh wait`). <hold> is the
# machine's hold, dev/.block/HOLD. A head whose lane has not taken a free hold within STALE_S seconds
# (300; LAND_QUEUE_STALE_S) of heading the queue is skipped: its line removed, a note in <queue>.log
# and on stderr; while the hold is held the clock does not run. <queue>.head records the head and the
# time its clock started. Every read and write of the queue holds <queue>.lock.
set -euo pipefail
Q=${1:?usage: dev/land_queue.sh <queue> <hold> add|may|head|pop|list [<lane> [<sha>]]}
H=${2:?hold}; cmd=${3:?command}
STALE_S=${LAND_QUEUE_STALE_S:-300}
mkdir -p "$(dirname "$Q")"; touch "$Q"
L="$Q.lock"
# the lock: a directory holding its owner's pid; one left by a pid that exited is taken over
for _ in $(seq 200); do
    if mkdir "$L" 2>/dev/null; then echo $$ > "$L/pid"; break; fi
    o=$(cat "$L/pid" 2>/dev/null || true)
    [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null && rm -rf "$L"
    sleep 0.05
done
[ "$(cat "$L/pid" 2>/dev/null)" = $$ ] || { echo "land_queue: $L is held — refusing"; exit 2; }
trap 'rm -rf "$L"' EXIT
now=$(date +%s)
held() { local o; [ -e "$H" ] || return 1; o=$(cut -d' ' -f1 "$H" 2>/dev/null || true)
         [ "$o" = 0 ] || { [ -n "$o" ] && kill -0 "$o" 2>/dev/null; }; }
# the head after stale heads are skipped: its clock restarts when the head changes or the hold is held
settle() {
    local hl hs l s
    while read -r l s < <(head -n 1 "$Q"); [ -n "${l:-}" ]; do
        hl=""; hs=0; [ -f "$Q.head" ] && read -r hl hs < "$Q.head"
        if held || [ "$hl" != "$l" ]; then echo "$l $now" > "$Q.head"; return 0; fi
        [ $((now - hs)) -le "$STALE_S" ] && return 0
        local note="$(date -u +%Y-%m-%dT%H:%M:%SZ) skipped $l $s: its lane took no free hold within $STALE_S s of heading the queue"
        echo "$note" >> "$Q.log"; echo "land_queue: $note" >&2
        tail -n +2 "$Q" > "$Q.new"; mv "$Q.new" "$Q"
    done
    rm -f "$Q.head"
}
case "$cmd" in
add)
    lane=${4:?lane}; sha=${5:?sha}
    if awk -v l="$lane" '$1 == l { f = 1 } END { exit !f }' "$Q"; then
        awk -v l="$lane" -v s="$sha" '$1 == l { $2 = s } { print }' "$Q" > "$Q.new"; mv "$Q.new" "$Q"
    else
        echo "$lane $sha" >> "$Q"
    fi
    settle ;;
may)
    lane=${4:?lane}; settle
    read -r l s < <(head -n 1 "$Q") || true
    [ -z "${l:-}" ] || [ "$l" = "$lane" ] && exit 0
    pos=$(awk -v l="$lane" '$1 == l { print NR - 1; exit }' "$Q")
    if [ -n "$pos" ]; then where="$pos behind it"; else where="not queued: bash dev/land.sh wait queues it"; fi
    echo "$l ${s:0:8} heads the landing queue; $lane is $where"
    exit 1 ;;
head) settle; head -n 1 "$Q" ;;
pop)
    lane=${4:?lane}
    awk -v l="$lane" '$1 != l' "$Q" > "$Q.new"; mv "$Q.new" "$Q"
    settle ;;
list) settle; cat "$Q" ;;
*) echo "land_queue: unknown command $cmd"; exit 2 ;;
esac
