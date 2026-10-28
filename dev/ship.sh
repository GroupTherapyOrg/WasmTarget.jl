#!/usr/bin/env bash
# Land this worktree's commits on wt3: rebase onto origin/wt3, run dev/check.sh, push fast-forward.
# A push another lane beat is rebased and checked again. Never a merge commit, never a force push.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "ship: commit or drop your changes first"; exit 2; }
for try in 1 2 3 4 5; do
  git fetch -q origin wt3 || { sleep 5; continue; }
  git rebase -q origin/wt3 || { echo "ship: the rebase onto origin/wt3 conflicts; resolve it and ship again"; exit 1; }
  [ "$(git rev-list --count origin/wt3..HEAD)" -gt 0 ] || { echo "ship: nothing to land"; exit 0; }
  bash dev/check.sh || exit 1
  if git push -q origin HEAD:wt3; then
    echo "ship: landed $(git rev-parse --short HEAD) on wt3: $(git log --format='%h %s' origin/wt3@{1}..HEAD 2>/dev/null | wc -l | tr -d ' ') commit(s)"; exit 0
  fi
  echo "ship: another lane landed first; again ($try)"
done
echo "ship: gave up after 5 races"; exit 1
