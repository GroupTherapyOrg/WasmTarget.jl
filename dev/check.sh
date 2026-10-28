#!/usr/bin/env bash
# The landing check on wt3 (dev/ship.sh runs it): WasmTarget loads, so every construction checks
# itself at load; the ratchet holds, every lock but those test/ratchet_open.txt lists; and every test
# of ported code passes (test/src_tests.jl). About a minute, one Julia at a time.
set -uo pipefail
cd "$(dirname "$0")/.."
. dev/depot.sh; wt_depot_export "$(pwd)"
mkdir -p .wtd; s0=$(date +%s)
julia --project=. --startup-file=no test/parity_ratchet.jl > .wtd/ratchet.out 2>&1
broken=$(grep -oE '^[LR][0-9]+_[a-z0-9_]+ +[^ ]+ +(❌|BROKEN)|^[LR][0-9]+_[a-z0-9_]+.*BROKEN' .wtd/ratchet.out | grep -oE '^[LR][0-9]+' | sort -u)
open=$(grep -oE '^[LR][0-9]+' test/ratchet_open.txt 2>/dev/null | sort -u)
new=$(comm -23 <(printf '%s\n' $broken | sed '/^$/d') <(printf '%s\n' $open | sed '/^$/d'))
if ! grep -q '── charter' .wtd/ratchet.out; then echo "check: the ratchet did not finish"; tail -30 .wtd/ratchet.out; exit 1; fi
if [ -n "$new" ]; then echo "check: broken locks: $new"; grep -E "^($(echo $new | tr ' ' '|'))_" .wtd/ratchet.out | cut -c1-300; exit 1; fi
echo "check: ratchet holds ($(( $(date +%s) - s0 ))s)"
julia --project=. --startup-file=no test/src_tests.jl || { echo "check: src tests red"; exit 1; }
grep -E '^ *· src:' .wtd/ratchet.out | sed 's/^ *· //'
echo "check: green ($(( $(date +%s) - s0 ))s)"
