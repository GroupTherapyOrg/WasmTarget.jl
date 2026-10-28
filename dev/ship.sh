#!/usr/bin/env bash
# Land this worktree's commits on the march branch: rebase onto it, run dev/check.sh, push fast-forward.
# A push another lane beat is rebased and checked again. Never a merge commit, never a force push.
set -uo pipefail
# the one march branch on origin (D23): every lane lands here; worktrees and their branches stay local
MARCH=wt2
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "ship: commit or drop your changes first"; exit 2; }
for try in 1 2 3 4 5; do
  git fetch -q origin "$MARCH" || { sleep 5; continue; }
  git rebase -q origin/$MARCH || { echo "ship: the rebase onto origin/$MARCH conflicts; resolve it and ship again"; exit 1; }
  [ "$(git rev-list --count origin/$MARCH..HEAD)" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
  bash dev/check.sh || exit 1
  if git push -q origin HEAD:$MARCH; then
    echo "ship: landed $(git rev-parse --short HEAD) on $MARCH: $(git log --format='%h %s' origin/$MARCH@{1}..HEAD 2>/dev/null | wc -l | tr -d ' ') commit(s)"
    # the rebuild's src progress, dev/src_progress.sh's line the check's ratchet printed for this tree (L208, D40)
    grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'; exit 0
  fi
  echo "ship: another lane landed first; again ($try)"
done
echo "ship: gave up after 5 races"; exit 1
