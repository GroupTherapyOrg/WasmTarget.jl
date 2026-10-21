#!/usr/bin/env bash
# dev/loop_excuse.sh — a slower landing's excuse measured, never asserted (L197; A25E1, A25E2).
#
#   bash dev/loop_excuse.sh write <landings.tsv> <steps.tsv> <commit> <dir> [<record.toml> ...]
#       `dev/land.sh land` runs it for the previous landing before its gate: when the landing took longer
#       than L197's target from its edit, and the causes outside its change, measured, bring it within the
#       target, it writes the one line to <dir>/<sha8> and prints it; otherwise nothing, and nothing for
#       a landing whose timing was judged red (an excuse file lifts that debt too, L198). The causes:
#         hold    the wait for the one hold (steps.tsv's step `hold`)
#         runner  a runner started for the landing (step `runner` past RUNNER_START_S)
#         gate    the gate runs `land` made again (a cold run with a judged run owed, a run with no
#                 verdict: every gate-<k> but the last) and the last run's wall past the gate's total
#                 budget (dev/timing_best.toml), which a green run has only when it was cold or the
#                 machine past the factor cap; the records of those runs named with their runner state
#                 and machine factor
#         before  the time from an earlier tree of the same change (its author time, author and
#                 subject) refused by the gate on L148 or L197 alone, a red record whose failed checks
#                 are the ratchet's and whose broken locks are those two (the audit window, the loop
#                 window: outside the change), to the landing's start
#   bash dev/loop_excuse.sh check <landings.tsv> <steps.tsv> <sha8> <excuse file>
#       L197 runs it on every excuse file: prints what is wrong with it, a sentence each, against the
#       landing's line and steps (nothing when the landing has no steps: it landed before steps.tsv).
#       A measured line ("measured by dev/land.sh land:") has every step it names as steps.tsv measured
#       it, its refusal inside the commit-to-start span, and leaves at most the target of its own; a
#       hand line has the numbers it shares with steps.tsv as measured (`waited N s`: the hold and the
#       time from the commit to the landing's start; `N s waiting on the hold`; `hold|runner|gate-<k>|
#       judge-<k> N s`), within 10 per cent (at least 0.5 s), and is refused where steps.tsv alone
#       measures the landing within its target: `land` writes that excuse itself.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# the one target, L197's literal (test/parity_ratchet.jl), and the gate's total budget
TARGET=$(sed -n 's/^const L197_TARGET = \([0-9][0-9]*\) .*/\1/p' "$ROOT/test/parity_ratchet.jl")
BUDGET=$(sed -n 's/^"total" = \([0-9][0-9]*\)$/\1/p' "$ROOT/dev/timing_best.toml" | head -1)
[ -n "$TARGET" ] && [ -n "$BUDGET" ] || { echo "loop_excuse: no L197_TARGET or total budget in this tree"; exit 2; }
# the measurement and its check, one program: the landing log (ARGV[1]), steps.tsv (ARGV[2]), then the
# facts `write` gathers (R: a refusal, A: a gate run's record) or the excuse's text (`check`)
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
mode == "write" && $1 == "R" { if (r == "" || $4 + 0 < rs) { r = $2; rl = $3; rs = $4 + 0; ri = $5 } next }
mode == "write" && $1 == "A" { na++; ann[na] = " (record " $3 ", " $4 ", factor " $5 ")"; next }
mode == "check" { x = x $0; next }
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
    if (mode == "write") {
        # an excuse file also lifts a red timing debt (L198): a measured line never does, so none is
        # written for a landing whose timing was judged red
        if (red) exit
        slot = (r != "" && rs <= ls) ? ls - (rs > au ? rs : au) : 0
        own = e2l - slot - hold - machine
        if (e2l <= target || own > target) exit
        line = ((slot + hold >= machine) ? "lock" : "machine") ": measured by dev/land.sh land: edit to landed " fmt(e2l) " s"
        if (slot > 0) line = line "; before land " fmt(slot) " s since record " r " refused it on " rl " at " ri
        line = line "; hold " fmt(hold) " s; runner " fmt(run) " s" (run > RUNNER_START_S ? " (a runner started)" : "")
        for (k = 1; k <= ng; k++) {
            line = line "; gate-" k " " fmt(st["gate-" k]) " s" (na == ng ? ann[k] : "")
            if (k < ng) line = line " run again"
            else if (st["gate-" k] > budget) line = line ", " fmt(st["gate-" k] - budget) " s past the " budget " s budget"
        }
        print line "; its own " fmt(own) " s of the " target " s target"
        exit
    }
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
    } else if (e2l > target && e2l - hold - machine <= target)
        print "measurable from steps.tsv (the hold " fmt(hold) " s, a runner start and gate runs past the budget " fmt(machine) " s leave " fmt(e2l - hold - machine) " s of its own): dev/land.sh land writes this excuse itself, a hand line excuses only a cause steps.tsv cannot measure"
}'
# each record's top-level fields, one line per record: path, verdict, finished, its gate run's start,
# head, checks_failed, timing_failed, logs, runner_state, machine_factor
REC_AWK='
function out(   q) {
    q = "\""; gsub(q, "", v["verdict"]); gsub(q, "", v["head"]); gsub(q, "", v["logs"]); gsub(q, "", v["runner_state"])
    printf "%s\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n", f, v["verdict"], v["finished"] + 0, v["finished"] - v["total_wall"], v["head"], v["checks_failed"], v["timing_failed"], v["logs"], v["runner_state"], v["machine_factor"]
}
FNR == 1 { if (f != "") out(); f = FILENAME; sec = 0; split("", v) }
/^\[/ { sec = 1 }
!sec && index($0, " = ") { v[substr($0, 1, index($0, " = ") - 1)] = substr($0, index($0, " = ") + 3) }
END { if (f != "") out() }'
epoch() { perl -MTime::Local=timegm -e '@a = $ARGV[0] =~ /(\d+)/g; print timegm($a[5], $a[4], $a[3], $a[2], $a[1] - 1, $a[0])' "$1"; }
iso() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($ARGV[0])), "\n"' "$1"; }
recid() { local b; b=$(basename "$1" .toml); echo "${b:0:8}-${b##*-}"; }

