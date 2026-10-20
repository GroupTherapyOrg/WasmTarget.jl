#!/usr/bin/env bash
# dev/land.sh — land a march agent branch onto the march branch (dev/MARCH.md §6).
#
#   dev/land.sh prepare <branch> [<old-base>]
#       worktree (durable, $WT_WORKTREES/<branch-leaf>) → rebase onto the march tip
#       (`--onto` from <old-base> when the branch was cut from rewritten or dropped
#       history) → strip transcript links from the rebased messages → fast lanes →
#       push the branch (a march/** push runs no CI: the gate is the landing's one run).
#   dev/land.sh merge <branch>
#       refuses unless gate.yml's run of the branch head on a gate/** branch (`bash dev/gate.sh`:
#       every lane, and CI's matrix through its gated call) concluded success with every job
#       successful, then fast-forwards the march branch to it from the main tree and pushes.
#
# The full gate is gate.yml on the exact head that lands, one run (dev/CHARTER.md C10, L153);
# a local full Pkg.test is optional.
set -euo pipefail
MARCH=${WT_MARCH_BRANCH:-wt-p0-strict-hygiene}
MAIN=$(git rev-parse --show-toplevel)
WT_WORKTREES=${WT_WORKTREES:-$(dirname "$MAIN")/.worktrees}
cmd=${1:?usage: dev/land.sh prepare|merge <branch> [old-base]}
br=${2:?branch}
leaf=${br##*/}
W="$WT_WORKTREES/wt-$leaf"

case "$cmd" in
prepare)
    git -C "$MAIN" fetch -q origin
    if [ ! -d "$W" ]; then
        git -C "$MAIN" worktree add -q "$W" "$br" 2>/dev/null ||
            git -C "$MAIN" worktree add -q -b "$br" "$W" "origin/$br"
    fi
    # Manifest.toml is untracked: a fresh worktree resolves exactly the main tree's environment
    [ -f "$W/Manifest.toml" ] || cp "$MAIN/Manifest.toml" "$W/Manifest.toml"
    tip=$(git -C "$MAIN" rev-parse "$MARCH")
    cd "$W"
    [ -z "$(git status --porcelain)" ] || { echo "worktree $W is dirty — refusing"; exit 1; }
    if [ -n "${3:-}" ]; then rebase=(git rebase --onto "$tip" "$3" "$br"); else rebase=(git rebase "$tip"); fi
    if ! "${rebase[@]}"; then
        # a stop whose only conflict is the ratchet baseline resolves through
        # dev/merge_baseline.py (per key the minimum; it refuses a key whose counter changed)
        while [ "$(git diff --name-only --diff-filter=U)" = "dev/parity_baseline.toml" ]; do
            python3 dev/merge_baseline.py dev/parity_baseline.toml
            git add dev/parity_baseline.toml
            GIT_EDITOR=true git rebase --continue && break
        done
        if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
            echo "rebase of $br stopped on a conflict outside dev/parity_baseline.toml — resolve it in $W"; exit 1
        fi
    fi
    # strip transcript links; add the dev/CHARTER.md trailer where an agent omitted it
    # (CHARTER="C1 C9" dev/land.sh prepare … — the lander states what the branch closes)
    FILTER_BRANCH_SQUELCH_WARNING=1 WT_HOOK_FILTER=1 CHARTER="${CHARTER:-}" git filter-branch -f --msg-filter \
        'f=$(mktemp); cat > "$f"; sh "'"$MAIN"'/dev/hooks/commit-msg" "$f"
         if ! grep -qE "^Charter: C[0-9]+" "$f" && [ -n "$CHARTER" ]; then printf "\nCharter: %s\n" "$CHARTER" >> "$f"; fi
         cat "$f"; rm -f "$f"' \
        "$tip..$br" >/dev/null
    for h in $(git rev-list --no-merges "$tip..$br"); do
        git log -1 --format=%B "$h" | grep -qE '^Charter: C[0-9]+' ||
            { echo "$(git log -1 --format='%h %s' "$h") has no Charter: trailer — rerun with CHARTER=\"C<n> …\""; exit 1; }
    done
    git log --oneline "$tip..$br" | cat
    bash dev/lanes.sh --fast
    git push -q --force-with-lease origin "$br"
    echo "pushed $br @ $(git rev-parse --short HEAD) — CI: gh run list --branch $br"
    ;;
merge)
    git -C "$MAIN" fetch -q origin "$br"
    head=$(git -C "$MAIN" rev-parse "origin/$br")
    # the newest gate.yml run of exactly this commit on a gate/** branch (a full gate, never a
    # gate-fast/** run): it concluded success and every job it ran did
    run=$(gh api "repos/{owner}/{repo}/actions/workflows/gate.yml/runs?head_sha=$head&event=push&per_page=100" \
        --jq "[.workflow_runs[] | select(.head_sha == \"$head\" and (.head_branch | startswith(\"gate/\")) and .status == \"completed\")]
              | sort_by(.created_at) | last | if . == null then \"\" else \"\(.id) \(.conclusion)\" end")
    [ -n "$run" ] || { echo "no gate/** run of gate.yml for $br @ ${head:0:8}: run \`bash dev/gate.sh $br\` — refusing"; exit 1; }
    id=${run% *}
    [ "${run#* }" = success ] || { echo "the gate run $id of $br @ ${head:0:8} is '${run#* }', not success — refusing"; exit 1; }
    bad=$(gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100&filter=latest" --paginate \
        --jq '.jobs[] | select(.conclusion != "success") | "\(.name): \(.conclusion // "pending")"')
    [ -z "$bad" ] || { echo "the gate run $id of $br @ ${head:0:8} has jobs that did not succeed — refusing:"; echo "$bad"; exit 1; }
    echo "the gate run $id of $br @ ${head:0:8}: every job succeeded"
    cd "$MAIN"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "$MARCH" ] || { echo "main tree is not on $MARCH"; exit 1; }
    git merge --ff-only "$head"
    git push -q origin "$MARCH"
    echo "landed $br @ ${head:0:8} on $MARCH"
    ;;
*) echo "unknown command $cmd"; exit 1 ;;
esac
