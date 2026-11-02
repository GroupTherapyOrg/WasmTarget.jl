#!/usr/bin/env bash
# dev/no_counterpart_spend.sh — the one spend step for an admission of dev/quarantine_no_counterpart.txt, which
# only shrinks once it exists (L227, D20): the lead admits one change's added keys by a line `admit:<hash> <note>`
# in the common dir's git-ignored wt-no-counterpart-admit, <hash> the blob id (`git hash-object`) of exactly
# the keys it adds, sorted, one per line; the landing that adds them spends it, appending `used:<hash> <landed
# sha>`, so the line admits one landing (the form of 1d56789d's content authorisation, A92E1).
#   bash dev/no_counterpart_spend.sh hash <base> <head>   the hash of the keys <head>'s list adds over <base>'s,
#                                                          empty when it adds none (the ratchet's L227 reads it)
#   bash dev/no_counterpart_spend.sh                       after a landing (dev/ship.sh's landed hook, in its
#                                                          scratch tree): spend HEAD's admission, if it added keys
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
LIST=dev/quarantine_no_counterpart.txt
# the keys a revision's list holds, comments and blank lines aside, each key the text before ` — `
keys() { git show "$1:$LIST" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed 's/ — .*//; s/[[:space:]]*$//' | LC_ALL=C sort || true; }
added_hash() {
    local added
    added=$(LC_ALL=C comm -13 <(keys "$1") <(keys "$2"))
    [ -n "$added" ] && printf '%s\n' "$added" | git hash-object --stdin
    return 0
}
if [ "${1:-}" = hash ]; then
    [ $# -eq 3 ] || { echo "no_counterpart_spend: hash <base> <head>" >&2; exit 2; }
    added_hash "$2" "$3"; exit 0
fi
[ $# -eq 0 ] || { echo "no_counterpart_spend: no arguments, or hash <base> <head>" >&2; exit 2; }
h=$(added_hash HEAD~1 HEAD)
[ -n "$h" ] || exit 0
printf 'used:%s %s\n' "$h" "$(git rev-parse HEAD)" >> "$(git rev-parse --path-format=absolute --git-common-dir)/wt-no-counterpart-admit"
echo "ship: spent the no-counterpart admission $h"
