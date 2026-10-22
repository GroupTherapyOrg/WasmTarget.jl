#!/usr/bin/env bash
# dev/land.sh — land a march agent branch onto the march branch (dev/MARCH.md §6).
#
#   dev/land.sh prepare <branch> [<old-base>]
#       worktree (durable, $WT_WORKTREES/<branch-leaf>) → rebase onto the march tip
#       (`--onto` from <old-base> when the branch was cut from rewritten or dropped
#       history) → strip transcript links from the rebased messages → the blocking gate,
#       `bash dev/gate.sh --block`, which records its verdict for the rebased head. No push.
#   dev/land.sh merge <branch>   (land's internal step, never a landing path of its own: it runs only
#       inside a landing whose shell holds the hold, LAND_HOLDER its pid; any other call refuses, A21E5)
#       refuses unless the blocking gate's records of the branch head's tree (dev/.block/<tree>-<n>.toml,
#       one per run, in any of the repository's worktrees) hold no red one (a red run stands) and
#       the last one is green, of exactly that commit, made on a clean tree, judging the change
#       from the head's merge base with the march branch,
#       and the main tree is clean; refuses while the last closure matrix (gate.yml's newest run on
#       a dispatch, a gate/** push or a push of the march branch whose head carries `Closes: C<n>`)
#       is red, its red the next item, naming it, and lands with a WARNING, written into the record,
#       while that run has not finished or there is none; then fast-forwards the march branch to it
#       from the main tree and pushes it, the landing's one push (gate.yml runs the full matrix on
#       that push when its head carries `Closes: C<n>`, non-blocking); appends the landing's line to
#       the landing log (below).
#   dev/land.sh wait
#       queues the branch in the landing queue, the main tree's dev/.loop/QUEUE (dev/land_queue.sh, one
#       total order: the orchestrator edits it, a lane appends itself), blocks until it heads the queue,
#       then lands it; `land` takes the hold only at the head of the queue or while it is empty, and pops
#       its own line at its end; a head that takes no free hold within 5 minutes is skipped, with a note
#   dev/land.sh warm
#       right after a commit, in the lane's worktree: outside any hold (it waits while one exists), starts
#       the tree's runner when absent and runs the blocking gate once at JLRUN_PRIO=5, so the landing's
#       gate runs warm; its record stands like any gate run's
#   dev/land.sh land
#       the self-serve landing, run by a batch's agent in its worktree on its branch (L197): refuses
#       a dirty tree; refuses a worktree with no live Kaimon session (dev/kaimon_session.sh: every lane
#       develops in one, its worktree made by dev/lane.sh), printing the call that starts it; refuses,
#       before the hold, when L148's audit window is full (the march tip's last
#       audit entry, or this landing's own when it adds the next one, the commits past it and this
#       landing's, at most 5: dev/audit_window.sh, the
#       ratchet's own program), naming the audit to wait for; holds the machine and the landing (dev/.block/HOLD in the main tree, its pid:
#       one landing at a time, and no other agent's Julia job starts while it exists); fetches and
#       rebases the branch onto the march tip (dev/parity_baseline.toml merged by
#       dev/merge_baseline.py, any other conflict stops the landing, naming the files); refuses a
#       branch more than one commit ahead of the tip (one landing is one commit, A24E1); refuses a
#       change to legacy/ but its deletion whole (WT1 frozen as the agreement oracle); refuses a
#       commit with no `Charter:` line, or one that changes dev/CHARTER.md other than exactly as
#       the maintainer authorised it (its `Charter-change: C<a> C<b> … authorised by Dale <date>` line,
#       the change's parent and new blobs listed with those clauses and date in the main tree's
#       charter_authorised, every changed line in one of them; an edit only adding MARCH row numbers
#       to a Planned citation, as L154 forces, is exempt and named); starts this tree's warm
#       runner when absent; runs `bash dev/gate.sh --block --warm` to a verdict (a run with no verdict
#       once more after 20 s, a red stops the landing with its record standing); lands through
#       `dev/land.sh merge`, the one landing path, on a green run, a cold one included (its checks
#       pass, its timing unjudged), and prints `LOOP <edit_to_landed_s> of 300 s`, the push being the
#       landing; after a cold landing, still holding the machine, judges its timing by a warm run of
#       the landed tree and writes it into the landing's line (judged; unjudged; SLOWER / OVER
#       <stages>, bests / budgets missed under the cap; FAILED <stages>, a check other than the
#       ratchet's; a red record standing); then releases the hold, prints each step's wall and the
#       timing's state (L198). After a line judged red, a landing lands on a judged green run or
#       carries the red landing's excuse file, dev/.loop/excuse/<sha8>, in its own tree (`merge` refuses any other). A
#       worktree whose Manifest.toml names other WasmTarget extensions than Project.toml is refused.
#       L197 judges a landing's own mechanics, own_s, never its waits (A30E1, A33E4): its land's start
#       to its push, less its wait for another landing's hold, plus each red of its own checks to its
#       next attempt (the red history, dev/.loop/reds.tsv); the waits, other landings' reds among them,
#       are queue_wait_s, reported beside it, and need no excuse.
#
# The landing log, the main tree's dev/.loop/landings.tsv (git-ignored; L197 reads it), one line
# per landing, written by `merge` right after its push:
#   landed_at  commit  author_at  land_start  gate_runs  gate_wall_s  land_wall_s  edit_to_landed_s  files  insertions  timing  own_s  queue_wait_s  gate_state
# author_at the earliest author time of the commits the landing brings (the edit), commit the landed
# head, files the paths those commits change and insertions the lines they add (git log --numstat
# over the range), gate_runs and gate_wall_s the gate runs `land` made (0 for a bare `merge`), timing
# the record's (judged, or unjudged when the machine was past the gate's factor cap), own_s the
# landing's own mechanics (its land's start to its push, less its wait for another landing's hold,
# A30E1, plus each red of its own checks from its start to the next attempt's, A33E4: a red on timing
# alone or on the ratchet's L148 or L197 alone is not its own) and queue_wait_s the rest of
# edit_to_landed_s (the holds of others, an audit window, other landings' reds, a stack's author time). A line before
# A30E1 has the first eleven fields. gate_state says whether the landing's gate ran warm (warm; cold;
# cold-after-warm, cold though a gate run of the change warmed the runner first; fresh, no runner); a
# line before it has thirteen fields.
#
# The landing's gate is the blocking gate on this machine (dev/CHARTER.md C10, L194); no CI run
# holds a landing: the last closure matrix's verdict is read, never waited for. The one
# final full gate before PR #128 merges is `bash dev/gate.sh` on the exact merge head.
set -euo pipefail
MARCH=${WT_MARCH_BRANCH:-wt2}
# the main tree: the worktree holding the march branch (the one `merge` fast-forwards), whichever
# worktree this runs in
MAIN=$(git worktree list --porcelain | awk -v b="branch refs/heads/$MARCH" '/^worktree / { w = substr($0, 10) } $0 == b && m == "" { m = w } END { print m }')
[ -n "$MAIN" ] || MAIN=$(git rev-parse --show-toplevel)
WT_WORKTREES=${WT_WORKTREES:-$(dirname "$MAIN")/.worktrees}
# a dev/CHARTER.md change lands only as an exact change the maintainer authorised (A21E6): the main
# tree's git-ignored charter_authorised, written after review and never by a landing commit, one line
# per change, "<parent blob> <new blob> <clause> <date>"
AUTHORISED="$MAIN/dev/.block/charter_authorised"
# a `Charter-change: C<a> C<b> … authorised by Dale <date>` line's clauses and date, "C<a> C<b> … <date>":
# a change to several clauses lands as one commit (L148 counts commits)
CHANGE_SED='s/^Charter-change: \(C[0-9][0-9]*\( C[0-9][0-9]*\)*\) authorised by Dale \([0-9][0-9-]*\)$/\1 \3/p'
# whether the authorisation file $1 lists the change $2 → $3 with exactly the clauses and date of $4
# ("C<a> C<b> … <date>", its lines "<parent blob> <new blob> C<a> C<b> … <date>"), the clauses as a set
authorised() {
    local want o n rest
    want="$(printf '%s\n' ${4% *} | sort -u | tr '\n' ' ')${4##* }"
    [ -f "$1" ] || return 1
    while read -r o n rest; do
        [ "$o" = "$2" ] && [ "$n" = "$3" ] && [ "$(printf '%s\n' ${rest% *} | sort -u | tr '\n' ' ')${rest##* }" = "$want" ] && return 0
    done < "$1"
    return 1
}
# whether clause $1 is one of the clauses $2 ("C<a> C<b> …"); "-", outside any clause, never is
clause_in() {
    case " $2 " in *" $1 "*) [ "$1" != - ] ;; *) return 1 ;; esac
}
# the clause each line of a dev/CHARTER.md text sits in: `- **C<n> ` opens clause n, a line that does
# not start with a space closes it ("-": no clause)
CLAUSE_AWK='/^- \*\*C[0-9]+ / { c = $2; sub(/^\*\*/, "", c); print c; next } /^ / && c != "" { print c; next } { c = ""; print "-" }'
# the clauses a `git diff -U0` touches: a hunk's removed lines in the parent's clause map (O), its
# added lines in the commit's (N)
HUNK_AWK='BEGIN { while ((getline l < O) > 0) o[++i] = l; while ((getline l < N) > 0) n[++j] = l }
/^@@ / { split(substr($2, 2), a, ","); split(substr($3, 2), b, ",")
         oc = (2 in a) ? a[2] : 1; nc = (2 in b) ? b[2] : 1
         for (k = a[1]; k < a[1] + oc; k++) print ((k in o) ? o[k] : "-")
         for (k = b[1]; k < b[1] + nc; k++) print ((k in n) ? n[k] : "-") }'
