#!/bin/zsh
# THE full capped gate with a STALL WATCHDOG (2026-07-05, after a day of silent
# hangs: overnight machine sleep froze a gate at 6/10 for 5h; a precompile-lock
# collision wedged a relaunch; a Windows CI job sat 3h19m on GitHub's 6h default).
# Behavior: launch detached; if the log stops growing for STALL_MIN minutes,
# kill + relaunch (once); write EXIT= to the log either way.
# Usage: dev/run_full_gate.sh <logfile>
set -u
LOG="${1:?usage: run_full_gate.sh <logfile>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STALL_MIN=12
launch() {
    : > "$LOG"
    WT_TEST_CONCURRENCY=2 julia --project="$REPO" -e "using Pkg; Pkg.test()" >> "$LOG" 2>&1 &
    GATE_PID=$!
}
run_watched() {
    launch
    while kill -0 $GATE_PID 2>/dev/null; do
        sleep 60
        local age=$(( $(date +%s) - $(stat -f %m "$LOG") ))
        if (( age > STALL_MIN * 60 )); then
            echo "WATCHDOG: log silent ${age}s — killing stalled gate" >> "$LOG"
            kill -9 $GATE_PID 2>/dev/null
            pkill -9 -P $GATE_PID 2>/dev/null
            return 1
        fi
    done
    wait $GATE_PID
    return $?
}
if run_watched; then
    echo "EXIT=0" >> "$LOG"
else
    rc=$?
    if grep -q "WATCHDOG" "$LOG"; then
        echo "WATCHDOG: relaunching once" >> "$LOG"
        if run_watched; then echo "EXIT=0" >> "$LOG"; else echo "EXIT=$?" >> "$LOG"; fi
    else
        echo "EXIT=$rc" >> "$LOG"
    fi
fi
