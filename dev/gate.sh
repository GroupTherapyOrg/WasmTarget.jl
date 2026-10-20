#!/usr/bin/env bash
# The gate on CI's runners (AGENTS.md; dev/CHARTER.md C10): pushes a commit to gate/<name>, where
# .github/workflows/gate.yml runs every lane of `bash dev/lanes.sh`'s default run, one job per
# part, and CI's matrix beside them (the first red job cancels the rest), waits for the run, and
# prints `FAST green` or `FAST red` as soon as the fast job (the ratchet and both smokes) is done,
# then one verdict line per job, the slowest lane job against the budgets gate.yml's fast and lane
# timeouts set (a job its budget cut off is marked past it), and `LANES green` or `LANES red`.
# Exit 0 only on green. A verdict the GitHub API would not give (every read retried three times,
# the waits between them growing) is `LANES unknown`, exit 3: a lost connection is never read as a
# red run. It runs no Julia on this machine. `bash dev/land.sh merge` lands a branch head only on
# this run of that exact commit.
#
#   bash dev/gate.sh                 # HEAD, on gate/<current branch, / as ->
#   bash dev/gate.sh <rev> [<name>]  # a branch or commit, on gate/<name>
#   bash dev/gate.sh --fast [<rev>] [<name>]   # the inner loop, not the push gate: pushes to
#       gate-fast/<name>, where gate.yml runs only the fast job, the ratchet and smoke on 1.12 and
#       1.13 (L163), with the emission-diff check (dev/emission_diff.sh, L190), and prints
#       `FAST green` or `FAST red`
#
# The commit is pushed as it is: uncommitted changes are not in it. Re-gating the commit a branch
# already holds pushes it to gate/<name>-N.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v gh >/dev/null || { echo "gate: needs the GitHub CLI (gh)" >&2; exit 2; }
# an API read, retried: three tries, 10 s then 30 s apart; its output, or nothing and status 1
api() { local out k; for k in 1 2 3; do out=$("$@" 2>/dev/null) && { printf '%s' "$out"; return 0; }
          [ $k -lt 3 ] && sleep $((k == 1 ? 10 : 30)); done; return 1; }