# over a word diff (--word-diff=porcelain): "yes" when it only adds MARCH row numbers (13.<n>, an
# added "and"): every changed word a row number, none removed that is not added back
EXEMPT_AWK='/^(\+\+\+|---) / { next }
/^[-+]/ { sign = substr($0, 1, 1); n = split(substr($0, 2), w, /[ \t]+/)
          for (x = 1; x <= n; x++) { t = w[x]; if (t == "") continue
              if (t == "and" && sign == "+") continue
              if (t !~ /^13\.[0-9]+[,;.]?$/) { bad = 1; continue }
              sub(/[,;.]$/, "", t); if (sign == "-") rem[t]++; else add[t]++ } }
END { for (t in rem) if (rem[t] > add[t]) bad = 1; print (bad ? "no" : "yes") }'
LOG="$MAIN/dev/.loop/landings.tsv"
STEPS="$MAIN/dev/.loop/steps.tsv"
HOLD="$MAIN/dev/.block/HOLD"
# the landing queue (dev/land_queue.sh; git-ignored): one total order of the lanes' landings
QUEUE="$MAIN/dev/.loop/QUEUE"
# a line in the queue's log (A35E2): a turn's end that the queue's order alone does not say
qlog() { mkdir -p "$(dirname "$QUEUE")"; printf '%s %s\n' "$(iso "$(now)")" "$*" >> "$QUEUE.log"; }
# the red history (dev/block.jl writes a line per red run; git-ignored, kept when a worktree goes) and
# the change's own red seconds over it (A33E4): over the history's lines sorted by start, those of the
# change (field 3, its author time, author and subject) from its author time to this land's start, each
# `own` line (field 4) its span to the next such line's start or the land's, less every wait of the change
# inside that span (A34E3): the wait history's spans (`land`'s wait for the hold, `wait`'s for its turn in
# the queue), the waits file read first (ARGV[1]: start, end, the change), the sorted red history after
REDS="$MAIN/dev/.loop/reds.tsv"
WAITS="$MAIN/dev/.loop/waits.tsv"
OWN_RED_AWK='FILENAME == ARGV[1] { if ($3 == w) { m++; ws[m] = $1 + 0; we[m] = $2 + 0 } next }
$3 == w && $1 + 0 >= au + 0 && $1 + 0 < ls + 0 { n++; s[n] = $1 + 0; k[n] = $4 }
END { t = 0
      for (i = 1; i <= n; i++) if (k[i] == "own") { a = s[i]; b = (i < n ? s[i + 1] : ls); d = b - a
          for (j = 1; j <= m; j++) { lo = (ws[j] > a ? ws[j] : a); hi = (we[j] < b ? we[j] : b); if (hi > lo) d -= hi - lo }
          t += d }
      printf "%.1f\n", t }'
