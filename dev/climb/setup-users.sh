#!/usr/bin/env bash
# dev/climb/setup-users.sh — the climb's build users (dev/climb/HILL.md, "The door"; Dale 2026-11-10, D-E and D-H):
# run once by Dale with sudo, after the lead has read it. Every process that loads repository code or acts on a
# model's output (the agents, Kaimon's servers and sessions, every Julia, node and java of a measurement, a score, a
# parse, a landing check and a regen) runs as one of these users, never as Dale. Precedent: Nix's build users
# (nixbld*, one group, each build's processes killed by user); how this differs: an agent needs the network to reach
# its model, so an agent's user has it and its Bash rests on Claude Code's own sandbox.
#
#   sudo bash dev/climb/setup-users.sh            print every step, ask y, then make the users (idempotent: a step
#                                                 already done is said so and skipped)
#   sudo bash dev/climb/setup-users.sh --undo     print every step, ask y, then reverse each one
#   bash dev/climb/setup-users.sh --plan          print the steps and exit, no root needed
#
# What it makes:
# - the group _wtclimb and one user per role (no login shell, no password, hidden), its home
#   /Users/Shared/wt-climb/u/<user>, owned by the user, mode 700, with an ACL that lets the owner (the account that
#   ran sudo) read and list it, inherited by everything the user writes there;
# - /Users/Shared/wt-climb (the owner's, 755), its in/ (the owner's, 711: a run's files, each run's directory readable
#   by its one user through an ACL the driver sets) and bin/ (the owner's, 755: the climb's pinned claude);
# - /etc/sudoers.d/wt-climb: the owner may run any command as those users and no other, with no password, checked by
#   `visudo -cf` before it is installed;
# - each user a line of /usr/lib/cron/cron.deny and at.deny: none of them can leave a job behind;
# - automatic installs of macOS updates off while the climb runs (AutomaticallyInstallMacOSUpdates false; its value
#   before is kept in /var/db/wt-climb-setup.prev and restored by --undo), since a reboot needs Dale's FileVault
#   password and ends the climb until he logs in.
set -euo pipefail

GROUP=_wtclimb
GID=461
# role user:uid (dev/climb/door.py ROLES names the same users; the ratchet's L204 holds the two lists equal)
USERS=(_wtk1:462 _wtk2:463 _wtr1:464 _wtr2:465 _wtr3:466 _wtm1:467 _wtm2:468 _wtland:469 _wtdep:470)
TOP=/Users/Shared/wt-climb
SUDOERS=/etc/sudoers.d/wt-climb
PREV=/var/db/wt-climb-setup.prev
SWU=/Library/Preferences/com.apple.SoftwareUpdate
CRON_DENY=/usr/lib/cron/cron.deny
AT_DENY=/usr/lib/cron/at.deny

mode=setup
case "${1:-}" in
  "") ;;
  --undo) mode=undo ;;
  --plan) mode=plan ;;
  *) echo "usage: sudo bash $0 [--undo] | bash $0 --plan"; exit 2 ;;
esac

owner="${SUDO_USER:-}"
if [ "$mode" != plan ]; then
  [ "$(id -u)" -eq 0 ] || { echo "setup-users: run it with sudo (sudo bash $0${1:+ $1})"; exit 1; }
  [ -n "$owner" ] && [ "$owner" != root ] || { echo "setup-users: run it with sudo from the account that runs the climb (SUDO_USER is empty or root)"; exit 1; }
else
  owner="${owner:-$(id -un)}"
fi
names() { local u; for u in "${USERS[@]}"; do printf '%s ' "${u%%:*}"; done; }
runas_list() { local out="" u; for u in "${USERS[@]}"; do out="${out:+$out,}${u%%:*}"; done; printf '%s' "$out"; }
sudoers_text() {
  printf '# dev/climb/setup-users.sh: %s may run any command as the climb'"'"'s build users and as no one else, with no password\n' "$owner"
  printf '%s ALL=(%s) NOPASSWD: ALL\n' "$owner" "$(runas_list)"
}
acl() { printf '%s allow list,search,read,readattr,readextattr,readsecurity,file_inherit,directory_inherit' "$owner"; }

