#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh — scenario tests for the apply step and its rollback path
# =============================================================================
# Runs pve-update.sh --apply against one fake CT (and, in some scenarios, a
# second idle one). pct, zfs, pvesm, curl and
# journalctl are test doubles (tests/fakes/), and PATH holds only those plus
# /usr/bin:/bin, so the real pct/zfs/pvesm in /usr/sbin can't be reached and
# apt-get/systemctl/qm are tripwires. Nothing on the host or in any real CT is
# touched. Needs root (the script checks EUID) and bash 4+, so run it on the
# PVE host or any Linux box:  sudo bash tests/run-tests.sh
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../pve-update.sh"
FAKES="$HERE/fakes"
CT=9104
PASS=0 FAIL=0
FAILED_NAMES=()

# A fresh fake CT. Profilarr and cron run; the community script is for
# profilarr; the rootfs is a ZFS subvol unless the scenario says otherwise.
setup() {
  S=$(mktemp -d)
  echo running > "$S/status"
  echo "VM-Pool:subvol-$CT-disk-0" > "$S/rootfs"
  echo "/VM-Pool/subvol-$CT-disk-0" > "$S/pvesm_path"
  echo "/VM-Pool/subvol-$CT-disk-0" > "$S/zfs_path"
  echo "VM-Pool/subvol-$CT-disk-0" > "$S/zfs_ds"
  mkdir -p "$S/fs" "$S/logs" "$S/hooks"
  printf 'cron.service\nprofilarr.service\n' > "$S/fs/enabled"
  : > "$S/fs/broken"
  cp "$S/fs/enabled" "$S/running"
  : > "$S/snapshots"; : > "$S/calls.log"
  echo ok > "$S/cs_mode"
  printf 'PVE_UPDATE_NTFY=https://ntfy.example/homelab-updates\nPVE_UPDATE_NTFY_TOKEN=tk_secret123\n' > "$S/config"
}