fast=0; [ "${1:-}" = --fast ] && { fast=1; shift; }
prefix=gate; workflow=Gate; verdict=LANES
[ $fast -eq 0 ] || { prefix=gate-fast; verdict=FAST; }
rev=${1:-HEAD}
sha=$(git rev-parse --verify -q "$rev^{commit}") || { echo "gate: no commit $rev" >&2; exit 2; }
if [ -n "${2:-}" ]; then name=$2
elif git show-ref --verify -q "refs/heads/$rev"; then name=$rev
else name=$(git symbolic-ref --short -q HEAD || echo detached); fi
name=${name#gate/}; name=${name#gate-fast/}; name=$prefix/${name//\//-}
[ -z "$(git status --porcelain --untracked-files=no)" ] || echo "gate: uncommitted changes are not in the gated commit"
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ); s0=$(date +%s)
# a push of the commit a gate branch already holds starts no run, so a re-gate goes to the first
# gate/<name>-N (N = 2, 3, ...) that does not hold it (workflow_dispatch would need gate.yml on main)
base=$name; n=1
while [ "$(git ls-remote origin "refs/heads/$name" | cut -f1)" = "$sha" ]; do n=$((n + 1)); name=$base-$n; done
git push -q --force origin "$sha:refs/heads/$name" || exit 2
echo "gate: $(git log -1 --format='%h %s' "$sha" | cut -c1-80) on $name"
id=""
for _ in $(seq 60); do
  # by name, not --workflow (which finds only a workflow on the default branch); a gate.yml that
  # does not parse is named by its path, and its run is red
  id=$(api gh run list --branch "$name" --limit 20 --json databaseId,headSha,createdAt,workflowName \
       --jq "[.[] | select(.headSha == \"$sha\" and .createdAt >= \"$t0\" and
                          (.workflowName == \"$workflow\" or .workflowName == \".github/workflows/gate.yml\"))][0].databaseId // empty")
  [ -n "$id" ] && break
  sleep 5
done
[ -n "$id" ] || { echo "gate: no gate.yml run for $sha on $name" >&2; exit 2; }
echo "gate: run $id  $(api gh run view "$id" --json url --jq .url)"
# the fast job's names (the ratchet and the smokes, gate.yml's `fast` matrix): its verdict prints
# as soon as every one of them is done
fastjob='^(ratchet|smoke [0-9]+/[0-9]+|smoke-1\\.13 [0-9]+/[0-9]+)$'
fast_said=0
# the run is done when the API says completed: a dropped connection is retried, and a run whose
# status the API will not give after the retries has no verdict
until [ "$(api gh run view "$id" --json status --jq .status)" = completed ]; do
  if [ $fast_said -eq 0 ] && [ $fast -eq 0 ]; then
    f=$(api gh run view "$id" --json jobs --jq "[.jobs[] | select(.name | test(\"$fastjob\"))] |
         if length > 0 and all(.status == \"completed\") then (if all(.conclusion == \"success\") then \"green\" else \"red\" end) else \"\" end") || f=""
    if [ -n "$f" ]; then echo "FAST $f  ($(( $(date +%s) - s0 ))s; the full verdict follows)"; fast_said=1; fi
  fi
  sleep 20
  api gh run view "$id" --json status --jq .status >/dev/null ||
    { echo "gate: the API gives no status for run $id: no verdict"; echo "$verdict unknown"; exit 3; }
done
# the budgets, minutes per job: B_fast the fast job's timeout in gate.yml (L163), B the lane job's
# (L162), the one source of each
job_timeout() { awk -v job="  $1:" '$0 == job { injob = 1; next } /^  [a-z][a-z-]*:$/ { injob = 0 }
                  injob && /^    timeout-minutes:/ { print $2; exit }' .github/workflows/gate.yml; }
bfast=$(job_timeout fast); budget=$(job_timeout lane)
[ -n "$bfast" ] && [ -n "$budget" ] || { echo "gate: gate.yml's fast or lane job has no timeout-minutes, its budget" >&2; exit 2; }
# a job whose step failed is red, though its own `Cancel the run` step leaves it cancelled; a
# fast job is measured against B_fast, a lane job against B, CI's (ci / ...) against its own timeout
api gh run view "$id" --json jobs --jq '.jobs[] | [(if any(.steps[]?; .conclusion == "failure") then "failure" else .conclusion end), .name,
    (if (.startedAt // "") != "" and (.completedAt // "") != "" and .startedAt < .completedAt
     then ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601) | tostring) else "" end)] | @tsv' |
  awk -F'\t' -v B="$budget" -v BF="$bfast" -v FJ="$fastjob" '{ v = $1 == "success" ? "ok  " : $1 == "failure" ? "FAIL" : "--  ";
                 ci = ($2 ~ /^ci \//); b = ($2 ~ FJ) ? BF : B
                 past = (!ci && $3 != "" && $3 + 0 >= b * 60) ? sprintf("  PAST THE %d-MINUTE BUDGET", b) : "";
                 printf "  %s %-40s %6s  %s%s\n", v, $2, ($3 == "" ? "" : $3 "s"), ($1 == "success" ? "" : $1), past
                 if (ci) { if ($3 != "" && $3 + 0 > cslow) { cslow = $3 + 0; cslowest = $2 } }
                 else if ($2 != "coverage-merge" && $2 != "emission-plan" && $2 != "emission" && $3 != "" && $3 + 0 > slow) { slow = $3 + 0; slowest = $2 } }
               END { if (slowest != "") printf "gate: slowest lane job %s %d s (budgets: fast %d min, lane %d min)\n", slowest, slow, BF, B
                     if (cslowest != "") printf "gate: slowest CI job %s %d s\n", cslowest, cslow }'
conclusion=$(api gh run view "$id" --json conclusion --jq .conclusion)
echo "gate: wall $(( $(date +%s) - s0 ))s"
if [ "$conclusion" = success ]; then echo "$verdict green"; exit 0; fi
# only a conclusion the API gave is red; none (a lost connection, an empty read) is unknown
if [ -z "$conclusion" ]; then echo "gate: the API gives no conclusion for run $id: no verdict"; echo "$verdict unknown"; exit 3; fi
echo "the red lane's log: gh run view $id --log-failed"
echo "$verdict red"; exit 1
