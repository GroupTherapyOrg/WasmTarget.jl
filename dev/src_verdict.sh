#!/usr/bin/env bash
# dev/src_verdict.sh — the one reading of a landing check's src-test shards into its verdict (dev/check.sh runs it after
# the shards end; the round-14 probes run it alone on planted records):
#   bash dev/src_verdict.sh <the handed set> <shard 1's exit status> <its records> [<status> <records> ...]
# It prints its reasons as `check:` lines and exits:
#   0   every row of every shard is green, or red only at a known red's own listed failing tests (below);
#   15  a shard's records are void (the judge's canary, last or as a file, read wrong or is missing, or its exit status disagrees with its
#       rows: the round-13 architect's A13-5): a red of the process, its files listed as `void\t<file>` lines in
#       $SRC_VOID_OUT when set, which the lander locates through R3's path (spec v17 Z3);
#   1   the rows are not exactly the handed set (spec v17 Z2), or a shard skipped as claimed a file no other shard started (v19 Q2);
#   14  a row is red, and not only at a known red's listed failing tests: red on test files alone (R3 reads which).
# A known red (the climb's registry: a src-test fix-first entry, measure.src_reds) that runs in the set is named in it by
# the lander as `# known <file>\t<its failures, tab-separated>` (every non-passing test, `<file>:<line> <kind>`); a row of
# that file whose every non-passing test is one that line lists is the known red's, never this change's (the round-14
# operator's finding 2, spec v17 Z1: a flaky known red that reads red in every shard livelocked the lander), so the check
# stands and the entry ages in landings. A row with any other failure of that file is a new red (spec v18 Q1: the
# round-15 architect's finding 2, a known red masking a new failure in its file) and counts. A row's failures are read
# by red_id below, the one identity measure.src_fails reads too (a multiset: spec v19 Q1).
set -uo pipefail
# THE identity of a red (spec v18 Q1, v19 Q1; the round-16 architect's finding 2): the MULTISET of `<file>:<line>
# <kind>` of every non-passing test a row's why lists (a line each; a line with no place kept as its first 120
# characters), sorted with duplicates kept, so a second failure at a line a known red already lists (an iteration of a
# looped @test) is a new red. One definition: this function, which measure.src_fails calls as `--fails` (D5).
red_id() { awk '{ if (match($0, /^[^ ]+:[0-9]+ [^ :]+:/)) print substr($0, 1, RLENGTH - 1); else if ($0 != "") print substr($0, 1, 120) }' | LC_ALL=C sort; }
if [ "${1:-}" = "--fails" ]; then red_id; exit 0; fi   # a why on stdin: its identity, a line each
setf=$1; shift
known=$(sed -n 's/^# known \(.*\)$/\1/p' "$setf" 2>/dev/null)
k=0; void=""; voidfiles=""; red=0; knownred=""; open_all=0
fails_of() { printf '%s' "$1" | base64 -D 2>/dev/null | red_id; }
is_known() {   # <file> <its failures, a line each>: a known line of the file lists every one
  local f=$1 fs=$2 line
  [ -n "$fs" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && [ "${line%%$'\t'*}" = "$f" ] || continue
    [ -z "$(LC_ALL=C comm -23 <(printf '%s\n' "$fs") <(printf '%s' "${line#*$'\t'}" | tr '\t' '\n' | LC_ALL=C sort))" ] && return 0   # as multisets
  done <<< "$known"
  return 1
}
recs=()
while [ $# -ge 2 ]; do
  r=$1; f=$2; shift 2; k=$((k + 1)); recs+=("$f")
  canary=$(awk -F'\t' '$1 == "row" && $2 == "~canary" { c = $3 } END { print c }' "$f" 2>/dev/null)
  rows=$(awk -F'\t' '$1 == "row" && $2 != "~canary" && $3 != "passed" { print $2 "\t" $5 }' "$f" 2>/dev/null)
  n=0; unknown=0
  while IFS=$'\t' read -r file why; do
    [ -n "$file" ] || continue
    n=$((n + 1))
    if is_known "$file" "$(fails_of "$why")"; then knownred="$knownred $file"; else unknown=$((unknown + 1)); fi
  done <<< "$rows"
  open=$(awk -F'\t' '$1 == "started" { s[$2] = 1 } $1 == "row" { delete s[$2] } END { n = 0; for (x in s) n++; print n }' "$f" 2>/dev/null)
  ran=$(awk -F'\t' '$1 == "started" && $2 != "~canary" { printf "%s ", $2 }' "$f" 2>/dev/null)
  v0=$void
  # the block grammar (spec v18 Q3, red's round-15 p1 v3; measure.src_process reads the same): a file's records are its
  # block, `started <f>` then `row <f>`, closed before the next opens; a `claimed <f>` line (a file another shard took)
  # sits between blocks; the canary's row is the last line (spec v19 Q2, red's round-16 p1v4: an @async task writing a
  # claimed sibling's block after the canary). A `started` inside another file's block, a row outside its own block or
  # any line after the canary's row is a record the process's files did not write as the harness does: the shard is
  # void
  grammar=$(awk -F'\t' 'done { print "a line after the canary'"'"'s row (" $1 " " $2 ")"; exit }
                        $1 == "started" { if (open != "") { print "a started of " $2 " inside " open "'"'"'s block"; exit } open = $2; next }
                        $1 == "row" { if ($2 != open) { print "a row of " $2 " outside its own block"; exit } open = ""; if ($2 == "~canary") done = 1; next }
                        $1 == "claimed" { if (open != "") { print "a claimed " $2 " inside " open "'"'"'s block"; exit } next }' "$f" 2>/dev/null)
  [ -z "$grammar" ] || void="$void; shard $k's records break their block grammar: $grammar (its files: ${ran:-none})"
  [ "$canary" = passed ] || void="$void; shard $k's canary read ${canary:-nothing} (its files: ${ran:-none})"
  asfile=$(awk -F'\t' '$1 == "row" && $2 != "~canary" && $6 != "passed" { printf "%s ", $2 }' "$f" 2>/dev/null)
  [ -z "$asfile" ] || void="$void; shard $k's canary as ${asfile}read wrong (spec v17 Z4; its files: ${ran:-none})"
  { [ "$r" -eq 0 ] && [ "$n" -gt 0 ]; } && void="$void; shard $k exited 0 with $n red row(s) (its files: $ran)"
  { [ "$r" -ne 0 ] && [ "$n" -eq 0 ] && [ "$open" -eq 0 ]; } && void="$void; shard $k exited $r with every row passed (its files: $ran)"
  [ "$void" = "$v0" ] || voidfiles="$voidfiles $ran"
  red=$((red + unknown)); open_all=$((open_all + open))
done
if [ -n "$void" ]; then
  [ -z "${SRC_VOID_OUT:-}" ] || for x in $voidfiles; do printf 'void\t%s\n' "$x"; done > "$SRC_VOID_OUT"
  echo "check: RED — the shards' records are void${void}"; exit 15
fi
# a landing proves exactly its set (red's round-14 finding 2, spec v17 Z2): every file the lander handed has exactly one
# row across the shards, or the check is red naming the files. A file whose claim another file made (the claims queue,
# test/src_tests.jl `_wt_claim`) never runs in any shard and left no record a rule above reads
want=$(grep -v '^#' "$setf" | sed '/^[[:space:]]*$/d' | sort)
got=$(cat "${recs[@]}" 2>/dev/null | awk -F'\t' '$1 == "row" && $2 != "~canary" { print $2 }' | sort)
# a file started and left without a row (its shard ended during it) is unfinished, red below and read by R3; a file never
# started in any shard is missing
seen=$(cat "${recs[@]}" 2>/dev/null | awk -F'\t' '($1 == "row" || $1 == "started") && $2 != "~canary" { print $2 }' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$want" | sort -u) <(printf '%s\n' "$seen") | sed '/^$/d' | tr '\n' ' ')
twice=$(printf '%s\n' "$got" | uniq -d | sed '/^$/d' | tr '\n' ' ')
outside=$(comm -13 <(printf '%s\n' "$want" | sort -u) <(printf '%s\n' "$got" | sort -u) | sed '/^$/d' | tr '\n' ' ')
# each `claimed <f>` a shard wrote must match ANOTHER shard's `started <f>` (spec v19 Q2): a claim no other shard ran
# is a file the set handed that ran nowhere, red naming it
unclaimed=""; k=0
for f in "${recs[@]}"; do
  k=$((k + 1))
  for c in $(awk -F'\t' '$1 == "claimed" { print $2 }' "$f" 2>/dev/null); do
    j=0; hit=0
    for g in "${recs[@]}"; do j=$((j + 1)); [ "$j" -ne "$k" ] && awk -F'\t' -v c="$c" '$1 == "started" && $2 == c { f = 1 } END { exit !f }' "$g" 2>/dev/null && hit=1; done
    [ "$hit" -eq 1 ] || unclaimed="$unclaimed $c"
  done
done
[ -z "$unclaimed" ] || { echo "check: RED — a shard skipped a file as claimed that no other shard started:$unclaimed"; exit 1; }
[ -z "$missing$twice$outside" ] || { echo "check: RED — the shards' rows are not exactly the handed set:${missing:+ no row for $missing}${twice:+; more than one row for $twice}${outside:+; rows outside the set for $outside}"; exit 1; }
[ -n "$knownred" ] && echo "check: red only at known reds' own failing tests:${knownred}; the known reds', not this change's (their entries age)"
{ [ "$red" -eq 0 ] && [ "$open_all" -eq 0 ]; } || { echo "check: src tests red"; exit 14; }
exit 0
