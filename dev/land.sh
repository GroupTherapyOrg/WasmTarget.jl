#!/usr/bin/env bash
# dev/land.sh — land a march agent branch onto the march branch (dev/MARCH.md §6).
#
#   dev/land.sh prepare <branch> [<old-base>]
#       worktree (durable, $WT_WORKTREES/<branch-leaf>) → rebase onto the march tip
#       (`--onto` from <old-base> when the branch was cut from rewritten or dropped
#       history) → strip transcript links from the rebased messages → the blocking gate,
#       `bash dev/gate.sh --block`, which records its verdict for the rebased head. No push.
#   dev/land.sh merge <branch>
#       refuses unless the blocking gate's records of the branch head's tree (dev/.block/<tree>-<n>.toml,
#       one per run, in any of the repository's worktrees) hold no red one (a red run stands) and
#       the last one is green, of exactly that commit, made on a clean tree, judging the change
#       from the head's merge base with the march branch,
#       and the main tree is clean; refuses while the full matrix on the last landed head (its
#       gate.yml run) is red, its red being the next item, and lands with a WARNING, written into
#       the record, while that run has not finished or there is none; then fast-forwards the march
#       branch to it from the main tree, pushes it, and pushes the head to march/<branch-leaf>,
#       where gate.yml runs the full matrix on it, non-blocking.
#
# The landing's gate is the blocking gate on this machine (dev/CHARTER.md C10, L194); no CI run
# holds a landing: the matrix's verdict on the last landed head is read, never waited for. The one
# final full gate before PR #122 merges is `bash dev/gate.sh` on the exact merge head.
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
    # the blocking gate's records of this tree (dev/block.jl writes one per run, in the worktree it
    # ran in): no red one, whatever ran after it; the last, by the time it finished, green, of this
    # head, made on a clean tree
    recs=()
    for w in $(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p'); do
        for f in "$w/dev/.block/$tree"-*.toml; do [ -f "$f" ] && recs+=("$f"); done
    done
    [ ${#recs[@]} -gt 0 ] || { echo "no blocking-gate record of $br @ ${head:0:8}: run \`bash dev/gate.sh --block\` on it — refusing"; exit 1; }
    for f in "${recs[@]}"; do
        grep -qx 'verdict = "red"' "$f" && { echo "$f is red: a red run of this tree stands — refusing"; grep -A8 '^failures' "$f"; exit 1; }
    done
    rec=$(for f in "${recs[@]}"; do printf '%s\t%s\n' "$(sed -n 's/^finished = //p' "$f")" "$f"; done | sort -g | tail -1 | cut -f2)
    grep -qx "head = \"$head\"" "$rec" || { echo "$rec, the last record of this tree, is of another commit — refusing"; exit 1; }
    grep -qx 'clean = true' "$rec" || { echo "$rec was made on a tree with uncommitted changes — refusing"; exit 1; }
    # the change judged whole: from the head's merge base with the march branch, never a --base or
    # WT_MARCH_BRANCH that narrows what the gate selects (A19P8)
    mb=$(git -C "$MAIN" merge-base "$head" "$MARCH")
    grep -qx "base = \"$mb\"" "$rec" ||
        { echo "$rec judged the change from $(sed -n 's/^base = //p' "$rec"), not from ${head:0:8}'s merge base with $MARCH, ${mb:0:8} — refusing"; exit 1; }
    # fresh processes, or this commit's own warm runner, named by its blob (A19P4)
    runner=$(sed -n 's/^runner = "\(.*\)"$/\1/p' "$rec")
    [ -z "$runner" ] || [ "$runner" = "dev/block_runner.jl $(git -C "$MAIN" rev-parse "$head:dev/block_runner.jl")" ] ||
        { echo "$rec ran through \"$runner\", not fresh processes or this commit's dev/block_runner.jl — refusing"; exit 1; }
    grep -qx 'verdict = "green"' "$rec" || { echo "$rec, the last record of this tree, is not green ($(sed -n 's/^verdict_why = //p' "$rec")) — refusing"; exit 1; }
    echo "the blocking gate's record of $br @ ${head:0:8}: green ($rec)"
    # the full matrix on the last landed head: gate.yml's newest run of it on a march/** or gate/** push
    # (by name, not --workflow, which finds only a workflow on the default branch; a gate.yml not yet
    # parsed is named by its path), read three times at most, never waited for
    command -v gh >/dev/null || { echo "land: needs the GitHub CLI (gh) to read the matrix on the last landed head — refusing"; exit 1; }
    prev=$(git -C "$MAIN" rev-parse "$MARCH")
    matrix=""
    for k in 1 2 3; do
        matrix=$(gh run list --commit "$prev" --limit 50 --json databaseId,status,conclusion,workflowName,event,headBranch \
            --jq '[.[] | select(.event == "push" and ((.headBranch | startswith("march/")) or (.headBranch | startswith("gate/")))
                                and (.workflowName == "Gate" or .workflowName == ".github/workflows/gate.yml"))]
                  | sort_by(.databaseId) | last | if . == null then "none::" else "\(.status):\(.conclusion // ""):\(.databaseId)" end' 2>/dev/null) && break
        matrix=""; [ $k -lt 3 ] && sleep $((k * 10))
    done
    [ -n "$matrix" ] || { echo "land: the GitHub API gives no runs of ${prev:0:8}: the matrix's verdict on the last landed head is unknown — refusing"; exit 1; }
    IFS=: read -r mstatus mconclusion mrun <<<"$matrix"
    warning=""
    case "$mstatus:$mconclusion" in
    completed:success) echo "the full matrix on the last landed head ${prev:0:8}: green (run $mrun)" ;;
    completed:failure | completed:timed_out | completed:startup_failure)
        echo "a red matrix on ${prev:0:8} is the next item (gate.yml run $mrun, $mconclusion): fix it first — refusing"; exit 1 ;;
    none:*) warning="no gate.yml run of the last landed head ${prev:0:8}: its matrix has no verdict" ;;
    completed:*) warning="the full matrix on the last landed head ${prev:0:8} has no verdict (gate.yml run $mrun, $mconclusion)" ;;
    *) warning="the full matrix on the last landed head ${prev:0:8} is not finished (gate.yml run $mrun, $mstatus)" ;;
    esac
    if [ -n "$warning" ]; then
        echo "WARNING: $warning"
        printf '\n[landing]\nwarning = "%s"\n' "$warning" >> "$rec"
    fi
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
