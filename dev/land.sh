#!/usr/bin/env bash
# dev/land.sh — land a march agent branch onto the march branch (dev/MARCH.md §6).
#
#   dev/land.sh prepare <branch> [<old-base>]
#       worktree (durable, $WT_WORKTREES/<branch-leaf>) → rebase onto the march tip
#       (`--onto` from <old-base> when the branch was cut from rewritten or dropped
#       history) → strip transcript links from the rebased messages → fast lanes →
#       push the branch, which runs the FULL CI matrix on it (ci.yml `march/**`).
#   dev/land.sh merge <branch>
#       refuses unless every CI check on the branch head concluded success, then
#       fast-forwards the march branch to it from the main tree and pushes.
#
# The full gate is CI on the exact head that lands; a local full Pkg.test is optional.
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
    head=$(git -C "$MAIN" rev-parse "origin/$br")
    states=$(gh api "repos/{owner}/{repo}/commits/$head/check-runs?per_page=100" \
        --jq '[.check_runs[] | select(.name | test("downstream") | not) | .conclusion // "pending"] | unique | join(",")')
    [ "$states" = "success" ] || { echo "CI on $br @ ${head:0:8} is '$states', not success — refusing"; exit 1; }
    cd "$MAIN"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "$MARCH" ] || { echo "main tree is not on $MARCH"; exit 1; }
    git merge --ff-only "$head"
    git push -q origin "$MARCH"
    echo "landed $br @ ${head:0:8} on $MARCH"
    ;;
*) echo "unknown command $cmd"; exit 1 ;;
esac
