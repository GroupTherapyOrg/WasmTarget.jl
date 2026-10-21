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
#       and the main tree is clean; refuses while the full matrix on the last landed head (its
#       gate.yml run) is red, its red being the next item, and lands with a WARNING, written into
#       the record, while that run has not finished or there is none; then fast-forwards the march
#       branch to it from the main tree, pushes it, and pushes the head to march/<branch-leaf>,
#       where gate.yml runs the full matrix on it, non-blocking; appends the landing's line to the
#       landing log (below).
#   dev/land.sh land
#       the self-serve landing, run by a batch's agent in its worktree on its branch (L197): refuses
#       a dirty tree; holds the machine and the landing (dev/.block/HOLD in the main tree, its pid:
#       one landing at a time, and no other agent's Julia job starts while it exists); fetches and
#       rebases the branch onto the march tip (dev/parity_baseline.toml merged by
#       dev/merge_baseline.py, any other conflict stops the landing, naming the files); refuses a
#       commit with no `Charter:` line, or one that changes dev/CHARTER.md other than exactly as
#       the maintainer authorised it (its `Charter-change: <clause> authorised by Dale <date>` line,
#       the change's parent and new blobs listed with that clause and date in the main tree's
#       charter_authorised, every changed line in that clause; an edit only adding MARCH row numbers
#       to a Planned citation, as L154 forces, is exempt and named); starts this tree's warm
#       runner when absent; runs `bash dev/gate.sh --block --warm` to a verdict (a run with no verdict
#       once more after 20 s, a red stops the landing with its record standing); lands through
#       `dev/land.sh merge`, the one landing path, on a green run, a cold one included (its checks
#       pass, its timing unjudged), and prints `LOOP <edit_to_landed_s> s`, the push being the
#       landing; after a cold landing, still holding the machine, judges its timing by a warm run of
#       the landed tree and writes it into the landing's line (judged; unjudged; SLOWER / OVER
#       <stages>, bests / budgets missed under the cap; FAILED <stages>, a check other than the
#       ratchet's; a red record standing); then releases the hold, prints each step's wall and the
#       timing's state (L198). After a line judged red, a landing lands on a judged green run or
#       names the red landing in a dev/MARCH.md row of its own tree (`merge` refuses any other). A
#       worktree whose Manifest.toml names other WasmTarget extensions than Project.toml is refused.
#
# The landing log, the main tree's dev/.loop/landings.tsv (git-ignored; L197 reads it), one line
# per landing, written by `merge` right after its push:
#   landed_at  commit  author_at  land_start  gate_runs  gate_wall_s  land_wall_s  edit_to_landed_s  files  insertions  timing
# author_at the earliest author time of the commits the landing brings (the edit), commit the landed
# head, files the paths those commits change and insertions the lines they add (git log --numstat
# over the range), gate_runs and gate_wall_s the gate runs `land` made (0 for a bare `merge`), timing
# the record's (judged, or unjudged when the machine was past the gate's factor cap).
#
# The landing's gate is the blocking gate on this machine (dev/CHARTER.md C10, L194); no CI run
# holds a landing: the matrix's verdict on the last landed head is read, never waited for. The one
# final full gate before PR #122 merges is `bash dev/gate.sh` on the exact merge head.
set -euo pipefail
MARCH=${WT_MARCH_BRANCH:-wt-p0-strict-hygiene}
# the main tree: the worktree holding the march branch (the one `merge` fast-forwards), whichever
# worktree this runs in
MAIN=$(git worktree list --porcelain | awk -v b="branch refs/heads/$MARCH" '/^worktree / { w = substr($0, 10) } $0 == b && m == "" { m = w } END { print m }')
[ -n "$MAIN" ] || MAIN=$(git rev-parse --show-toplevel)
WT_WORKTREES=${WT_WORKTREES:-$(dirname "$MAIN")/.worktrees}
# a dev/CHARTER.md change lands only as an exact change the maintainer authorised (A21E6): the main
# tree's git-ignored charter_authorised, written after review and never by a landing commit, one line
# per change, "<parent blob> <new blob> <clause> <date>"
AUTHORISED="$MAIN/dev/.block/charter_authorised"
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
HOLD="$MAIN/dev/.block/HOLD"
# the landing log's last line, when its timing was judged red (SLOWER, OVER or FAILED, L198): its commit and timing
OWED_AWK='NR == 1 && $11 ~ /^(SLOWER|OVER|FAILED)/ { print substr($2, 1, 8) " " $11 }'
# a red landing's debt is lifted by a dev/MARCH.md row in the landing's own tree naming it by its
# first 8 hex digits (a Timing exemption row, or the fix's row): <commit> <owed>
owed_lifted() { git show "$1:dev/MARCH.md" 2>/dev/null | grep '^| 13\.' | grep -q "${2:0:8}"; }
now() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
iso() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($ARGV[0])), "\n"' "${1%.*}"; }
cmd=${1:?usage: dev/land.sh land (in the worktree of the branch) | prepare <branch> [old-base]}
if [ "$cmd" = land ]; then
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
    echo "prepared $br @ $(git rev-parse --short HEAD): dev/land.sh merge $br lands it"
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
    # a landing whose timing was judged red is owed a judged green run: until one lands, a landing
    # whose timing is unjudged is refused (L198)
    owed=$(tail -n 1 "$LOG" 2>/dev/null | awk -F'\t' "$OWED_AWK" || true)
    if [ -n "$owed" ] && [ "$timing" != judged ]; then
        if owed_lifted "$head" "$owed"; then
            echo "the last landing's timing is red ($owed); this landing's dev/MARCH.md names it: lifted"
        else
            echo "the last landing's timing is red ($owed) and $rec's is $timing: a judged green run lands next, or a landing whose dev/MARCH.md names ${owed%% *} (a fix, or a Timing: correctness fix row) — refusing"; exit 1
        fi
    fi
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
    landed=$(now)
    # the landing log's line (L197), written as soon as the march branch holding it is pushed
    read -r author files ins < <(git log --no-merges --numstat --format='C %at' "$prev..$head" |
        awk -F'\t' '/^C / { split($0, a, " "); if (min == "" || a[2] + 0 < min + 0) min = a[2]; next }
                    NF >= 3 { if (!($3 in seen)) { seen[$3] = 1; n++ } if ($1 != "-") ins += $1 }
                    END { print min, n + 0, ins + 0 }')
    start=${LAND_START:-$m_start}
    mkdir -p "$(dirname "$LOG")"
    [ -s "$LOG" ] || printf 'landed_at\tcommit\tauthor_at\tland_start\tgate_runs\tgate_wall_s\tland_wall_s\tedit_to_landed_s\tfiles\tinsertions\ttiming\n' > "$LOG"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(iso "$landed")" "$head" "$(iso "$author")" "$(iso "$start")" \
        "${LAND_GATE_RUNS:-0}" "${LAND_GATE_WALL:-0}" "$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$landed" "$start")" \
        "$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "${landed%.*}" "$author")" "$files" "$ins" "$timing" >> "$LOG"
    # the full matrix on the landed head, non-blocking (gate.yml runs on march/**)
    git push -q --force origin "$head:refs/heads/march/$leaf"
    echo "landed $br @ ${head:0:8} on $MARCH; the full matrix: gh run list --branch march/$leaf"
    ;;
land)
    # bash reads this whole case statement before it runs any of it, and every way out of this arm
    # is an exit: the rebase below rewrites this file under the running shell, which reads no more
    l_start=$(now); s0=$l_start; steps=""
    step() { local t d; t=$(now); d=$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$t" "$s0")
             steps="$steps$1"$'\t'"$d"$'\n'; s0=$t; echo "land: step $1 $d s"; }
    W=$(git rev-parse --show-toplevel)
    [ "$W" != "$MAIN" ] || { echo "land: run it in the batch's worktree, not the main tree — refusing"; exit 1; }
    [ "$br" != "$MARCH" ] || { echo "land: $br is the march branch — refusing"; exit 1; }
    cd "$W"
    [ -z "$(git status --porcelain)" ] || { echo "land: $W has uncommitted or untracked files — refusing"; git status --short | awk 'NR <= 10'; exit 1; }
    # the worktree's untracked Manifest.toml resolved for this Project.toml: a stale one names extensions
    # WasmTarget no longer has, and a package image built over it fails (A20P23)
    want=$(awk '/^\[extensions\]/ { f = 1; next } /^\[/ { f = 0 } f && NF { print $1 }' Project.toml | sort | tr '\n' ' ')
    have=$([ -f Manifest.toml ] && awk '/^ *\[deps\.WasmTarget\.extensions\]/ { f = 1; next } /^ *\[/ { f = 0 } f && NF { print $1 }' Manifest.toml | sort | tr '\n' ' ' || true)
    [ "$want" = "$have" ] ||
        { echo "land: Manifest.toml's WasmTarget extensions ($have) are not Project.toml's ($want): julia --project=. -e 'using Pkg; Pkg.resolve()' — refusing"; exit 1; }
    step preflight
    # the hold, the machine's one (the agents' scheduler reads this file alone, and the orchestrator's
    # hold is this file with owner 0): one landing at a time, and while it exists no other agent's
    # Julia job starts; created only if absent, with this shell's pid, removed only by it
    mkdir -p "$(dirname "$HOLD")"
    release() { [ "$(cut -d' ' -f1 "$HOLD" 2>/dev/null)" = "$$" ] && rm -f "$HOLD"; return 0; }
    trap release EXIT
    waited=0
    until ( set -o noclobber; echo "$$ $(iso "$(now)") $br" > "$HOLD" ) 2>/dev/null; do
        owner=$(cut -d' ' -f1 "$HOLD" 2>/dev/null || true)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            echo "land: $HOLD was left by pid $owner, which has exited: removed"; rm -f "$HOLD"; continue
        fi
        [ $waited -eq 1 ] || echo "land: waiting for the landing that holds the machine ($(cat "$HOLD" 2>/dev/null))"
        waited=1; sleep 2
    done
    step hold
    git fetch -q origin
    tip=$(git rev-parse "$MARCH")
    git merge-base --is-ancestor "origin/$MARCH" "$tip" ||
        { echo "land: origin/$MARCH holds commits the main tree's $MARCH lacks — refusing"; exit 1; }
    if ! git merge-base --is-ancestor "$tip" HEAD && ! git rebase -q "$tip"; then
        # a stop whose only conflict is the ratchet baseline resolves through dev/merge_baseline.py
        while [ "$(git diff --name-only --diff-filter=U)" = "dev/parity_baseline.toml" ]; do
            python3 dev/merge_baseline.py dev/parity_baseline.toml || break
            git add dev/parity_baseline.toml
            GIT_EDITOR=true git rebase --continue && break
        done
        if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
            echo "land: the rebase onto $MARCH ${tip:0:8} stopped on a conflict in:"
            git diff --name-only --diff-filter=U | sed 's/^/  /'
            git rebase --abort
            echo "land: $br is as it was: rebase it onto $MARCH, resolve, and land again"; exit 1
        fi
    fi
    step rebase
    [ -n "$(git rev-list "$tip..HEAD")" ] || { echo "land: $br holds nothing $MARCH lacks — refusing"; exit 1; }
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
        a=$(printf '%s\n' "$msg" | sed -n 's/^Charter-change: \(C[0-9][0-9]*\) authorised by Dale \([0-9-]*\)$/\1 \2/p' | head -1)
        [ -n "$a" ] || { echo "land: $what changes dev/CHARTER.md with no 'Charter-change: <clause> authorised by Dale <date>' line — refusing"; exit 1; }
        ob=$(git rev-parse "$h^:dev/CHARTER.md"); nb=$(git rev-parse "$h:dev/CHARTER.md")
        grep -qx "$ob $nb $a" "$AUTHORISED" 2>/dev/null ||
            { echo "land: $what's dev/CHARTER.md change ($ob → $nb) is not one the maintainer authorised: after review, in the main tree: echo '$ob $nb $a' >> dev/.block/charter_authorised — refusing"; exit 1; }
        old=$(mktemp); new=$(mktemp)
        git show "$h^:dev/CHARTER.md" | awk "$CLAUSE_AWK" > "$old"; git show "$h:dev/CHARTER.md" | awk "$CLAUSE_AWK" > "$new"
        for c in $(git diff -U0 "$h^" "$h" -- dev/CHARTER.md | awk -v O="$old" -v N="$new" "$HUNK_AWK" | sort -u); do
            [ "$c" = "${a%% *}" ] ||
                { echo "land: $what changes dev/CHARTER.md $([ "$c" = - ] && echo "outside any clause" || echo "in $c"), outside ${a%% *}, the clause authorised — refusing"; exit 1; }
        done
        rm -f "$old" "$new"
        echo "land: $what changes dev/CHARTER.md inside ${a%% *} exactly as authorised ($ob → $nb)"
    done
    step checks
    out=$(julia --startup-file=no dev/block_runner.jl start 2>&1) || { echo "$out"; echo "land: this tree's warm runner did not start — refusing"; exit 1; }
    echo "$out" | tail -1
    step runner
    # a landing whose timing was judged red (its line SLOWER or FAILED, L198) is owed a judged green
    # run: the next landing lands only on one (a fix, or a `Timing: correctness fix` row)
    owed=$(tail -n 1 "$LOG" 2>/dev/null | awk -F'\t' "$OWED_AWK" || true)
    if [ -n "$owed" ] && owed_lifted HEAD "$owed"; then
        echo "land: the last landing's timing is red ($owed); this branch's dev/MARCH.md names it: lifted"; owed=""
    fi
    [ -z "$owed" ] || echo "land: the last landing's timing is red ($owed): this landing lands only on a judged green run, or with a dev/MARCH.md row naming ${owed%% *}"
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
        1) echo "land: the gate is red and its record stands: fix it in a new commit, then land again"; exit 1 ;;
        3) if [ $busy_again -eq 0 ]; then
               busy_again=1; echo "land: no verdict: the gate once more after 20 s"; sleep 20
           else
               echo "land: no verdict after its retries — not landed"; exit 3
           fi ;;
        *) echo "land: the gate exited $st with no verdict — not landed"; exit "$st" ;;
        esac
    done
    LAND_HOLDER=$$ LAND_START=$l_start LAND_GATE_RUNS=$runs LAND_GATE_WALL=$gwall bash "$W/dev/land.sh" merge "$br"
    step land
    head=$(git rev-parse HEAD)
    line=$(tail -1 "$LOG")
    [ "$(printf '%s' "$line" | cut -f2)" = "$head" ] || { echo "land: the landing log's last line is not ${head:0:8}'s"; exit 1; }
    # the push is the landing
    echo "LOOP $(printf '%s' "$line" | cut -f8) s"
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
            1) # FAILED for a check other than the ratchet's (the cold run judged the same tree's checks);
               # otherwise the timing missed under the cap, SLOWER (a best) and OVER (a budget)
               chk=$(field checks_failed | tr ' ' '\n' | grep -vx ratchet | tr '\n' ' ' | sed 's/ *$//' || true)
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
            echo "land: its record is red and stands: the next landing lands on a judged green run, or names ${head:0:8} in a dev/MARCH.md row (a fix, or a Timing: correctness fix row; L198)" ;;
        esac
    fi
    rm -f "$glog"
    release
    printf '%s' "$steps" | awk -v h="$head" -F'\t' '{ print h "\t" $1 "\t" $2 }' >> "$(dirname "$LOG")/steps.tsv"
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
        echo "land: timing red ($owed): owed by the next landing, a judged green run or a dev/MARCH.md row naming ${owed%% *}"
    elif [ "$unjudged" -gt 0 ]; then
        echo "land: timing unjudged for $unjudged landing(s); judge on a quiet machine: bash dev/gate.sh --block --warm"
    else
        echo "land: timing judged"
    fi
    exit 0
    ;;
*) echo "unknown command $cmd"; exit 1 ;;
esac