cmd=${1:?usage: dev/loop_excuse.sh write <log> <steps> <commit> <dir> [records…] | check <log> <steps> <sha8> <file>}
case "$cmd" in
write)
    log=$2; steps=$3; sha=$4; dir=$5; shift 5
    [ -f "$log" ] && [ -f "$steps" ] || exit 0
    line=$(awk -F'\t' -v s="$sha" '$2 == s { print $1, $3, $4 }' "$log" | tail -1)
    [ -n "$line" ] || exit 0
    read -r la au ls <<<"$line"
    la=$(epoch "$la"); au=$(epoch "$au"); ls=$(epoch "$ls")
    # the change, as git names it across rebases: its author time, author and subject
    want=$(git log -1 --format='%at %ae %s' "$sha" 2>/dev/null || true)
    tree=$(git rev-parse -q --verify "$sha^{tree}" 2>/dev/null || true)
    facts=$(mktemp); found=$(mktemp)
    if [ $# -gt 0 ] && [ -n "$want" ]; then
        awk "$REC_AWK" "$@" | while IFS=$'\t' read -r f verdict fin start head chk tfl logs state factor; do
            case $(basename "$f") in
            "$tree"-*) [ "$fin" -ge "$ls" ] && [ "$fin" -le "$la" ] && printf 'A\t%s\t%s\t%s\t%s\n' "$fin" "$(recid "$f")" "$state" "$factor" ;;
            esac
            [ "$verdict" = red ] && [ "$chk" = '["ratchet"]' ] && [ "$tfl" = '[]' ] && [ "$start" -ge "$au" ] && [ "$start" -le "$ls" ] || continue
            [ "$(git log -1 --format='%at %ae %s' "$head" 2>/dev/null || true)" = "$want" ] || continue
            locks=$(grep '❌' "${f%/dev/.block/*}/$logs/ratchet.log" 2>/dev/null | awk '{ split($1, a, "_"); print a[1] }' | sort -u | tr '\n' ' ' || true)
            [ -n "$locks" ] && [ -z "$(printf '%s\n' $locks | grep -vx -e L148 -e L197 || true)" ] || continue
            printf 'R\t%s\t%s\t%s\t%s\n' "$(recid "$f")" "$(echo $locks | sed 's/ / and /g')" "$start" "$(iso "$start")"
        done > "$found"
    fi
    { grep '^R' "$found" || true; grep '^A' "$found" | sort -t "$(printf '\t')" -k2,2n || true; } > "$facts"
    out=$(awk -v mode=write -v sha="$sha" -v target="$TARGET" -v budget="$BUDGET" "$EXCUSE_AWK" "$log" "$steps" "$facts")
    rm -f "$facts" "$found"
    [ -n "$out" ] || exit 0
    mkdir -p "$dir" && printf '%s\n' "$out" > "$dir/${sha:0:8}"
    printf '%s\n' "$out"
    ;;
check)
    [ -f "$2" ] && [ -f "$3" ] || exit 0
    awk -v mode=check -v sha="$4" -v target="$TARGET" -v budget="$BUDGET" "$EXCUSE_AWK" "$2" "$3" "$5"
    ;;
*) echo "loop_excuse: unknown command $cmd"; exit 2 ;;
esac
