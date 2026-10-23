#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh — scenario tests for the community-script rollback path
# =============================================================================
# Runs pve-update.sh --apply against one fake CT. pct, zfs, pvesm, curl and
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
  mkdir -p "$S/fs" "$S/logs"
  printf 'cron.service\nprofilarr.service\n' > "$S/fs/enabled"
  : > "$S/fs/broken"
  cp "$S/fs/enabled" "$S/running"
  : > "$S/snapshots"; : > "$S/calls.log"
  echo ok > "$S/cs_mode"
  printf 'PVE_UPDATE_NTFY=https://ntfy.example/homelab-updates\nPVE_UPDATE_NTFY_TOKEN=tk_secret123\n' > "$S/config"
}

# Run the script. Output in $S/out, exit code in $RC.
run() {
  env -i HOME=/root PATH="$FAKES:/usr/bin:/bin" FAKE_STATE="$S" FAKE_CT="$CT" \
    PVE_UPDATE_CONFIG="$S/config" PVE_UPDATE_LOG_DIR="$S/logs" \
    bash "$SCRIPT" --apply -y --no-update-check "$CT" </dev/null > "$S/out" 2>&1
  RC=$?
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
run
check "exit 0"                      equals "$RC" 0
check "snapshot was taken"          has "$S/calls.log" "^zfs snapshot VM-Pool/subvol-$CT-disk-0@pve-update-"
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

# --- 6. Low-disk skip: not a failure, no rollback, P3 ------------------------
begin "low-disk skip: no rollback, snapshot removed, P3 push"
echo lowdisk > "$S/cs_mode"
run
check "exit 0"                      equals "$RC" 0
check "no rollback"                 hasnt "$S/calls.log" "^zfs rollback"
check "snapshot removed"            empty "$S/snapshots"
check "push is P3"                  has "$S/curl.args" "^Priority: 3$"
check "push names the skip"         has "$S/curl.body" "low disk space"
end

# --- 7. Config is parsed, never executed -------------------------------------
begin "config file values are read as data, not run"
printf 'PVE_UPDATE_NTFY=$(touch %s/pwned)\nPVE_UPDATE_NTFY_TOKEN="tk_quoted"\n' "$S" > "$S/config"
echo fail > "$S/cs_mode"
run
check "command substitution not run" missing "$S/pwned"
check "quotes stripped from token"  has "$S/curl.stdin" "Bearer tk_quoted\"$"
end

echo ""
echo "passed: $PASS  failed: $FAIL"
for n in "${FAILED_NAMES[@]}"; do echo "  ✘ $n"; done
[[ $FAIL -eq 0 ]]