# Run the script, by default '--apply -y --no-update-check <CT>' (stdin is
# never a terminal here, so --apply needs -y). Other arguments replace those.
# Output in $S/out, exit code in $RC. FAKE_CT2 (if set) adds the idle CT.
run() {
  local args=("$@")
  [[ ${#args[@]} -gt 0 ]] || args=(--apply -y --no-update-check "$CT")
  env -i HOME=/root PATH="$FAKES:/usr/bin:/bin" FAKE_STATE="$S" FAKE_CT="$CT" \
    FAKE_CT2="${FAKE_CT2:-}" PVE_UPDATE_CONFIG="$S/config" PVE_UPDATE_LOG_DIR="$S/logs" \
    PVE_UPDATE_HOOK_DIR="$S/hooks" \
    bash "$SCRIPT" "${args[@]}" </dev/null > "$S/out" 2>&1
  RC=$?
}

# Run the default apply in the background, wait until the fake community
# script is running (cs_wait), send signal $1 to the script, then let the
# community script finish. Output in $S/out, exit code in $RC. A script's
# background jobs start with SIGINT ignored, and an ignored signal can't be
# trapped, so perl puts the default back before it runs pve-update.sh.
run_signal() {
  local pid i
  touch "$S/cs_wait"
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
    env -i HOME=/root PATH="$FAKES:/usr/bin:/bin" FAKE_STATE="$S" FAKE_CT="$CT" \
    PVE_UPDATE_CONFIG="$S/config" PVE_UPDATE_LOG_DIR="$S/logs" PVE_UPDATE_HOOK_DIR="$S/hooks" \
    bash "$SCRIPT" --apply -y --no-update-check "$CT" </dev/null > "$S/out" 2>&1 &
  pid=$!
  i=0
  while [[ ! -e "$S/cs_started" ]] && (( i++ < 300 )); do /usr/bin/sleep 0.1; done
  kill -s "$1" "$pid"
  /usr/bin/sleep 0.5      # the script is now waiting on its job
  touch "$S/cs_go"
  wait "$pid"; RC=$?
}

# A busy hook for CT $1 that records its call and exits $2.
hook() {
  # shellcheck disable=SC2016  # $1 is the hook's own argument
  printf '#!/bin/sh\necho "hook $1" >> "%s/calls.log"\nexit %s\n' "$S" "$2" > "$S/hooks/$1"
  chmod +x "$S/hooks/$1"
}

_t=""
check() {  # check "<what>" <command...>
  local what="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$_t: $what")
    echo "    ✘ $what"
  fi
}
has()     { grep -qE -- "$2" "$1" 2>/dev/null; }
hasnt()   { ! grep -qE -- "$2" "$1" 2>/dev/null; }
exists()  { [[ -e "$1" ]]; }
missing() { [[ ! -e "$1" ]]; }
equals()  { [[ "$1" == "$2" ]]; }
empty()   { [[ ! -s "$1" ]]; }
logdir()  { ls -d "$S"/logs/*-ct$CT-profilarr 2>/dev/null | head -n1; }

begin() { _t="$1"; echo "• $1"; setup; }
end() {
  check "no unmodelled calls" missing "$S/unhandled"
  [[ -f "$S/unhandled" ]] && sed 's/^/      /' "$S/unhandled"
  if [[ $FAIL -gt 0 && -n "${KEEP:-}" ]]; then echo "    state kept in $S"; else rm -rf "$S"; fi
}

# --- 1. Success: snapshot taken, then removed; nothing pushed ----------------
begin "success removes the pre-update snapshot and stays quiet"
hook "$CT" 0
run
check "exit 0"                      equals "$RC" 0
check "snapshot was taken"          has "$S/calls.log" "^zfs snapshot VM-Pool/subvol-$CT-disk-0@pve-update-"
check "hook, then snapshot, then script" equals \
  "$(awk -v ct="$CT" '$0 == "hook " ct {print "hook"} /^zfs snapshot / {print "snapshot"} /bash \/tmp\/\.pve_update_/ {print "script"}' "$S/calls.log" | paste -sd'|' -)" \
  "hook|snapshot|script"
check "snapshot is gone"            empty "$S/snapshots"
check "no rollback"                 hasnt "$S/calls.log" "^zfs rollback"
check "no push"                     missing "$S/curl.args"
check "no failure log"              equals "$(logdir)" ""
end

# --- 2. Failure: evidence saved, rolled back, app live, P4 push --------------
begin "failure rolls back to a live state, logs it and pushes P4"
echo fail > "$S/cs_mode"; touch "$S/oom"
run
L=$(logdir)
check "exit 1"                      equals "$RC" 1
check "rolled back"                 has "$S/calls.log" "^zfs rollback VM-Pool/subvol-$CT-disk-0@pve-update-"
check "CT running again"            equals "$(cat "$S/status")" running
check "profilarr running again"     has "$S/running" "^profilarr\.service$"
check "snapshot removed after rollback" empty "$S/snapshots"
check "log dir created"             exists "$L"
check "script output kept in full"  has "$L/community-script.log" "exit code 137"
check "CT error files kept"         has "$L/ct-tmp-logs.txt" "EXIT_CODE=137"
check "CT journal kept"             has "$L/ct-journal.txt" "Stopped profilarr.service"
check "kernel OOM kept"             has "$L/kernel.txt" "oom_memcg=/lxc/$CT"
check "services down listed"        has "$L/services.txt" "profilarr\.service"
check "summary written"             has "$L/summary.txt" "rolled back"
check "summary lists the failure"   has "$S/out" "$CT \(profilarr\): community script failed \(exit 137"
check "summary names the log dir"   has "$S/out" "$L"
check "push sent"                   exists "$S/curl.args"
check "push is P4"                  has "$S/curl.args" "^Priority: 4$"
check "push to the configured URL"  has "$S/curl.args" "^https://ntfy\.example/homelab-updates$"
check "push names CT and outcome"   has "$S/curl.body" "$CT \(profilarr\).*rolled back"
check "push mentions the OOM"       has "$S/curl.body" "out of memory"
check "push names the log dir"      has "$S/curl.body" "$L"
check "token sent on stdin"         has "$S/curl.stdin" "Authorization: Bearer tk_secret123"
check "token not in argv"           hasnt "$S/curl.args" "tk_secret123"
end

# --- 3. Rollback itself fails: CT started anyway, snapshot kept, P5 ----------
begin "failed rollback keeps the snapshot, starts the CT and pushes P5"
echo fail > "$S/cs_mode"; touch "$S/fail_rollback"
run
check "exit 1"                      equals "$RC" 1
check "CT started anyway"           equals "$(cat "$S/status")" running
check "snapshot kept"               has "$S/snapshots" "@pve-update-"
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says rollback failed"   has "$S/curl.body" "rollback failed"
check "push names the snapshot"     has "$S/curl.body" "VM-Pool/subvol-$CT-disk-0@pve-update-"
end

# --- 4. Rootfs not on ZFS: no snapshot possible, logged, P5 ------------------
begin "non-ZFS rootfs: no snapshot, failure logged, P5"
rm -f "$S/zfs_ds"; echo "local-lvm:vm-$CT-disk-0" > "$S/rootfs"; echo "/dev/pve/vm-$CT-disk-0" > "$S/pvesm_path"
echo fail > "$S/cs_mode"
run
check "exit 1"                      equals "$RC" 1
check "no snapshot attempted"       hasnt "$S/calls.log" "^zfs snapshot"
check "says it can't roll back"     has "$S/out" "not on ZFS"
check "log dir created"             exists "$(logdir)"
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says app still down"    has "$S/curl.body" "profilarr\.service"
end

# --- 5. No ntfy config: same recovery, no push -------------------------------
begin "without ntfy config: still rolls back, sends nothing"
rm -f "$S/config"; echo fail > "$S/cs_mode"
run
check "exit 1"                      equals "$RC" 1
check "rolled back"                 has "$S/calls.log" "^zfs rollback"
check "no push"                     missing "$S/curl.args"
end

# --- 6. Low-disk skip: not a failure, no rollback, no push ------------------
begin "low-disk skip: no rollback, snapshot removed, no push"
echo lowdisk > "$S/cs_mode"
run
check "exit 0"                      equals "$RC" 0
check "snapshot was taken"          has "$S/calls.log" "^zfs snapshot "
check "no rollback"                 hasnt "$S/calls.log" "^zfs rollback"
check "snapshot removed"            empty "$S/snapshots"
check "skips don't push"            missing "$S/curl.args"
check "board lists the skip"        has "$S/out" "$CT \(profilarr\): low disk space"
end

# --- 7. Config is parsed, never executed -------------------------------------
begin "config file values are read as data, not run"
printf 'PVE_UPDATE_NTFY=$(touch %s/pwned)\nPVE_UPDATE_NTFY_TOKEN="tk_quoted"\n' "$S" > "$S/config"
echo fail > "$S/cs_mode"
run
check "command substitution not run" missing "$S/pwned"
check "quotes stripped from token"  has "$S/curl.stdin" "Bearer tk_quoted\"$"
end

# --- 8. No terminal and no -y: refused before anything runs -----------------
begin "--apply without a terminal or -y refuses before touching anything"
run --apply --no-update-check "$CT"
check "exit 1"                      equals "$RC" 1
check "says why"                    has "$S/out" "no terminal to confirm on"
check "no pct call at all"          hasnt "$S/calls.log" "^pct "
check "no zfs call"                 hasnt "$S/calls.log" "^zfs "
end

# --- 9. Nothing to apply: the check runs, the apply step never does ----------
begin "nothing to apply: exits after the check without acting"
touch "$S/no_cs"; hook "$CT" 0
run
check "exit 0"                      equals "$RC" 0
check "says so"                     has "$S/out" "NOTHING TO APPLY"
check "the CT was checked"          has "$S/calls.log" "^pct exec $CT -- cat /usr/bin/update"
check "hook not called"             hasnt "$S/calls.log" "^hook "
check "no snapshot"                 hasnt "$S/calls.log" "^zfs snapshot"
check "no apply step"               hasnt "$S/out" "EXECUTING UPDATE SEQUENCE"
end

# --- 10. A CT the check found nothing in is left alone by the apply ----------
begin "an idle CT is checked but never touched by the apply step"
FAKE_CT2=9105; hook "$CT" 0; hook 9105 0
run --apply -y --no-update-check "$CT" 9105
check "exit 0"                      equals "$RC" 0
check "idle CT was checked"         has "$S/calls.log" "^pct exec 9105 -- cat /usr/bin/update"
check "busy CT was updated"         has "$S/calls.log" "bash /tmp/\.pve_update_"
check "busy CT's hook ran"          has "$S/calls.log" "^hook $CT$"
check "idle CT's hook never ran"    hasnt "$S/calls.log" "^hook 9105$"
check "idle CT never snapshotted"   hasnt "$S/calls.log" "^zfs snapshot .*9105"
check "no apply card for it"        hasnt "$S/out" "DECK 9105\]─\[IDLE\]─\[EXECUTE"
FAKE_CT2=""
end

# --- 11. Hook defers the CT after the check ----------------------------------
begin "hook deferral: checked first, then deferred untouched, no push"
hook "$CT" 1
run
check "exit 0"                      equals "$RC" 0
check "checked before the hook"     equals "$(grep -nE '^(pct exec '"$CT"' -- cat /usr/bin/update|hook '"$CT"')$' "$S/calls.log" | cut -d: -f2- | paste -sd'|' -)" "pct exec $CT -- cat /usr/bin/update|hook $CT"
check "shows DEFERRED"              has "$S/out" "DEFERRED"
check "no snapshot"                 hasnt "$S/calls.log" "^zfs snapshot"
check "community script not run"    hasnt "$S/calls.log" "bash /tmp/\.pve_update_"
check "listed as a skip"            has "$S/out" "deferred by hook \(exit 1\)"
check "no push"                     missing "$S/curl.args"
end

# --- 12. apt upgrade fails: FAULT with apt's exit code, exit 1, P4 push ------
begin "failed apt upgrade: FAULT with its exit code, exit 1, P4 push"
touch "$S/apt_pending" "$S/apt_fail"
run
check "exit 1"                      equals "$RC" 1
check "FAULT with apt's exit code"  has "$S/out" "FAULT — apt upgrade failed \(exit 3\)"
check "board says what failed"     has "$S/out" "✖ $CT \(profilarr\): apt upgrade failed \(exit 3\)$"
check "push is P4"                  has "$S/curl.args" "^Priority: 4$"
check "push says what failed"      has "$S/curl.body" "^FAILED $CT \(profilarr\): apt upgrade failed \(exit 3\)$"
check "never a bare FAILED line"    hasnt "$S/curl.body" "^FAILED $CT \(profilarr\)$"
end

# --- 13. CT stopped while the prompt waited: left alone, a skip -------------
begin "CT stopped between the check and the apply is left alone"
# The hook stands in for whoever stops it: it runs after the check, right
# before the apply step looks at the CT.
# shellcheck disable=SC2016  # $1 is the hook's own argument
printf '#!/bin/sh\necho "hook $1" >> "%s/calls.log"\necho stopped > "%s/status"\n' "$S" "$S" > "$S/hooks/$CT"
chmod +x "$S/hooks/$CT"; touch "$S/apt_pending"
run
check "exit 0"                      equals "$RC" 0
check "says so"                     has "$S/out" "STOPPED SINCE SCAN"
check "no snapshot"                 hasnt "$S/calls.log" "^zfs snapshot"
check "no rollback"                 hasnt "$S/calls.log" "^zfs rollback"
check "not started"                 hasnt "$S/calls.log" "^pct start"
check "no apt upgrade"              hasnt "$S/calls.log" "apt-get upgrade -y"
check "script not run"              hasnt "$S/calls.log" "bash /tmp/\.pve_update_"
check "still stopped"               equals "$(cat "$S/status")" stopped
check "listed as a skip"            has "$S/out" "$CT \(profilarr\): stopped since the check"
check "no push"                     missing "$S/curl.args"
end

# --- 14. CT stopped while its script ran: rolled back, not started ----------
begin "CT stopped during a failing script is rolled back but left stopped"
echo failstop > "$S/cs_mode"
run
check "exit 1"                      equals "$RC" 1
check "rolled back"                 has "$S/calls.log" "^zfs rollback"
check "not started"                 hasnt "$S/calls.log" "^pct start"
check "still stopped"               equals "$(cat "$S/status")" stopped
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says it was left stopped" has "$S/curl.body" "left stopped"
end

# --- 15. Guard-held script: apt still applies, nothing else ------------------
begin "guard-held community script: apt applies, no snapshot, no script, no push"
echo sonarr > "$S/cs_slug"; touch "$S/apt_pending"
echo "sonarr|5.0.1.100|develop|builtin|True|4.0.15.2941|5.0.1.100||" > "$S/arr"
run
check "exit 0"                      equals "$RC" 0
check "held in the check"           has "$S/out" "WITHHELD"
check "apt applied"                 has "$S/calls.log" "apt-get upgrade -y"
check "no zfs call at all"          hasnt "$S/calls.log" "^zfs "
check "script not run"              hasnt "$S/calls.log" "bash /tmp/\.pve_update_"
check "listed as a skip"            has "$S/out" "sonarr has run 5\.0\.1\.100, a newer major"
check "no push"                     missing "$S/curl.args"
end

# --- 16. --apt-only --apply: packages only ----------------------------------
begin "--apt-only --apply upgrades packages and nothing else"
touch "$S/apt_pending"
run --apply -y --apt-only --no-update-check "$CT"
check "exit 0"                      equals "$RC" 0
check "apt applied"                 has "$S/calls.log" "apt-get upgrade -y"
check "no zfs call at all"          hasnt "$S/calls.log" "^zfs "
check "script not run"              hasnt "$S/calls.log" "bash /tmp/\.pve_update_"
end

# --- 17. The CT won't stop: no rollback, no start, snapshot kept, P5 ---------
begin "CT that won't stop: no rollback, snapshot kept, P5"
echo fail > "$S/cs_mode"; touch "$S/fail_stop"
run
check "exit 1"                      equals "$RC" 1
check "no rollback"                 hasnt "$S/calls.log" "^zfs rollback"
check "not started"                 hasnt "$S/calls.log" "^pct start"
check "snapshot kept"               has "$S/snapshots" "@pve-update-"
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says snapshot kept"     has "$S/curl.body" "snapshot kept"
end

# --- 18. Rolled back, but the CT won't start: P5, snapshot gone -------------
begin "rolled back but the CT stays down: P5, snapshot destroyed"
echo fail > "$S/cs_mode"; touch "$S/fail_start"
run
check "exit 1"                      equals "$RC" 1
check "rolled back"                 has "$S/calls.log" "^zfs rollback"
check "snapshot destroyed"          empty "$S/snapshots"
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says it didn't start"   has "$S/curl.body" "didn't start"
end

# --- 19. Ctrl-C while a script fails and can't roll back --------------------
begin "Ctrl-C mid-apply: waits for the job, reports INTERRUPTED, pushes P5, exits 130"
echo fail > "$S/cs_mode"; touch "$S/fail_rollback"
run_signal INT
check "exit 130"                    equals "$RC" 130
check "said it was waiting"         has "$S/out" "HOLDING — WAITING FOR 1 CT"
check "the job finished"            has "$S/out" "ROLLBACK FAILED"
check "board marked interrupted"    has "$S/out" "STATUS BOARD // AFTER ACTION — INTERRUPTED"
check "failure on the board"        has "$S/out" "✖ $CT \(profilarr\): community script failed"
check "push is P5"                  has "$S/curl.args" "^Priority: 5$"
check "push says snapshot kept"     has "$S/curl.body" "snapshot kept"
end

# --- 20. kill while a script succeeds: report, no push ------------------------
begin "kill mid-apply on a good update: reports INTERRUPTED, no push, exits 143"
run_signal TERM
check "exit 143"                    equals "$RC" 143
check "the job finished"            has "$S/out" "COMPLETE — community script update"
check "snapshot removed"            empty "$S/snapshots"
check "board marked interrupted"    has "$S/out" "STATUS BOARD // AFTER ACTION — INTERRUPTED"
check "no push"                     missing "$S/curl.args"
end

echo ""
echo "passed: $PASS  failed: $FAIL"
for n in "${FAILED_NAMES[@]}"; do echo "  ✘ $n"; done
[[ $FAIL -eq 0 ]]