# the landing log's last line, when its timing was judged red (SLOWER, OVER or FAILED, L198): its commit and timing
OWED_AWK='NR == 1 && $11 ~ /^(SLOWER|OVER|FAILED)/ { print substr($2, 1, 8) " " $11 }'
# a red timing's debt (SLOWER, OVER) is lifted by the red landing's excuse file in the landing's own tree,
# it by its first 8 hex digits (a Timing exemption row, or the fix's row): <commit> <owed>; a failed
# check's (FAILED) never is: only a fix lands it, green on a warm run (A21E1)
owed_lifted() { case "${2#* }" in FAILED*) return 1 ;; esac
                git cat-file -e "$1:dev/.loop/excuse/${2:0:8}" 2>/dev/null; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
iso() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($ARGV[0])), "\n"' "${1%.*}"; }
cmd=${1:?usage: dev/land.sh land | wait | warm (in the worktree of the branch) | prepare <branch> [old-base]}
if [ "$cmd" = land ] || [ "$cmd" = warm ] || [ "$cmd" = wait ]; then
    br=$(git symbolic-ref --short -q HEAD) || { echo "land: HEAD is detached: run it on the batch's branch — refusing"; exit 1; }
else
    br=${2:?branch}
fi
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
    echo "prepared $br @ $(git rev-parse --short HEAD): bash dev/land.sh land, in $W, lands it"
    ;;
merge)
    # land's internal step (A21E5): the one landing path is `land`, which holds the hold and passes its
    # pid; a call from anywhere else, or one whose landing no longer holds the hold, refuses
    holder=$(cut -d' ' -f1 "$HOLD" 2>/dev/null || true)
    [ -n "${LAND_HOLDER:-}" ] && [ "$holder" = "$LAND_HOLDER" ] && kill -0 "$holder" 2>/dev/null ||
        { echo "dev/land.sh merge is the internal step of 'bash dev/land.sh land', which the branch's worktree runs — refusing"; exit 1; }
    m_start=$(now)
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
    # its timing (L198): judged, or unjudged when the machine was past the gate's factor cap (a record
    # from before the rule is judged), written into the landing log
    timing=$(sed -n 's/^timing = "\(.*\)"$/\1/p' "$rec"); timing=${timing:-judged}
    # a landing whose judgement after its push failed a check is owed a fix: the next landing lands
    # only on a green warm run, its checks passing where the failure was seen (A21E1); one whose timing
    # was judged red is owed a judged green run or a naming row (L198)
    owed=$(tail -n 1 "$LOG" 2>/dev/null | awk -F'\t' "$OWED_AWK" || true)
    case "${owed#* }" in FAILED*)
        grep -qx 'runner_state = "warm"' "$rec" ||
            { echo "the last landing's judgement failed a check ($owed) and $rec is not of a warm run: a fix lands next, green on a warm run (no excuse file lifts a failed check) — refusing"; exit 1; }
        echo "the last landing's judgement failed a check ($owed); this landing's checks pass on a warm run"; owed="" ;;
    esac
    if [ -n "$owed" ] && [ "$timing" != judged ]; then
        if owed_lifted "$head" "$owed"; then
            echo "the last landing's timing is red ($owed); this landing carries its excuse file: lifted"
        else
            echo "the last landing's timing is red ($owed) and $rec's is $timing: a judged green run lands next, or a landing carrying dev/.loop/excuse/${owed%% *} (a cause outside its change, or a Timing: correctness fix row) — refusing"; exit 1
        fi
    fi
    # the last closure matrix (the full matrix runs only at clause closure, Dale 2026-10-21): gate.yml's
    # newest run on a dispatch, a gate/** push, or a push of the march branch whose head commit carries a
    # `Closes: C<n>` line (read from the commit itself, not the run's name), by workflow name, not
    # --workflow, which finds only a workflow on the default branch (a gate.yml not yet parsed is named
    # by its path), read three times at most, never waited for
    command -v gh >/dev/null || { echo "land: needs the GitHub CLI (gh) to read the last closure matrix — refusing"; exit 1; }
    prev=$(git -C "$MAIN" rev-parse "$MARCH")
    runs=""
    for k in 1 2 3; do
        runs=$(gh run list --limit 200 --json databaseId,status,conclusion,workflowName,event,headBranch,headSha \
            --jq '[.[] | select((.event == "workflow_dispatch" or (.event == "push" and ((.headBranch == "'"$MARCH"'") or (.headBranch | startswith("gate/")))))
                                and (.workflowName == "Gate" or .workflowName == ".github/workflows/gate.yml"))]
                  | sort_by(.databaseId) | reverse | .[] | "\(.status):\(.conclusion // ""):\(.databaseId):\(.headSha):\(.event):\(.headBranch)"' 2>/dev/null) && break
        runs=""; [ $k -lt 3 ] && sleep $((k * 10))
    done
    [ -n "$runs" ] || { echo "land: the GitHub API gives no gate.yml runs: the last closure matrix's verdict is unknown — refusing"; exit 1; }
    matrix="none:::"
    while IFS=: read -r rs rc rid rsha rev rbr; do
        if [ "$rev" = workflow_dispatch ] || [ "${rbr#gate/}" != "$rbr" ] ||
           git -C "$MAIN" log -1 --format=%B "$rsha" 2>/dev/null | grep -qE '^Closes: C[0-9]+'; then
            matrix="$rs:$rc:$rid:${rsha:0:8}"; break
        fi
    done <<<"$runs"
    IFS=: read -r mstatus mconclusion mrun msha <<<"$matrix"
    warning=""
    case "$mstatus:$mconclusion" in
    completed:success) echo "the last closure matrix: green (gate.yml run $mrun on $msha)" ;;
    completed:failure | completed:timed_out | completed:startup_failure)
        echo "the last closure matrix is red, the next item (gate.yml run $mrun on $msha, $mconclusion): fix it first — refusing"; exit 1 ;;
    none:*) warning="no closure matrix has run (no gate.yml run named Gate closure): no verdict" ;;
    completed:*) warning="the last closure matrix has no verdict (gate.yml run $mrun on $msha, $mconclusion)" ;;
    *) warning="the last closure matrix is not finished (gate.yml run $mrun on $msha, $mstatus)" ;;
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
    landed=$(now)
    # the landing log's line (L197), written as soon as the march branch holding it is pushed
    read -r author files ins < <(git log --no-merges --numstat --format='C %at' "$prev..$head" |
        awk -F'\t' '/^C / { split($0, a, " "); if (min == "" || a[2] + 0 < min + 0) min = a[2]; next }
                    NF >= 3 { if (!($3 in seen)) { seen[$3] = 1; n++ } if ($1 != "-") ins += $1 }
                    END { print min, n + 0, ins + 0 }')
    start=${LAND_START:-$m_start}
    mkdir -p "$(dirname "$LOG")"
    [ -s "$LOG" ] || printf 'landed_at\tcommit\tauthor_at\tland_start\tgate_runs\tgate_wall_s\tland_wall_s\tedit_to_landed_s\tfiles\tinsertions\ttiming\town_s\tqueue_wait_s\tgate_state\n' > "$LOG"
    # own_s, the landing's own mechanics (A30E1, A33E4): its land's start to its push, less its wait for
    # another landing's hold, plus its own reds (LAND_OWN_RED); queue_wait_s the rest of its edit to
    # landed (the holds of others, an audit window, other landings' reds, a stack's author time)
    e2l=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "${landed%.*}" "$author")
    own=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1] - $ARGV[2] + $ARGV[3]' "$landed" "$start" "${LAND_HOLD_WAIT:-0}" "${LAND_OWN_RED:-0}")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(iso "$landed")" "$head" "$(iso "$author")" "$(iso "$start")" \
        "${LAND_GATE_RUNS:-0}" "${LAND_GATE_WALL:-0}" "$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$landed" "$start")" \
        "$e2l" "$files" "$ins" "$timing" "$own" "$(perl -e 'my $q = $ARGV[0] - $ARGV[1]; printf "%.1f", $q < 0 ? 0 : $q' "$e2l" "$own")" "${LAND_GATE_STATE:-fresh}" >> "$LOG"
    # the landing's one push is the march branch's, above: gate.yml runs the full matrix on it when its
    # head carries `Closes: C<n>` (no other ref is pushed, L153)
    echo "landed $br @ ${head:0:8} on $MARCH"
    ;;