plan_setup() {
  cat <<PLAN
setup-users will, as root, for the owner $owner:
  1. create the group $GROUP (gid $GID) unless it exists with that gid
  2. create the users $(names)(uids ${USERS[*]##*:} in that order), each: shell /usr/bin/false, password '*', hidden,
     primary group $GROUP, home $TOP/u/<user>; refuse if a uid or a name is taken by another account
  3. make $TOP ($owner, 755), $TOP/in ($owner, 711), $TOP/bin ($owner, 755), $TOP/locks ($owner, 700, its files
     600), $TOP/u (root, 755), and each home
     ($TOP/u/<user>, the user's, 700, ACL: $(acl))
  4. write $SUDOERS (root, 440) after \`visudo -cf\` passes:
       $(sudoers_text | tail -1)
  5. add each user to $CRON_DENY and $AT_DENY
  6. record AutomaticallyInstallMacOSUpdates (now: $(defaults read "$SWU" AutomaticallyInstallMacOSUpdates 2>/dev/null || echo unset)) in $PREV and set it false
PLAN
}
plan_undo() {
  cat <<PLAN
setup-users --undo will, as root:
  1. kill every process of $(names)
  2. remove $SUDOERS
  3. remove those users' lines from $CRON_DENY and $AT_DENY
  4. delete the users and the group $GROUP
  5. remove $TOP (the homes, the runs' files, the pinned claude)
  6. restore AutomaticallyInstallMacOSUpdates from $PREV ($(cat "$PREV" 2>/dev/null || echo "no record: left as it is")) and remove $PREV
PLAN
}

if [ "$mode" = plan ]; then plan_setup; echo; plan_undo; exit 0; fi
if [ "$mode" = setup ]; then plan_setup; else plan_undo; fi
printf 'Proceed? [y/N] '; read -r ans
[ "$ans" = y ] || [ "$ans" = Y ] || { echo "setup-users: nothing done"; exit 1; }

say() { echo "setup-users: $*"; }
uid_of() { dscl . -read "/Users/$1" UniqueID 2>/dev/null | awk '{print $2}' || true; }   # no such user: dscl exits 56; the answer is the empty string
name_of_uid() { dscl . -list /Users UniqueID | awk -v u="$1" '$2 == u { print $1 }'; }
name_of_gid() { dscl . -list /Groups PrimaryGroupID | awk -v g="$1" '$2 == g { print $1 }'; }

deny_add() {   # $1 file, $2 user: a line of its own, once
  [ -f "$1" ] || { : > "$1"; chmod 644 "$1"; }
  [ ! -s "$1" ] || [ "$(tail -c 1 "$1" | od -An -c | tr -d ' ')" = '\n' ] || printf '\n' >> "$1"   # never joined to a last line
  grep -qxF "$2" "$1" || { printf '%s\n' "$2" >> "$1"; say "$2 added to $1"; }
}
deny_remove() {
  [ -f "$1" ] || return 0
  if grep -qxF "$2" "$1"; then
    grep -vxF "$2" "$1" > "$1.wt-climb.tmp" || true
    cat "$1.wt-climb.tmp" > "$1"; rm -f "$1.wt-climb.tmp"; say "$2 removed from $1"
  fi
}

if [ "$mode" = setup ]; then
  # refuse before any change: every name and number ours or free, the parent no link
  g=$(name_of_gid "$GID"); [ -z "$g" ] || [ "$g" = "$GROUP" ] || { say "gid $GID belongs to $g; refused, nothing changed"; exit 1; }
  for ent in "${USERS[@]}"; do
    u=${ent%%:*}; id=${ent##*:}
    other=$(name_of_uid "$id"); [ -z "$other" ] || [ "$other" = "$u" ] || { say "uid $id belongs to $other; refused, nothing changed"; exit 1; }
    have=$(uid_of "$u"); [ -z "$have" ] || [ "$have" = "$id" ] || { say "$u exists with uid $have, not $id; refused, nothing changed"; exit 1; }
  done
  if [ -e "$TOP" ] || [ -L "$TOP" ]; then
    [ ! -L "$TOP" ] && [ -d "$TOP" ] || { say "$TOP is not a directory of its own (a link or a file); refused, nothing changed"; exit 1; }
    o=$(stat -f %Su "$TOP"); [ "$o" = "$owner" ] || [ "$o" = root ] || { say "$TOP is owned by $o; refused, nothing changed"; exit 1; }
  fi
  grep -Eq '^[#@]includedir /(private/)?etc/sudoers.d' /etc/sudoers || { say "/etc/sudoers includes no /etc/sudoers.d; refused, nothing changed"; exit 1; }

  # 1. the group
  if [ "$(name_of_gid "$GID")" = "$GROUP" ]; then say "group $GROUP exists (gid $GID)"
  else
    dscl . -create "/Groups/$GROUP"; dscl . -create "/Groups/$GROUP" PrimaryGroupID "$GID"
    dscl . -create "/Groups/$GROUP" RealName "WasmTarget climb build users"; dscl . -create "/Groups/$GROUP" Password '*'
    say "group $GROUP created (gid $GID)"
  fi
  # 2 and 3. the directories and the users
  install -d -o "$owner" -g staff -m 755 "$TOP"; install -d -o "$owner" -g staff -m 711 "$TOP/in"
  install -d -o "$owner" -g staff -m 755 "$TOP/bin"; install -d -o root -g wheel -m 755 "$TOP/u"
  # every lock on a global resource (door.lock_fd): the owner's alone, so no build user can open one to flock it
  install -d -o "$owner" -g staff -m 700 "$TOP/locks"; chmod 600 "$TOP/locks"/* "$TOP/locks"/.[!.]* 2>/dev/null || true
  for ent in "${USERS[@]}"; do
    u=${ent%%:*}; id=${ent##*:}; home="$TOP/u/$u"
    if [ "$(uid_of "$u")" = "$id" ]; then say "user $u exists (uid $id)"
    else
      dscl . -create "/Users/$u"
      dscl . -create "/Users/$u" UniqueID "$id"; dscl . -create "/Users/$u" PrimaryGroupID "$GID"
      dscl . -create "/Users/$u" UserShell /usr/bin/false; dscl . -create "/Users/$u" NFSHomeDirectory "$home"
      dscl . -create "/Users/$u" RealName "WasmTarget climb $u"; dscl . -create "/Users/$u" Password '*'
      dscl . -create "/Users/$u" IsHidden 1
      say "user $u created (uid $id)"
    fi
    dscl . -read "/Groups/$GROUP" GroupMembership 2>/dev/null | tr ' ' '\n' | grep -qxF "$u" ||
      dscl . -append "/Groups/$GROUP" GroupMembership "$u"
    [ ! -L "$home" ] || rm -f "$home"
    install -d -o "$u" -g "$GROUP" -m 700 "$home"
    chmod -N "$home"; chmod +a "$(acl)" "$home"
  done
  # 4. sudoers, checked before it is installed
  tmp=$(mktemp /etc/sudoers.d/.wt-climb.XXXXXX)
  sudoers_text > "$tmp"; chown root:wheel "$tmp"; chmod 440 "$tmp"
  if ! visudo -cf "$tmp" >/dev/null; then rm -f "$tmp"; say "the sudoers drop-in does not pass visudo -cf; not installed"; exit 1; fi
  mv -f "$tmp" "$SUDOERS"; visudo -c >/dev/null || { rm -f "$SUDOERS"; say "sudoers as a whole fails visudo -c with the drop-in; removed"; exit 1; }
  say "$SUDOERS installed"
  # 5. no cron or at job
  for ent in "${USERS[@]}"; do deny_add "$CRON_DENY" "${ent%%:*}"; deny_add "$AT_DENY" "${ent%%:*}"; done
  # 6. no automatic macOS install while the climb runs
  if [ ! -f "$PREV" ]; then
    defaults read "$SWU" AutomaticallyInstallMacOSUpdates > "$PREV" 2>/dev/null || echo unset > "$PREV"
    chmod 644 "$PREV"
  fi
  defaults write "$SWU" AutomaticallyInstallMacOSUpdates -bool false
  say "AutomaticallyInstallMacOSUpdates false (before: $(cat "$PREV"))"
  # the result, read back
  for ent in "${USERS[@]}"; do
    u=${ent%%:*}
    printf 'setup-users: %s uid %s shell %s home %s\n' "$u" "$(uid_of "$u")" "$(dscl . -read "/Users/$u" UserShell | awk '{print $2}')" "$(stat -f '%Su %Lp' "$TOP/u/$u")"
  done
  say "done. Tell the lead; it runs \`python3 dev/climb/climb.py door-probe\`."
  exit 0
fi

# --undo
for ent in "${USERS[@]}"; do
  u=${ent%%:*}
  if [ -n "$(uid_of "$u")" ]; then pkill -KILL -U "$u" 2>/dev/null || true; fi
done
rm -f "$SUDOERS" && say "$SUDOERS removed"
for ent in "${USERS[@]}"; do deny_remove "$CRON_DENY" "${ent%%:*}"; deny_remove "$AT_DENY" "${ent%%:*}"; done
for ent in "${USERS[@]}"; do
  u=${ent%%:*}
  if [ -n "$(uid_of "$u")" ]; then dscl . -delete "/Users/$u" && say "user $u deleted"; fi
done
if [ "$(name_of_gid "$GID")" = "$GROUP" ]; then dscl . -delete "/Groups/$GROUP" && say "group $GROUP deleted"; fi
if [ -d "$TOP" ] && [ ! -L "$TOP" ]; then rm -rf "$TOP" && say "$TOP removed"; fi
if [ -f "$PREV" ]; then
  case "$(cat "$PREV")" in
    1) defaults write "$SWU" AutomaticallyInstallMacOSUpdates -bool true ;;
    0) defaults write "$SWU" AutomaticallyInstallMacOSUpdates -bool false ;;
    unset) defaults delete "$SWU" AutomaticallyInstallMacOSUpdates 2>/dev/null || true ;;
    *) say "$PREV holds $(head -c 40 "$PREV"), no value this script writes; AutomaticallyInstallMacOSUpdates left as it is" ;;
  esac
  rm -f "$PREV"; say "AutomaticallyInstallMacOSUpdates restored"
fi
say "undone"
