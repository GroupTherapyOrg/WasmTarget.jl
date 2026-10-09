#!/usr/bin/env bash
# The gate on CI's runners (AGENTS.md; dev/CHARTER.md C10): pushes a commit to gate/<name>, where
# .github/workflows/gate.yml runs every lane of `bash dev/lanes.sh`'s default run as its own job
# (the first red job cancels the rest), waits for the run, and prints one verdict line per lane
# and `LANES green` or `LANES red`. Exit 0 only on green. It runs no Julia on this machine.
#
#   bash dev/gate.sh                 # HEAD, on gate/<current branch, / as ->
#   bash dev/gate.sh <rev> [<name>]  # a branch or commit, on gate/<name>
#
# The commit is pushed as it is: uncommitted changes are not in it. A gate branch keeps its
# julia caches from push to push (GitHub scopes a cache to its branch and the default branch);
# re-gating the commit a branch already holds pushes it to gate/<name>-N, which starts cold.
set -uo pipefail
cd "$(dirname "$0")/.."
command -v gh >/dev/null || { echo "gate: needs the GitHub CLI (gh)" >&2; exit 2; }
rev=${1:-HEAD}
sha=$(git rev-parse --verify -q "$rev^{commit}") || { echo "gate: no commit $rev" >&2; exit 2; }
if [ -n "${2:-}" ]; then name=$2
elif git show-ref --verify -q "refs/heads/$rev"; then name=$rev
else name=$(git symbolic-ref --short -q HEAD || echo detached); fi
name=${name#gate/}; name=gate/${name//\//-}
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
  id=$(gh run list --branch "$name" --limit 20 --json databaseId,headSha,createdAt,workflowName \
       --jq "[.[] | select(.headSha == \"$sha\" and .createdAt >= \"$t0\" and
                          (.workflowName == \"Gate\" or .workflowName == \".github/workflows/gate.yml\"))][0].databaseId // empty")
  [ -n "$id" ] && break
  sleep 5
done
[ -n "$id" ] || { echo "gate: no gate.yml run for $sha on $name" >&2; exit 2; }
echo "gate: run $id  $(gh run view "$id" --json url --jq .url)"
gh run watch "$id" --interval 30 >/dev/null 2>&1
gh run view "$id" --json jobs --jq '.jobs[] | [.conclusion, .name,
    (if (.startedAt // "") != "" and (.completedAt // "") != "" and .startedAt < .completedAt
     then ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601) | tostring) + "s" else "" end)] | @tsv' |
  awk -F'\t' '{ v = $1 == "success" ? "ok  " : $1 == "failure" ? "FAIL" : "--  ";
                 printf "  %s %-16s %6s  %s\n", v, $2, $3, ($1 == "success" ? "" : $1) }'
conclusion=$(gh run view "$id" --json conclusion --jq .conclusion)
echo "gate: wall $(( $(date +%s) - s0 ))s"
if [ "$conclusion" = success ]; then echo "LANES green"; exit 0; fi
echo "the red lane's log: gh run view $id --log-failed"
echo "LANES red"; exit 1