wait)
    # queues this branch in the landing queue (dev/land_queue.sh) and lands it at its turn: blocks while
    # another lane heads the queue, then runs `bash dev/land.sh land` as its child and acts on its end
    # (A35E1): a refusal before the hold (exit 4, 5 on a full audit window) pops the lane, logs it, and
    # waits until the preflight passes (LAND_PREFLIGHT_ONLY=1) before queueing it again, so a refused
    # head never holds the queue; any other end is the land's. A commit that adds the next audit entry
    # goes to the head of the queue (it is what empties a full window). A lane skipped as a stale head
    # while it waits queues itself again, at the tail.
    W=$(git rev-parse --show-toplevel)
    [ "$W" != "$MAIN" ] || { echo "wait: run it in the lane's worktree, not the main tree — refusing"; exit 1; }
    cd "$W"
    git fetch -q origin
    front=""; git diff --quiet "$(git merge-base "origin/$MARCH" HEAD)" HEAD -- dev/AUDIT.md || front=front
    while :; do
        bash dev/land_queue.sh "$QUEUE" "$HOLD" add "$br" "$(git rev-parse HEAD)" $front
        last=""; qs=$(now)
        while ! qmsg=$(bash dev/land_queue.sh "$QUEUE" "$HOLD" may "$br" 2>&1); do
            case $qmsg in *"$br is not queued"*)
                echo "wait: $br left the queue (a stale head skipped): queued again at the tail"
                bash dev/land_queue.sh "$QUEUE" "$HOLD" add "$br" "$(git rev-parse HEAD)" ;;
            esac
            [ "$qmsg" = "$last" ] || { echo "wait: $qmsg"; last=$qmsg; }
            sleep 5
        done
        echo "wait: $br heads the landing queue: landing"
        # the wait for its turn, in the wait history (A34E3): never the change's own time
        mkdir -p "$(dirname "$WAITS")"
        printf '%s\t%s\t%s\tqueue\n' "$qs" "$(now)" "$(git log -1 --format='%at %ae %s' HEAD)" >> "$WAITS"
        set +e; bash "$W/dev/land.sh" land; st=$?; set -e
        case $st in
        4|5) bash dev/land_queue.sh "$QUEUE" "$HOLD" pop "$br" >/dev/null 2>&1 || true
             qlog "$br $(git rev-parse --short=8 HEAD) refused before the hold (exit $st$([ $st = 5 ] && echo ', the audit window full')): popped, queued again once its preflight passes"
             echo "wait: $br refused before the hold (exit $st): out of the queue until its preflight passes"
             until LAND_PREFLIGHT_ONLY=1 bash "$W/dev/land.sh" land >/dev/null 2>&1; do sleep 30; done
             echo "wait: $br's preflight passes again: queued" ;;
        *) exit "$st" ;;
        esac
    done
    ;;
