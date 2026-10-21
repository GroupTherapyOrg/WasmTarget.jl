#!/usr/bin/env bash
# dev/kaimon_session.sh — whether a worktree has a live Kaimon session (every lane develops in one;
# `dev/land.sh land` refuses a worktree without one, in its preflight).
#
#   bash dev/kaimon_session.sh <worktree> [<kaimon cache dir>]
#
# A live session is a Kaimon REPL session record, <cache>/sock/<id>.json (the cache ~/.cache/kaimon by
# default), whose project_path is the worktree, whose endpoint socket exists and whose pid is alive.
# Prints the session and exits 0, or prints the call that starts one and exits 1. A checkout on CI
# (GITHUB_ACTIONS) runs no Kaimon: it exits 0, saying so.
set -euo pipefail
wt=$(cd "${1:?usage: dev/kaimon_session.sh <worktree> [<kaimon cache dir>]}" && pwd -P)
cache=${2:-$HOME/.cache/kaimon}
if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "kaimon: a CI checkout runs no Kaimon session"; exit 0; fi
found=$(python3 -I - "$wt" "$cache/sock" <<'PY'
import json, os, sys
wt, d = sys.argv[1], sys.argv[2]
for f in (sorted(os.listdir(d)) if os.path.isdir(d) else []):
    if not f.endswith('.json'):
        continue
    try:
        s = json.load(open(os.path.join(d, f)))
    except Exception:
        continue
    p = s.get('project_path') or ''
    if not p or os.path.realpath(p) != wt:
        continue
    ep = s.get('endpoint') or ''
    sock = ep[len('ipc://'):] if ep.startswith('ipc://') else os.path.join(d, f[:-5] + '.sock')
    pid = s.get('pid')
    if not os.path.exists(sock) or not isinstance(pid, int) or pid <= 0:
        continue
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue
    except PermissionError:
        pass
    print(s.get('session_id', f[:-5]), pid)
    break
PY
)
if [ -n "$found" ]; then echo "kaimon: live session ${found% *} (pid ${found#* }) for $wt"; exit 0; fi
echo "kaimon: no live Kaimon session for $wt: start one, mcp__kaimon__start_session(project_path=\"$wt\", private=true)"
exit 1
