#!/usr/bin/env bash
# dev/land.sh — land a march agent branch onto the march branch (dev/MARCH.md §6).
#
#   dev/land.sh prepare <branch> [<old-base>]
#       worktree (durable, $WT_WORKTREES/<branch-leaf>) → rebase onto the march tip
#       (`--onto` from <old-base> when the branch was cut from rewritten or dropped
#       history) → strip transcript links from the rebased messages → the blocking gate,
#       `bash dev/gate.sh --block`, which records its verdict for the rebased head. No push.
#   dev/land.sh merge <branch>
#       refuses unless the blocking gate's record of exactly the branch head (dev/.block/<tree>.toml
#       in one of the repository's worktrees) is green, of that commit, and made on a clean tree,
#       and the main tree is clean; then fast-forwards the march branch to it from the main tree,
#       pushes it, and pushes the head to march/<branch-leaf>, where gate.yml runs the full matrix
#       on it, non-blocking (its red is the next batch's first item).
#
# The landing's gate is the blocking gate on this machine (dev/CHARTER.md C10, L194); no CI run
# holds a landing. The one final full gate before PR #122 merges is `bash dev/gate.sh` on the
# exact merge head.
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
    bash dev/gate.sh --block
    echo "prepared $br @ $(git rev-parse --short HEAD): dev/land.sh merge $br lands it"
    ;;
merge)
    head=$(git -C "$MAIN" rev-parse --verify -q "$br^{commit}") || { echo "no branch $br — refusing"; exit 1; }
    tree=$(git -C "$MAIN" rev-parse "$head^{tree}")
    # the blocking gate's record of exactly this commit (dev/block.jl writes it in the worktree it
    # ran in): green, of this head, made on a clean tree
    rec=""
    for w in $(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p'); do
        if [ -f "$w/dev/.block/$tree.toml" ] && grep -qx "head = \"$head\"" "$w/dev/.block/$tree.toml"; then rec="$w/dev/.block/$tree.toml"; break; fi
    done
    [ -n "$rec" ] || { echo "no blocking-gate record of $br @ ${head:0:8}: run \`bash dev/gate.sh --block\` on it — refusing"; exit 1; }
    grep -qx 'clean = true' "$rec" || { echo "$rec was made on a tree with uncommitted changes — refusing"; exit 1; }
    grep -qx 'verdict = "green"' "$rec" || { echo "$rec is not green — refusing"; grep -A8 '^failures' "$rec"; exit 1; }
    echo "the blocking gate's record of $br @ ${head:0:8}: green ($rec)"
    cd "$MAIN"
    [ "$(git rev-parse --abbrev-ref HEAD)" = "$MARCH" ] || { echo "main tree is not on $MARCH"; exit 1; }
    [ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "main tree has uncommitted changes — refusing"; exit 1; }
    git merge --ff-only "$head"
    git push -q origin "$MARCH"
    # the full matrix on the landed head, non-blocking (gate.yml runs on march/**)
    git push -q --force origin "$head:refs/heads/march/$leaf"
    echo "landed $br @ ${head:0:8} on $MARCH; the full matrix: gh run list --branch march/$leaf"
    ;;
*) echo "unknown command $cmd"; exit 1 ;;
esac