warm)
    # pre-warms this tree's runner right after a commit, outside any hold, so the landing's gate runs
    # warm (a gate's first run on a server is cold, 80-265 s against 30-40 s warm): waits while a landing
    # holds the machine, starts the runner when absent (it stays up IDLE_MIN, 120 min), and runs the
    # blocking gate once on the committed tree at JLRUN_PRIO=5; its record is a gate run's like any, a
    # red one standing (the change is red: fix it before the landing)
    W=$(git rev-parse --show-toplevel)
    [ "$W" != "$MAIN" ] || { echo "warm: run it in the lane's worktree, not the main tree — refusing"; exit 1; }
    cd "$W"
    [ -z "$(git status --porcelain)" ] || { echo "warm: $W has uncommitted or untracked files: commit first — refusing"; exit 1; }
    waited=0
    while [ -e "$HOLD" ] && kill -0 "$(cut -d' ' -f1 "$HOLD" 2>/dev/null || echo x)" 2>/dev/null; do
        [ $waited -eq 1 ] || echo "warm: waiting while a landing holds the machine ($(cat "$HOLD" 2>/dev/null))"
        waited=1; sleep 5
    done
    export JLRUN_PRIO=5
    out=$(julia --startup-file=no dev/block_runner.jl start 2>&1) || { echo "$out"; echo "warm: this tree's runner did not start — refusing"; exit 1; }
    echo "$out" | tail -1
    set +e; bash dev/gate.sh --block --warm 2>&1 | grep -E '^(BLOCK|  FAIL|  runner)'; st=${PIPESTATUS[0]}; set -e
    echo "warm: the gate ran once on $(git rev-parse --short HEAD) (exit $st); \`bash dev/land.sh land\` lands it on a warm runner unless the tip's src moves under it"
    exit "$st"
    ;;
