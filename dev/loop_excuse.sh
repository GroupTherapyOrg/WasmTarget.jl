#!/usr/bin/env bash
# dev/loop_excuse.sh — an excuse file held to its landing's measured steps (L197, A25E2).
#
#   bash dev/loop_excuse.sh check <landings.tsv> <steps.tsv> <sha8> <excuse file>
#       L197 runs it on every excuse file (dev/.loop/excuse/<sha8>, which lifts a red timing's debt,
#       L198; waits need none, A30E1: L197 judges a landing's own mechanics and reports its waits apart):
#       prints what is wrong with it, a sentence each, against the landing's line and steps (nothing when
#       the landing has no steps: it landed before steps.tsv). A line "measured by dev/land.sh land:"
#       (written by land until A30E1) has every step it names as steps.tsv measured it, its refusal inside
#       the commit-to-start span, and leaves at most the target of its own; a hand line has the numbers it
#       shares with steps.tsv as measured (`waited N s`: the hold and the time from the commit to the
#       landing's start; `N s waiting on the hold`; `hold|runner|gate-<k>|judge-<k> N s`), within 10 per
#       cent (at least 0.5 s).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# the one target, L197's literal (test/parity_ratchet.jl), and the gate's total budget
TARGET=$(sed -n 's/^const L197_TARGET = \([0-9][0-9]*\) .*/\1/p' "$ROOT/test/parity_ratchet.jl")
BUDGET=$(sed -n 's/^"total" = \([0-9][0-9]*\)$/\1/p' "$ROOT/dev/timing_best.toml" | head -1)
[ -n "$TARGET" ] && [ -n "$BUDGET" ] || { echo "loop_excuse: no L197_TARGET or total budget in this tree"; exit 2; }
# the check: the landing log (ARGV[1]), steps.tsv (ARGV[2]), then the excuse's text
EXCUSE_AWK='
function epoch(s,   y, mo, d, era, yoe, doe) {
    y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (mo <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
    return (era * 146097 + doe - 719468) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
}
function fmt(v) { return sprintf("%.1f", v) }
function far(c, m,   t) { t = (m * 0.1 > 0.5) ? m * 0.1 : 0.5; return (c - m > t || m - c > t) }
function num(c,   w, n) { n = split(c, w, " "); return w[n - 1] + 0 }
BEGIN { FS = "\t"; RUNNER_START_S = 10 }
FILENAME == ARGV[1] { if (index($2, sha) == 1) { found = 1; au = epoch($3); ls = epoch($4); e2l = $8 + 0; red = ($11 ~ /^(SLOWER|OVER|FAILED)/) } next }
FILENAME == ARGV[2] { if (index($1, sha) == 1) { nst++; st[$2] = $3 + 0; if ($2 ~ /^gate-[0-9]+$/ && substr($2, 6) + 0 > ng) ng = substr($2, 6) + 0 } next }
{ x = x $0; next }
END {
    auto = (x ~ /measured by dev\/land\.sh land:/)
    if (!found || !nst) {
        if (auto) print (found ? "steps.tsv holds no steps of it" : "the landing log holds no line of it") ": a measured line needs them"
        exit
    }
    hold = st["hold"] + 0; run = st["runner"] + 0
    gate = 0
    for (k = 1; k < ng; k++) gate += st["gate-" k]
    if (ng > 0 && st["gate-" ng] > budget) gate += st["gate-" ng] - budget
    machine = (run > RUNNER_START_S ? run : 0) + gate
    # check: every step a line names with its seconds, as steps.tsv measured it
    s = x
    while (match(s, /(^|; |[^A-Za-z0-9_-])((hold|runner) |(gate|judge)-[0-9]+ )[0-9]+(\.[0-9]+)? s([^A-Za-z]|$)/)) {
        c = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH - 1)
        # the words hold and runner name a step only at the start of the line or after "; ", as land writes them
        if (c ~ /^[^;](hold|runner) /) continue
        sub(/^(; |[^a-z])/, "", c); sub(/ s.?$/, " s", c); split(c, w, " ")
        if (!(w[1] in st)) print "\"" c "\": steps.tsv measured no step " w[1] " of it"
        else if (far(w[2] + 0, st[w[1]])) print "\"" c "\", where steps.tsv measured " w[1] " " fmt(st[w[1]]) " s: more than 10 per cent apart"
    }
    s = x
    while (match(s, /(^|[^A-Za-z])waited [0-9]+(\.[0-9]+)? s([^A-Za-z]|$)/)) {
        c = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH - 1)
        sub(/^[^a-z]/, "", c); sub(/ s.?$/, " s", c)
        if (far(num(c), hold + ls - au)) print "\"" c "\", where the landing waited " fmt(hold + ls - au) " s (the hold " fmt(hold) " s, steps.tsv, and " fmt(ls - au) " s from its commit to its land start, the landing log): more than 10 per cent apart"
    }
    s = x
    while (match(s, /[0-9]+(\.[0-9]+)? s (of its [0-9]+(\.[0-9]+)? s )?waiting on the (one )?hold/)) {
        c = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        split(c, w, " ")
        if (far(w[1] + 0, hold)) print "\"" c "\", where steps.tsv measured the hold " fmt(hold) " s: more than 10 per cent apart"
    }
    if (auto) {
        if (red) print "a measured line for a landing whose timing was judged red: it would lift the timing debt (L198), which only a hand line naming its cause or a judged green run does"
        if (match(x, /edit to landed [0-9]+(\.[0-9]+)? s/)) {
            c = substr(x, RSTART, RLENGTH)
            if (far(num(c), e2l)) print "\"" c "\", where the landing log measured " fmt(e2l) " s"
        } else print "a measured line names no edit to landed"
        slot = 0
        if (match(x, /since record [^ ]+ refused it on [^;]* at [0-9][0-9-]*T[0-9:]*Z/)) {
            c = substr(x, RSTART, RLENGTH); si = epoch(substr(c, length(c) - 19))
            if (si < au || si > ls) print "\"" c "\": the refusal lies outside its commit-to-start span (the landing log)"
            else slot = ls - si
            if (match(x, /before land [0-9]+(\.[0-9]+)? s/)) {
                c = substr(x, RSTART, RLENGTH)
                if (far(num(c), slot)) print "\"" c "\", where its refusal to its land start measures " fmt(slot) " s"
            }
        } else if (x ~ /before land /) print "a measured line names a wait before its land with no refusal"
        own = e2l - slot - hold - machine
        if (match(x, /its own [0-9]+(\.[0-9]+)? s/)) {
            c = substr(x, RSTART, RLENGTH)
            if (num(c) < own - 0.5) print "\"" c "\", where its measured causes leave " fmt(own) " s of its own"
        } else print "a measured line names no time of its own"
        if (own > target) print "its measured causes leave " fmt(own) " s of its own, over the " target " s target"
    }
}'
cmd=${1:?usage: dev/loop_excuse.sh check <log> <steps> <sha8> <file>}
case "$cmd" in
check)
    [ -f "$2" ] && [ -f "$3" ] || exit 0
    awk -v sha="$4" -v target="$TARGET" -v budget="$BUDGET" "$EXCUSE_AWK" "$2" "$3" "$5"
    ;;
*) echo "loop_excuse: unknown command $cmd"; exit 2 ;;
esac
