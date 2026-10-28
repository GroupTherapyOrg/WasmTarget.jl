#!/usr/bin/env bash
# Land this worktree's commits on the march branch: rebase onto it, run dev/check.sh, push fast-forward.
# A push another lane beat is rebased and checked again. Never a merge commit, never a force push.
set -uo pipefail
# the one march branch on origin (D23): every lane lands here; worktrees and their branches stay local
MARCH=wt2
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "ship: commit or drop your changes first"; exit 2; }
log="$(git rev-parse --git-common-dir)/wt-landings.tsv"   # one log for every lane: D13's band
for try in 1 2 3 4 5; do
  git fetch -q origin "$MARCH" || { sleep 5; continue; }
  [ "$(git rev-list --count origin/$MARCH..HEAD)" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
  first=$(git log --reverse --format=%at origin/$MARCH..HEAD | head -1)
  # every commit is checked on its own tree, against its parent (the rule bors and git rebase
  # --exec keep: each landed commit passes), so no landed commit is red
  # (the check runs with git's own rebase variables cleared: the ratchet's plants make scratch
  # repositories, and an inherited GIT_DIR or GIT_INDEX_FILE would point them at this one)
  if ! git rebase -q origin/$MARCH --exec 'env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX -u GIT_REFLOG_ACTION CHECK_BASE=HEAD~1 bash dev/check.sh'; then
    if [ -d "$(git rev-parse --git-dir)/rebase-merge" ]; then git rebase --abort; fi
    echo "ship: a commit's check is red or the rebase conflicts; the branch is as it was. Fix it and ship again"; exit 1
  fi
  if git push -q origin HEAD:$MARCH; then
    secs=$(( $(date +%s) - first ))
    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(git rev-parse --short HEAD)" "$secs" >> "$log"
    med=$(tail -5 "$log" | cut -f3 | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
    echo "ship: landed $(git rev-parse --short HEAD) on $MARCH, ${secs}s from its first commit to landed"
    if [ "$med" -gt 600 ]; then echo "ship: RED — the median of the last five landings is ${med}s, past D13's band (a 300-s target, red past 600 s)"
    else echo "ship: median of the last five landings ${med}s (D13: a 300-s target, red past 600 s)"; fi
    # the rebuild's src progress, dev/src_progress.sh's line the check's ratchet printed for this tree (L208, D40)
    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0
  fi
  echo "ship: another lane landed first; again ($try)"
done
echo "ship: gave up after 5 races"; exit 1