land)
    # bash reads this whole case statement before it runs any of it, and every way out of this arm
    # is an exit: the rebase below rewrites this file under the running shell, which reads no more
    l_start=$(now); s0=$l_start; steps=""
    step() { local t d; t=$(now); d=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$t" "$s0")
             steps="$steps$1"$'\t'"$d"$'\n'; s0=$t; last_step=$d; echo "land: step $1 $d s"; }
    W=$(git rev-parse --show-toplevel)
    [ "$W" != "$MAIN" ] || { echo "land: run it in the batch's worktree, not the main tree — refusing"; exit 4; }
    [ "$br" != "$MARCH" ] || { echo "land: $br is the march branch — refusing"; exit 4; }
    cd "$W"
    [ -z "$(git status --porcelain)" ] || { echo "land: $W has uncommitted or untracked files — refusing"; git status --short | awk 'NR <= 10'; exit 4; }
    # the worktree's untracked Manifest.toml resolved for this Project.toml: a stale one names extensions
    # WasmTarget no longer has, and a package image built over it fails (A20P23)
    mc=$(bash dev/manifest_check.sh "$W") ||
        { echo "land: $mc: julia --project=. -e 'using Pkg; Pkg.resolve()' — refusing"; exit 4; }
    # every lane develops in a live Kaimon session (dev/kaimon_session.sh; dev/lane.sh makes the lane's
    # worktree a Kaimon project): a worktree with none refuses here, in a second, printing the call that
    # starts one (a CI checkout runs none)
    ks=$(bash dev/kaimon_session.sh "$W") || { echo "land: $ks — refusing"; exit 4; }
    # L148's audit window, read by the ratchet's own program (dev/audit_window.sh) before the hold: the
    # march tip's last audit entry, the commits past its audited-through commit and this landing's,
    # at most 5; a full window refuses here, in a second, never after a gate run its ratchet refuses
    git fetch -q origin
    if ! win=$(bash dev/audit_window.sh "$W" "origin/$MARCH" "$(git rev-list --count --no-merges "origin/$MARCH..HEAD")" HEAD); then
        read -r wsha wcount wcap wentries <<<"$win"
        if [ "$wsha" = - ] || [ "$wcount" -le "$wcap" ]; then
            echo "land: origin/$MARCH's dev/AUDIT.md names no audited-through commit its head holds ($win) — refusing"; exit 4
        fi
        echo "land: the audit window is full ($wcount commits past ${wsha:0:8}, this one included, at most $wcap: L148): wait for audit #$((wentries + 1)) — refusing"; exit 5
    fi
    step preflight
    # LAND_PREFLIGHT_ONLY=1: the preflight alone, its refusals exiting 4 (5 on a full audit window), 0
    # when it passes; `land wait` polls it after a refusal before it queues the lane again (A35E1)
    [ "${LAND_PREFLIGHT_ONLY:-}" != 1 ] || { echo "land: the preflight passes"; exit 0; }
    # the hold, the machine's one (the agents' scheduler reads this file alone, and the orchestrator's
    # hold is this file with owner 0): one landing at a time, and while it exists no other agent's
    # Julia job starts; created only if absent, with this shell's pid, removed only by it
    mkdir -p "$(dirname "$HOLD")"
    # the landing queue (ledger D13): the hold goes only to the lane heading the queue, or to any lane
    # while it is empty; a lane queues itself with `bash dev/land.sh wait`, which lands it at its turn
    qmsg=$(bash dev/land_queue.sh "$QUEUE" "$HOLD" may "$br") ||
        { echo "land: $qmsg — refusing (\`bash dev/land.sh wait\` queues $br and lands it at its turn)"; exit 4; }
    # the landing pops its own line from the queue whatever its end, its turn spent
    release() { [ "$(cut -d' ' -f1 "$HOLD" 2>/dev/null)" = "$$" ] && rm -f "$HOLD"
                bash "$W/dev/land_queue.sh" "$QUEUE" "$HOLD" pop "$br" >/dev/null 2>&1 || true; return 0; }
    trap release EXIT
    waited=0; hs=$(now)
    until ( set -o noclobber; echo "$$ $(iso "$(now)") $br" > "$HOLD" ) 2>/dev/null; do
        owner=$(cut -d' ' -f1 "$HOLD" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "land: $HOLD was left by pid $owner, which has exited: removed"; rm -f "$HOLD"; continue
        fi
        [ $waited -eq 1 ] || echo "land: waiting for the landing that holds the machine ($(cat "$HOLD" 2>/dev/null))"
        waited=1; sleep 2
    done
    step hold
    # the wait for another landing's hold: a queue wait, never the landing's own time (A30E1), its span in the
    # wait history so a later attempt's own_s leaves it out too (A34E3)
    hold_wait=$last_step
    printf '%s\t%s\t%s\thold\n' "$hs" "$(now)" "$(git log -1 --format='%at %ae %s' HEAD)" >> "$WAITS"
    git fetch -q origin
    tip=$(git rev-parse "$MARCH")
    git merge-base --is-ancestor "origin/$MARCH" "$tip" ||
        { echo "land: origin/$MARCH holds commits the main tree's $MARCH lacks — refusing"; exit 1; }
    if ! git merge-base --is-ancestor "$tip" HEAD && ! git rebase -q "$tip"; then
        # a stop whose only conflicts are the ratchet baseline, resolved through dev/merge_baseline.py, and
        # the carried landing log, which an earlier attempt left in the commit and which takes the tip's
        # (it is carried again below)
        while u=$(git diff --name-only --diff-filter=U) && [ -n "$u" ] &&
              [ -z "$(printf '%s\n' "$u" | grep -vx -e dev/parity_baseline.toml -e dev/.loop/landings.log || true)" ]; do
            if printf '%s\n' "$u" | grep -qx dev/parity_baseline.toml; then
                python3 dev/merge_baseline.py dev/parity_baseline.toml || break
                git add dev/parity_baseline.toml
            fi
            if printf '%s\n' "$u" | grep -qx dev/.loop/landings.log; then
                git checkout --ours -- dev/.loop/landings.log && git add dev/.loop/landings.log
            fi
            GIT_EDITOR=true git rebase --continue && break
        done
        if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
            echo "land: the rebase onto $MARCH ${tip:0:8} stopped on a conflict in:"
            git diff --name-only --diff-filter=U | sed 's/^/  /'
            qlog "$br $(git rev-parse --short=8 HEAD) turn ended: the rebase onto $MARCH ${tip:0:8} stopped on a conflict in $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
            git rebase --abort
            echo "land: $br is as it was: rebase it onto $MARCH, resolve, and land again"; exit 1
        fi
    fi
    step rebase
    [ -n "$(git rev-list "$tip..HEAD")" ] || { echo "land: $br holds nothing $MARCH lacks — refusing"; exit 1; }
    # one landing is one commit (A24E1): `merge` judges the head's tree alone, so a commit under it
    # would enter history ungated; a series lands as a sequence of landings
    ahead=$(git rev-list --count "$tip..HEAD")
    [ "$ahead" -eq 1 ] ||
        { echo "land: $br is $ahead commits ahead of $MARCH ${tip:0:8}: one landing is one commit, its own tree gated (A24E1) — land them one at a time — refusing"; exit 1; }
    # legacy/ is frozen (dev/MARCH.md 1.G): WT1 is the agreement oracle as it was moved there, never
    # edited; the one change it takes is its deletion, whole, by its rule (1.F); the commit that
    # creates it (no commit of the march tip's history ever held it) is the move itself, and a
    # deletion followed by a re-creation is refused (audit 34)
    if [ -n "$(git diff --name-only "$tip" HEAD -- legacy/)" ] && [ -n "$(git log -1 --format=%H "$tip" -- legacy)" ] && [ -n "$(git ls-tree -d HEAD legacy)" ]; then
        echo "land: $br changes legacy/ ($(git diff --name-only "$tip" HEAD -- legacy/ | head -3 | tr '\n' ' ')…): legacy/ is frozen, its one change its deletion whole (dev/MARCH.md 1.G) — refusing"; exit 1
    fi
    # L148's window again on the rebased head: a landing that took the hold while this one waited may
    # have filled it since the preflight; the same program on this tree, before the gate
    if ! win=$(bash dev/audit_window.sh "$W"); then
        read -r wsha wcount wcap wentries <<<"$win"
        echo "land: the audit window is full on the rebased head ($wcount commits past ${wsha:0:8}, at most $wcap: L148; $win): wait for audit #$((wentries + 1)) — refusing"; exit 1
    fi
    for h in $(git rev-list --reverse --no-merges "$tip..HEAD"); do
        msg=$(git log -1 --format=%B "$h"); what=$(git log -1 --format='%h %s' "$h")
        printf '%s\n' "$msg" | grep -qE '^Charter: C[0-9]+' || { echo "land: $what has no 'Charter: C<n>' line — refusing"; exit 1; }
        git diff --quiet "$h^" "$h" -- dev/CHARTER.md && continue
        # an edit only adding MARCH row numbers (13.<n>) to a Planned citation, as L154 forces, is exempt
        if [ "$(git diff --word-diff=porcelain --word-diff-regex='[^[:space:]]+' "$h^" "$h" -- dev/CHARTER.md | awk "$EXEMPT_AWK")" = yes ]; then
            echo "land: $what only adds MARCH row numbers to dev/CHARTER.md's Planned citations (L154): exempt"; continue
        fi
        # any other change lands only as the exact change the maintainer authorised: its message names the
        # clause and the authorisation, and the main tree's charter_authorised lists the change's parent
        # and new dev/CHARTER.md blobs with that clause and date (written there after review, never by a
        # landing commit), and every changed line lies in that clause
        a=$(printf '%s\n' "$msg" | sed -n "$CHANGE_SED" | head -1)
        [ -n "$a" ] || { echo "land: $what changes dev/CHARTER.md with no 'Charter-change: C<n> … authorised by Dale <date>' line — refusing"; exit 1; }
        ob=$(git rev-parse "$h^:dev/CHARTER.md"); nb=$(git rev-parse "$h:dev/CHARTER.md")
        authorised "$AUTHORISED" "$ob" "$nb" "$a" ||
            { echo "land: $what's dev/CHARTER.md change ($ob → $nb) is not one the maintainer authorised: after review, in the main tree: echo '$ob $nb $a' >> dev/.block/charter_authorised — refusing"; exit 1; }
        old=$(mktemp); new=$(mktemp)
        git show "$h^:dev/CHARTER.md" | awk "$CLAUSE_AWK" > "$old"; git show "$h:dev/CHARTER.md" | awk "$CLAUSE_AWK" > "$new"
        for c in $(git diff -U0 "$h^" "$h" -- dev/CHARTER.md | awk -v O="$old" -v N="$new" "$HUNK_AWK" | sort -u); do
            clause_in "$c" "${a% *}" ||
                { echo "land: $what changes dev/CHARTER.md $([ "$c" = - ] && echo "outside any clause" || echo "in $c"), outside ${a% *}, the clauses authorised — refusing"; exit 1; }
        done
        rm -f "$old" "$new"
        echo "land: $what changes dev/CHARTER.md inside ${a% *} exactly as authorised ($ob → $nb)"
    done
    step checks
    # the landing log through the previous landing, carried in this landing's own tree (A21E4): the
    # main tree's git-ignored log copied to the tracked dev/.loop/landings.log, into the branch's head
    # commit (its author time kept), before the gate, so the gated tree is the tree that lands
    if [ -s "$LOG" ] && ! cmp -s "$LOG" dev/.loop/landings.log; then
        mkdir -p dev/.loop && cp "$LOG" dev/.loop/landings.log && git add dev/.loop/landings.log
        git commit -q --amend --no-edit
        echo "land: the landing log through $(tail -n 1 "$LOG" | cut -c22-29) carried in ${br}'s head, now $(git rev-parse --short HEAD)"
    fi
    out=$(julia --startup-file=no dev/block_runner.jl start 2>&1) || { echo "$out"; echo "land: this tree's warm runner did not start — refusing"; exit 1; }
    echo "$out" | tail -1
    step runner
    # a landing whose timing was judged red (its line SLOWER or FAILED, L198) is owed a judged green
    # run: the next landing lands only on one (a fix, or a `Timing: correctness fix` row)
    owed=$(tail -n 1 "$LOG" 2>/dev/null | awk -F'\t' "$OWED_AWK" || true)
    if [ -n "$owed" ] && owed_lifted HEAD "$owed"; then
        echo "land: the last landing's timing is red ($owed); this branch carries its excuse file: lifted"; owed=""
    fi
    case "${owed#* }" in
    FAILED*) echo "land: the last landing's judgement failed a check ($owed): this landing lands only as a fix, green on a warm run" ;;
    ?*) echo "land: the last landing's timing is red ($owed): this landing lands only on a judged green run, or carrying dev/.loop/excuse/${owed%% *}" ;;
    esac
    # the gate to a verdict: a green run lands, a cold one whose checks pass included (its timing judged
    # by a warm run after the push, below) unless a judged run is owed; a no-verdict run once more after
    # 20 s; a red stops
    runs=0; gwall=0; cold_again=0; busy_again=0; cold_green=0; glog=$(mktemp)
    while :; do
        runs=$((runs + 1)); g0=$(now)
        set +e; bash dev/gate.sh --block --warm 2>&1 | tee "$glog"; st=${PIPESTATUS[0]}; set -e
        gwall=$(perl -e 'printf "%.1f", $ARGV[0] + $ARGV[1] - $ARGV[2]' "$gwall" "$(now)" "$g0")
        step "gate-$runs"
        case $st in
        0) if grep -q '^BLOCK green (timing unjudged: the run was cold' "$glog"; then
               if [ -n "$owed" ] && [ $cold_again -eq 0 ]; then
                   cold_again=1; echo "land: the run was cold and a judged run is owed: the gate once more"; continue
               fi
               cold_green=1
           fi
           break ;;
        1) qlog "$br $(git rev-parse --short=8 HEAD) turn ended: the gate is red, its record $(sed -n 's/^BLOCK .*→ \(dev\/\.block\/.*\.toml\)$/\1/p' "$glog" | tail -1) standing"
           echo "land: the gate is red and its record stands: fix it in a new commit, then land again"; exit 1 ;;
        3) if [ $busy_again -eq 0 ]; then
               busy_again=1; echo "land: no verdict: the gate once more after 20 s"; sleep 20
           else
               echo "land: no verdict after its retries — not landed"; exit 3
           fi ;;
        *) echo "land: the gate exited $st with no verdict — not landed"; exit "$st" ;;
        esac
    done
    # a commit that says `Closes: C<n>` (the full matrix's trigger, gate.yml) lands only on a gate whose
    # ratchet reads C<n> CLOSED on this tree
    closes=$(git log --format=%B "$tip..HEAD" | sed -n 's/^Closes: \(C[0-9][0-9]*\)$/\1/p' | sort -u)
    if [ -n "$closes" ]; then
        crec=$(sed -n 's/^BLOCK .*→ \(dev\/\.block\/.*\.toml\)$/\1/p' "$glog"); rlog="$(sed -n 's/^logs = "\(.*\)"$/\1/p' "$crec")/ratchet.log"
        for c in $closes; do
            grep -qE "^$c +.* CLOSED( |$)" "$rlog" 2>/dev/null ||
                { echo "land: a commit says 'Closes: $c', but this gate's ratchet ($rlog) does not read $c CLOSED — refusing"; exit 1; }
        done
        echo "land: Closes: $(echo $closes): the ratchet reads each CLOSED; the full matrix runs on this landing's push"
    fi
    # whether the landing's gate ran warm (its record's runner_state): cold after a warm-up of this change
    # on this tree's runner (an earlier gate record of a commit with the same author time, author and
    # subject, finished before this land began) is reported, the warm-up having not held (the tip's src
    # moved under it, or the runner restarted); the tracker counts the cold landings (L197)
    grec=$(sed -n 's/^BLOCK .*→ \(dev\/\.block\/.*\.toml\)$/\1/p' "$glog" | tail -1)
    gstate=$(sed -n 's/^runner_state = "\(.*\)"$/\1/p' "$grec" 2>/dev/null || true)
    case $gstate in
    warm) gate_state=warm ;;
    cold*) gate_state=cold; warmed=""
           want_g=$(git log -1 --format='%at %ae %s' HEAD)
           for f in dev/.block/*-*.toml; do
               [ -f "$f" ] && [ "$f" != "$grec" ] || continue
               fin=$(sed -n 's/^finished = //p' "$f")
               [ -n "$fin" ] && perl -e 'exit !($ARGV[0] < $ARGV[1])' "$fin" "$l_start" || continue
               [ "$(git log -1 --format='%at %ae %s' "$(sed -n 's/^head = "\(.*\)"$/\1/p' "$f")" 2>/dev/null)" = "$want_g" ] && warmed=$(basename "$f" .toml)
           done
           if [ -n "$warmed" ]; then
               gate_state=cold-after-warm
               echo "land: the gate ran cold after a warm-up of this change (record ${warmed:0:8}-${warmed##*-}): $gstate"
           fi ;;
    *) gate_state=fresh ;;
    esac
    # the change's own reds (A33E4): from the red history (the main tree's dev/.loop/reds.tsv, which
    # dev/block.jl writes and a worktree's removal leaves, A33E5), each red run of a commit of the same
    # change (its author time, author and subject, as a rebase or an amend keeps them) after its author
    # time, before this land: an `own` red counts from its start to the next attempt's (the fix), a
    # `queue` red (timing alone; the ratchet on L148 or L197 alone) counts as queue time
    want=$(git log -1 --format='%at %ae %s' HEAD)
    touch "$WAITS"
    own_red=$( { sort -t "$(printf '\t')" -k1,1n "$REDS" 2>/dev/null || true; } | awk -F'\t' -v w="$want" -v au="${want%% *}" -v ls="$l_start" "$OWN_RED_AWK" "$WAITS" -)
    LAND_HOLDER=$$ LAND_START=$l_start LAND_OWN_RED=$own_red LAND_HOLD_WAIT=$hold_wait LAND_GATE_STATE=$gate_state LAND_GATE_RUNS=$runs LAND_GATE_WALL=$gwall bash "$W/dev/land.sh" merge "$br"
    step land
    head=$(git rev-parse HEAD)
    line=$(tail -1 "$LOG")
    [ "$(printf '%s' "$line" | cut -f2)" = "$head" ] || { echo "land: the landing log's last line is not ${head:0:8}'s"; exit 1; }
    # the push is the landing
    echo "LOOP $(printf '%s' "$line" | cut -f12) of 300 s (own; queue wait $(printf '%s' "$line" | cut -f13) s)"
    # a cold landing's timing, judged now by a warm run of the landed tree (the change taken from the
    # march tip it landed on), the machine still held: judged, unjudged (the run could not judge), or
    # SLOWER <stages> / FAILED <stages> (its record red, standing), written into the landing's line
    if [ $cold_green -eq 1 ]; then
        echo "land: the landing's gate was cold: its timing judged now by a warm run, the machine still held"
        verdict_t=unjudged
        for k in 1 2; do
            set +e; bash dev/gate.sh --block --warm --base "$tip" 2>&1 | tee "$glog"; st=${PIPESTATUS[0]}; set -e
            step "judge-$k"
            rec=$(sed -n 's/^BLOCK .*→ \(dev\/\.block\/.*\.toml\)$/\1/p' "$glog")
            field() { [ -f "$rec" ] && sed -n "s/^$1 = \[\(.*\)\]\$/\1/p" "$rec" | tr -d '",' || true; }
            case $st in
            0) if [ -f "$rec" ] && grep -qx 'timing = "judged"' "$rec"; then verdict_t=judged; break; fi
               verdict_t=$(sed -n 's/^timing = "\(.*\)"$/\1/p' "$rec"); verdict_t=${verdict_t:-unjudged}
               grep -q '^BLOCK green (timing unjudged: the run was cold' "$glog" || break ;;
            1) # FAILED for any check that failed, the ratchet's included (a lock red on the landed head,
               # though the cold run passed it, owes a fix, A21E1); otherwise the timing missed under the
               # cap, SLOWER (a best) and OVER (a budget)
               chk=$(field checks_failed)
               slow=$(field timing_slower); over=$(field timing_over)
               if [ -n "$chk" ]; then verdict_t="FAILED $chk"
               else verdict_t="${slow:+SLOWER $slow}${slow:+${over:+ }}${over:+OVER $over}"; verdict_t=${verdict_t:-unjudged}; fi
               break ;;
            *) break ;;
            esac
        done
        n=$(wc -l < "$LOG" | tr -d ' ')
        awk -F'\t' -v OFS='\t' -v n="$n" -v h="$head" -v t="$verdict_t" 'NR == n && $2 == h { $11 = t } { print }' "$LOG" > "$LOG.new"
        mv "$LOG.new" "$LOG"
        echo "land: the timing of ${head:0:8}: $verdict_t"
        case $verdict_t in SLOWER* | OVER* | FAILED*)
            echo "land: its record is red and stands: the next landing lands on a judged green run, or carries dev/.loop/excuse/${head:0:8} (a cause outside the change, or a Timing: correctness fix row; L198); a FAILED check only as a fix green on a warm run" ;;
        esac
    fi
    rm -f "$glog"
    # the steps, each landing's walls, before the hold is released
    printf '%s' "$steps" | awk -v h="$head" -F'\t' '{ print h "\t" $1 "\t" $2 }' >> "$STEPS"
    release
    echo "land: steps $(printf '%s' "$steps" | awk -F'\t' '{ printf "%s%s %s s", (NR > 1 ? ", " : ""), $1, $2 }')"
    # the unjudged streak (L198): the log's last lines in a row whose timing is unjudged, newest first,
    # counted until one whose commit's tree has a green run with its timing judged recorded in any
    # worktree (`bash dev/gate.sh --block --warm` on a quiet machine judges it)
    unjudged=0
    for c in $(awk -F'\t' 'NR > 1 { s = ($11 ~ /^unjudged/) ? $2 " " s : "" } END { print s }' "$LOG"); do
        t=$(git rev-parse "$c^{tree}"); judged=0
        for w in $(git worktree list --porcelain | sed -n 's/^worktree //p'); do
            for f in "$w/dev/.block/$t"-*.toml; do
                [ -f "$f" ] && grep -qx 'verdict = "green"' "$f" && grep -qx 'timing = "judged"' "$f" && judged=1
            done
        done
        [ $judged -eq 0 ] || break
        unjudged=$((unjudged + 1))
    done
    owed=$(tail -n 1 "$LOG" | awk -F'\t' "$OWED_AWK" || true)
    if [ -n "$owed" ]; then
        echo "land: timing red ($owed): owed by the next landing, a judged green run or dev/.loop/excuse/${owed%% *}"
    elif [ "$unjudged" -gt 0 ]; then
        echo "land: timing unjudged for $unjudged landing(s); judge on a quiet machine: bash dev/gate.sh --block --warm"
    else
        echo "land: timing judged"
    fi
    # the rebuild's src progress, after every landing (L208, dev/LEDGER.md D40)
    bash "$W/dev/src_progress.sh"
    exit 0
    ;;
*) echo "unknown command $cmd"; exit 1 ;;
esac
