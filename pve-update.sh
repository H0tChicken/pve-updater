#!/usr/bin/env bash
# =============================================================================
# pve-update.sh — Proxmox Host + LXC Update Checker & Applier
# =============================================================================
# Usage:
#   ./pve-update.sh                     # Check the PVE host + all running CTs
#   ./pve-update.sh --apply             # Apply updates to the host + all CTs
#   ./pve-update.sh --apply 100 112     # Apply to specific CTs only (host skipped)
#   ./pve-update.sh --apply host 100    # Apply to the host + CT 100
#   ./pve-update.sh --check 112 113     # Check specific CTs only (host skipped)
#   ./pve-update.sh --apt-only          # Check OS-level apt/apk upgrades only
#   ./pve-update.sh --apt-only --apply  # Apply OS-level apt/apk upgrades only
#   ./pve-update.sh --apt-only 107      # Check apt/apk for specific CTs
#   ./pve-update.sh --host-only         # Only update the Proxmox host
#   ./pve-update.sh --apply --no-host   # Apply to all CTs but skip the host
#   ./pve-update.sh --apply -y          # Apply without the confirm prompt
#   ./pve-update.sh --install-timer          # Install weekly systemd timer (apply mode)
#   ./pve-update.sh --install-timer daily    # Install daily systemd timer
#   ./pve-update.sh --self-update            # Pull + GPG-verify the latest script
#   ./pve-update.sh --self-update -y         # ...and skip the diff/confirm prompt
#   ./pve-update.sh --version                # Show this script's checksum (sha256)
#   ./pve-update.sh --no-update-check        # Skip the "new version available" check
#
# On interactive runs the script checks GitHub and prints a one-line notice if a
# newer version exists — it never updates itself automatically. Run --self-update
# to pull the new version: it downloads the script + detached signature, VERIFIES
# the signature against the public key pinned in this script, shows a diff and
# asks for confirmation, then does an atomic in-place replace. Re-run as usual
# afterwards. Verification fails closed — a missing/invalid signature or missing
# pinned key aborts without touching the installed script. The systemd timer
# runs skip the update check entirely. See the README to set up signing.
#
# When you run --apply in a terminal, the script first previews what's available
# and asks for a y/N before changing anything. Pass -y to skip the prompt. The
# systemd timer has no terminal, so it applies unattended as before.
#
# What it does:
#   0. PVE host: apt update && check/apply dist-upgrade (full-upgrade)
#   1. OS-level: apt/apk update && check/apply upgrades (Debian + Alpine)
#   2. Community scripts: detect /usr/bin/update and run it (--apply)
#   3. Docker: detect running containers, pull new images, recreate (--apply)
#
# The Proxmox host is included by default. Use 'host'/'pve' as a target,
# --host-only, or --no-host to control this. The host uses dist-upgrade
# (full-upgrade) per Proxmox best practice, and a reboot hint is shown when
# a new kernel/libs require it — the script never reboots automatically.
# New LXCs are automatically discovered — no configuration needed.
# VMs (qm) are not handled by this script.
#
# For Docker containers with PINNED version tags (e.g. traefik:v3.6.17),
# the script will warn you but NOT auto-update — you must manually change
# the tag in the compose file first. It WILL auto-pull :latest or
# unpinned tags.
# =============================================================================

set -o pipefail

if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "Error: 'pct' not found — this script requires Proxmox VE." >&2
  exit 1
fi

# The interactive "confirm before apply" gate re-runs this script in check mode
# as a nested subprocess (PVE_UPDATE_NESTED=1). That child must NOT try to grab
# the lock — the parent already holds it — or it would abort as a duplicate.
if [[ "${PVE_UPDATE_NESTED:-}" != "1" ]]; then
  exec 200>/var/lock/pve-update.lock
  if ! flock -n 200; then
    echo "Error: another instance of pve-update.sh is already running." >&2
    exit 1
  fi
fi

timestamp() { date '+%H:%M:%S'; }
SCRIPT_START=$(date +%s)

# =============================================================================
# SELF-UPDATE  (pull the latest pve-update.sh from GitHub, GPG-verified)
# =============================================================================
# --self-update downloads this script + its detached signature over HTTPS and
# runs it as root. Before replacing itself it VERIFIES the download against the
# public key pinned below (PUBKEY_B64). Because the trusted key lives in the
# CURRENTLY-RUNNING script, a malicious push to the repo cannot rotate it — an
# attacker would need the private signing key, which never touches the repo.
#
# Fail-closed: if no key is pinned, gpgv/gpg is missing, the signature is
# missing, or verification fails, the update is refused and nothing is touched.
# See the README "Signing releases" section to generate a key and set PUBKEY_B64.
REPO_RAW_URL="https://raw.githubusercontent.com/H0tChicken/pve-updater/main/pve-update.sh"
REPO_SIG_URL="${REPO_RAW_URL}.sig"

# base64 of the binary GPG public keyring:  gpg --export <KEYID> | base64 | tr -d '\n'
PUBKEY_B64="mDMEalg++RYJKwYBBAHaRw8BAQdA5CZMFIgN5yuxcSbNHyaIjJgOa+uo7Nc5+jn7DZUZREG0C1BWRSBVcGRhdGVyiK8EExYKAFcWIQSj1vxQN/5b9LRo8KDMH9eyldWoQQUCalg++RsUgAAAAAAEAA5tYW51MiwyLjUrMS4xMiwwLDMCGwMFCwkIBwICIgIGFQoJCAsCBBYCAwECHgcCF4AACgkQzB/XspXVqEHFhAEAiHgTkMV2iLKcbk1c7rnORhU+hVwvbe4rImPFlnY89QgA/A+t+Y9lMwvtPsiel7++ZqKklh+W/oSFLjg5439JFYQK"

self_sha() { sha256sum "$(realpath "$0")" 2>/dev/null | awk '{print $1}'; }

# Fetch $1 -> $2 over HTTPS only (no protocol downgrade / redirect to http/file).
fetch_url() {
  local url="$1" dest="$2" maxtime="${3:-20}"
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
       --connect-timeout 4 --max-time "$maxtime" "$url" -o "$dest" 2>/dev/null
}
fetch_remote() { fetch_url "$REPO_RAW_URL" "$1" "${2:-20}"; }

# Verify file $1 against detached signature $2 using the pinned key. 0 = good.
# Returns 2 for "can't verify" (no key / no tool) so callers can fail closed.
verify_signature() {
  local file="$1" sig="$2"
  # Match the PASTE_ prefix (a glob), not the full placeholder literal: base64
  # never contains '_', so a real pinned key can never match this, and replacing
  # the full placeholder value can't accidentally disable the guard.
  if [[ -z "$PUBKEY_B64" || "$PUBKEY_B64" == PASTE_* ]]; then
    echo -e "${RED}✘  No signing key pinned (PUBKEY_B64) — refusing to self-update.${NC}" >&2
    echo -e "     See the README 'Signing releases' section." >&2
    return 2
  fi
  local keyring; keyring=$(mktemp)
  if ! printf '%s' "$PUBKEY_B64" | base64 -d > "$keyring" 2>/dev/null; then
    echo -e "${RED}✘  Pinned key is not valid base64 — refusing to self-update.${NC}" >&2
    rm -f "$keyring"; return 2
  fi
  local rc=1
  if command -v gpgv >/dev/null 2>&1; then
    gpgv --keyring "$keyring" "$sig" "$file" >/dev/null 2>&1 && rc=0
  elif command -v gpg >/dev/null 2>&1; then
    local gh; gh=$(mktemp -d)
    gpg --homedir "$gh" --batch --import "$keyring" >/dev/null 2>&1
    gpg --homedir "$gh" --batch --verify "$sig" "$file" >/dev/null 2>&1 && rc=0
    rm -rf "$gh"
  else
    echo -e "${RED}✘  Neither gpgv nor gpg is installed — cannot verify signature.${NC}" >&2
    rm -f "$keyring"; return 2
  fi
  rm -f "$keyring"
  return $rc
}

# Best-effort notice that GitHub has a different version. Never fails the run.
# This only compares checksums to decide whether to PRINT a banner; it never
# executes the download, so it needs no signature check.
check_for_update() {
  local tmp; tmp=$(mktemp) || return 0
  if fetch_remote "$tmp" 6; then
    local remote_sha local_sha
    remote_sha=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    local_sha=$(self_sha)
    if [[ -n "$remote_sha" && -n "$local_sha" && "$remote_sha" != "$local_sha" ]]; then
      echo ""
      echo -e "${YELLOW}⬆  A newer version of pve-update.sh is available on GitHub.${NC}"
      echo -e "   local ${local_sha:0:12} → remote ${remote_sha:0:12}"
      echo -e "   Update with: ${BOLD}$0 --self-update${NC}"
    fi
  fi
  rm -f "$tmp"
}

self_update() {
  local script_path; script_path=$(realpath "$0")
  if [[ ! -w "$script_path" ]]; then
    echo -e "${RED}✘  $script_path is not writable — cannot self-update.${NC}" >&2
    exit 1
  fi
  # Temp files in the SAME directory so the final replace is an atomic
  # same-filesystem rename; the running shell keeps executing the old inode.
  local dir; dir=$(dirname "$script_path")
  local tmp tmpsig
  tmp=$(mktemp "$dir/.pve-update.XXXXXX")     || { echo "mktemp failed" >&2; exit 1; }
  tmpsig=$(mktemp "$dir/.pve-update-sig.XXXXXX") || { rm -f "$tmp"; echo "mktemp failed" >&2; exit 1; }
  # Expand the paths into the trap string NOW (double quotes): the trap fires at
  # the script's final exit — after this function has returned on the success
  # path — when $tmp/$tmpsig (locals) would already be out of scope. mktemp names
  # never contain quotes, so embedding them literally is safe.
  trap "rm -f -- '$tmp' '$tmpsig' 2>/dev/null" EXIT

  echo -e "  ${CYAN}[self-update]${NC} Downloading latest from GitHub..."
  if ! fetch_remote "$tmp"; then
    echo -e "${RED}✘  Download failed (network down or curl missing).${NC}" >&2
    exit 1
  fi

  # Already current? Nothing to verify or replace.
  local old_sha new_sha
  old_sha=$(self_sha)
  new_sha=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
  if [[ "$old_sha" == "$new_sha" ]]; then
    echo -e "  ${GREEN}✔  Already up to date (${old_sha:0:12}).${NC}"
    exit 0
  fi

  # --- SECURITY GATE: verify the signature before trusting the download ---
  echo -e "  ${CYAN}[self-update]${NC} Downloading signature..."
  if ! fetch_url "$REPO_SIG_URL" "$tmpsig"; then
    echo -e "${RED}✘  Could not download signature (${REPO_SIG_URL##*/}) — refusing.${NC}" >&2
    exit 1
  fi
  echo -e "  ${CYAN}[self-update]${NC} Verifying signature..."
  if ! verify_signature "$tmp" "$tmpsig"; then
    echo -e "${RED}✘  Signature verification FAILED — not replacing.${NC}" >&2
    exit 1
  fi
  echo -e "  ${GREEN}✔  Signature verified${NC}"

  # Integrity checks: valid bash + looks like this script.
  if ! bash -n "$tmp" 2>/dev/null; then
    echo -e "${RED}✘  Downloaded file failed syntax check — not replacing.${NC}" >&2
    exit 1
  fi
  if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! grep -q 'pve-update.sh' "$tmp"; then
    echo -e "${RED}✘  Downloaded file doesn't look like pve-update.sh — not replacing.${NC}" >&2
    exit 1
  fi

  # Show what's changing and get consent (interactive only).
  if [[ -t 0 && -t 1 && "$ASSUME_YES" != true ]]; then
    echo ""
    echo -e "  ${BOLD}Changes to be applied:${NC}"
    diff -u "$script_path" "$tmp" | sed 's/^/    /' || true
    echo ""
    local reply
    read -r -p "  Apply this signed update? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo -e "  ${YELLOW}Aborted — no changes made.${NC}"
      exit 0
    fi
  fi

  chmod --reference="$script_path" "$tmp" 2>/dev/null || chmod 0755 "$tmp"
  if ! mv "$tmp" "$script_path"; then
    echo -e "${RED}✘  Failed to replace $script_path.${NC}" >&2
    exit 1
  fi
  echo -e "  ${GREEN}✔  Updated ${old_sha:0:12} → ${new_sha:0:12}${NC}"
  echo -e "  ${BOLD}Now re-run:${NC} $0 --apply    ${CYAN}(or your usual flags)${NC}"
}

MODE="check"
APT_ONLY=false
INCLUDE_HOST=true      # update the Proxmox host by default
HOST_ONLY=false        # --host-only: update only the host
NO_HOST=false          # --no-host: skip the host
TARGET_HOST=false      # set when 'host'/'pve' is passed as a target
TARGET_CTS=()
INSTALL_TIMER=false
TIMER_SCHEDULE="weekly"
SELF_UPDATE=false
NO_UPDATE_CHECK=false
ASSUME_YES=false

# Capture the original invocation so the confirm gate can replay it in check mode.
ORIG_ARGS=("$@")

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)  MODE="apply"; shift ;;
    --check)  MODE="check"; shift ;;
    --apt-only) APT_ONLY=true; shift ;;
    --host-only) HOST_ONLY=true; shift ;;
    --no-host)   NO_HOST=true; shift ;;
    --self-update) SELF_UPDATE=true; shift ;;
    --no-update-check) NO_UPDATE_CHECK=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --version)
      echo "pve-update.sh  (sha256 $(self_sha | cut -c1-12))"
      exit 0 ;;
    --install-timer)
      INSTALL_TIMER=true
      shift
      if [[ "${1:-}" == "daily" || "${1:-}" == "weekly" ]]; then
        TIMER_SCHEDULE="$1"; shift
      fi
      ;;
    -h|--help)
      sed -n '5,/^# =====/{ /^# =====/d; s/^# \?//p }' "$0"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        TARGET_CTS+=("$1")
      elif [[ "${1,,}" == "host" || "${1,,}" == "pve" ]]; then
        TARGET_HOST=true
      else
        echo "Unknown option: $1 (use -h for help)"; exit 1
      fi
      shift
      ;;
  esac
done

# =============================================================================
# SYSTEMD TIMER INSTALLER
# =============================================================================
install_timer() {
  local schedule="$1"
  local script_path; script_path=$(realpath "$0")

  cat > /etc/systemd/system/pve-update.service <<EOF
[Unit]
Description=Proxmox Host + LXC Update Applier
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$script_path --apply
StandardOutput=journal
StandardError=journal
EOF

  local on_calendar
  case "$schedule" in
    daily)  on_calendar="daily" ;;
    weekly) on_calendar="weekly" ;;
    *)
      echo "Unknown schedule '$schedule'. Use 'daily' or 'weekly'." >&2
      exit 1
      ;;
  esac

  cat > /etc/systemd/system/pve-update.timer <<EOF
[Unit]
Description=Run pve-update $schedule

[Timer]
OnCalendar=$on_calendar
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now pve-update.timer
  echo -e "${GREEN}✔  Timer installed (${schedule}):${NC}"
  systemctl status pve-update.timer --no-pager -l
}

if [[ "$INSTALL_TIMER" == true ]]; then
  install_timer "$TIMER_SCHEDULE"
  exit 0
fi

if [[ "$SELF_UPDATE" == true ]]; then
  self_update
  exit 0
fi

# Best-effort "new version available" notice — interactive runs only, so the
# systemd timer's --apply runs stay quiet and don't depend on the network.
if [[ -t 1 && "$NO_UPDATE_CHECK" != true ]]; then
  check_for_update
fi

# --- Collect running CTs ---
mapfile -t ALL_CTS < <(pct list 2>/dev/null | awk '/running/{print $1}')

# --- Resolve what to update: PVE host and/or LXC containers ---
if [[ "$HOST_ONLY" == true ]]; then
  INCLUDE_HOST=true
  CTS=()
elif [[ ${#TARGET_CTS[@]} -gt 0 || "$TARGET_HOST" == true ]]; then
  # Explicit targets given — only touch what was named.
  CTS=("${TARGET_CTS[@]}")
  if [[ "$TARGET_HOST" == true ]]; then INCLUDE_HOST=true; else INCLUDE_HOST=false; fi
else
  # No targets — default to the host plus every running CT.
  CTS=("${ALL_CTS[@]}")
fi

# --no-host always wins.
[[ "$NO_HOST" == true ]] && INCLUDE_HOST=false

if [[ "$INCLUDE_HOST" != true && ${#CTS[@]} -eq 0 ]]; then
  echo "Nothing to do — no host selected and no running containers."
  exit 0
fi

# =============================================================================
# CONFIRM-BEFORE-APPLY GATE
# =============================================================================
# When applying interactively, first preview what's available (re-run ourselves
# in check mode with the same targets) and require a y/N before changing
# anything. Skipped when: -y/--yes was given, this is the nested check pass, or
# stdin isn't a terminal (the systemd timer, or a piped run) — those apply
# unattended. Gate on stdin (-t 0) only, NOT stdout: `read` reads stdin and its
# prompt goes to stderr, so `--apply | tee log` still prompts correctly. This
# also fails safe — no real stdin means the prompt is skipped for unattended
# runs, and if it ever fired without stdin, read's EOF leaves _reply empty → "no
# changes". The check pass has no side effects.
if [[ "$MODE" == "apply" && "${PVE_UPDATE_NESTED:-}" != "1" && "$ASSUME_YES" != true && -t 0 ]]; then
  echo ""
  echo -e "${BOLD}Previewing available updates before applying...${NC}"
  check_args=()
  for _a in "${ORIG_ARGS[@]}"; do
    case "$_a" in
      --apply|-y|--yes) ;;              # drop apply/consent flags → check mode
      *) check_args+=("$_a") ;;
    esac
  done
  # </dev/null so the preview's pct exec calls can't consume the terminal input
  # meant for the prompt below.
  PVE_UPDATE_NESTED=1 "$(realpath "$0")" --no-update-check "${check_args[@]}" </dev/null
  echo ""
  read -r -p "$(echo -e "${BOLD}Apply these updates now? [y/N] ${NC}")" _reply
  if [[ ! "$_reply" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}No changes made.${NC}"
    exit 0
  fi
  echo ""
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Proxmox Update Report — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  Mode: ${CYAN}${MODE}${NC}${BOLD}  APT-only: ${APT_ONLY}  Host: ${INCLUDE_HOST}  Containers: ${#CTS[@]}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

TOTAL_PKG=0
TOTAL_COMMUNITY=0
TOTAL_DOCKER=0
FAILED_CTS=()
SKIPPED_CTS=()
HOST_FAILED=false
HOST_REBOOT=false
REBOOT_KERNEL=""

# =============================================================================
# 0. PVE HOST OS UPGRADES  (run directly on the hypervisor, no pct exec)
# =============================================================================
update_host() {
  local host_start; host_start=$(date +%s)
  local hname; hname=$(hostname 2>/dev/null)
  local pveline; pveline=$(pveversion 2>/dev/null | head -n1)

  echo ""
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}  PVE HOST — ${hname}${NC}  (${pveline:-Proxmox VE}) [apt]"
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"

  echo -e "\n  ${CYAN}[$(timestamp)] [apt]${NC} Checking for package updates..."
  apt-get update -qq >/dev/null 2>&1

  local apt_upgrades apt_count
  # Proxmox recommends dist-upgrade (full-upgrade), not plain upgrade.
  apt_upgrades=$(apt-get -s dist-upgrade 2>/dev/null | grep "^Inst ")
  apt_count=0
  [[ -n "$apt_upgrades" ]] && apt_count=$(echo "$apt_upgrades" | grep -c "^Inst")

  if [[ "$apt_count" -gt 0 ]]; then
    TOTAL_PKG=$((TOTAL_PKG + apt_count))
    echo -e "  ${YELLOW}⬆  ${apt_count} package(s) upgradeable:${NC}"
    echo "$apt_upgrades" | while IFS= read -r line; do
      pkg=$(echo "$line" | awk '{print $2}')
      old=$(echo "$line" | awk -F'[][]' '{print $2}')
      new=$(echo "$line" | awk -F'[()]' '{print $2}' | awk '{print $1}')
      echo -e "     ${pkg}: ${old} → ${GREEN}${new}${NC}"
    done

    if [[ "$MODE" == "apply" ]]; then
      echo -e "  ${CYAN}[$(timestamp)] [apt]${NC} Applying upgrades (dist-upgrade)..."
      local apt_output apt_exit
      apt_output=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1)
      apt_exit=$?
      echo "$apt_output" | grep -E '^(Unpacking|Setting up|Errors|E:|Processing|Need to)' | sed "s/^/     /"
      if [[ $apt_exit -eq 0 ]]; then
        echo -e "  ${GREEN}✔  apt dist-upgrade applied${NC}"
      else
        echo -e "  ${RED}✘  apt dist-upgrade failed (exit $apt_exit)${NC}"
        HOST_FAILED=true
      fi
    fi
  else
    echo -e "  ${GREEN}✔  OS packages are up to date${NC}"
  fi

  # Reboot detection. Proxmox ships no /run/reboot-required, so a kernel
  # update would otherwise go unnoticed. Compare the running kernel against
  # the newest installed one (each installed ABI has a dir in /lib/modules)
  # and flag a reboot when a newer kernel is staged. Never reboot automatically.
  local running_kernel newest_kernel reboot_needed=false
  running_kernel=$(uname -r)
  newest_kernel=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)

  if [[ -n "$newest_kernel" && "$newest_kernel" != "$running_kernel" \
        && "$(printf '%s\n%s\n' "$newest_kernel" "$running_kernel" | sort -V | tail -n1)" == "$newest_kernel" ]]; then
    reboot_needed=true
    REBOOT_KERNEL="$newest_kernel"
  fi
  if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    reboot_needed=true
  fi

  if [[ "$reboot_needed" == true ]]; then
    HOST_REBOOT=true
    if [[ -n "$REBOOT_KERNEL" ]]; then
      echo -e "  ${YELLOW}⚠  Reboot required — running ${running_kernel}, ${REBOOT_KERNEL} installed${NC}"
    else
      echo -e "  ${YELLOW}⚠  Reboot required to finish applying updates${NC}"
    fi
  fi

  local host_elapsed=$(( $(date +%s) - host_start ))
  echo -e "  ${CYAN}── completed in ${host_elapsed}s${NC}"
}

if [[ "$INCLUDE_HOST" == true ]]; then
  update_host
fi

# =============================================================================
# PER-CONTAINER UPDATE LOGIC  (called in parallel — one subprocess per CT)
# =============================================================================
process_ct() {
  local ctid="$1"
  local results_file="$2"
  local CT_START; CT_START=$(date +%s)
  local ct_pkg=0 ct_community=0 ct_docker=0
  local ct_skipped=""   # reason, when a community script declined a precondition
  local ct_error=false

  # Verify the CT is running
  local status; status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
  if [[ "$status" != "running" ]]; then
    echo -e "\n${YELLOW}⏭  CT $ctid — not running, skipping${NC}"
    printf '0|0|0|\n' >> "$results_file"
    return
  fi

  local ct_hostname; ct_hostname=$(pct config "$ctid" 2>/dev/null | awk '/^hostname/{print $2}')

  # Detect OS and package manager — handles Alpine (ash/apk) vs Debian (bash/apt)
  local os; os=$(pct exec "$ctid" -- sh -c '. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"' 2>/dev/null)
  local pkg_manager="apt"
  if pct exec "$ctid" -- sh -c 'command -v apk >/dev/null 2>&1' 2>/dev/null; then
    pkg_manager="apk"
  elif ! pct exec "$ctid" -- sh -c 'command -v apt-get >/dev/null 2>&1' 2>/dev/null; then
    pkg_manager="unknown"
  fi

  # Detect apps that need extra env vars to upgrade non-interactively.
  # homebridge-apt-pkg refuses apt upgrades whose process tree includes
  # hb-service (its own updater runs under it) unless UPDATE_HOMEBRIDGE_FORCE=1
  # is set. Detecting homebridge reliably under pct exec is fiddly — the
  # 'homebridge' binary lives under the package's private node runtime and
  # hb-service isn't consistently on PATH — so we just always set the flag on
  # Debian/apt containers. It's a homebridge-only variable that every other
  # package ignores, so it is harmless elsewhere.
  local extra_env=""
  if [[ "$pkg_manager" == "apt" ]]; then
    extra_env="UPDATE_HOMEBRIDGE_FORCE=1"
  fi

  echo ""
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}  CT ${ctid} — ${ct_hostname}${NC}  (${os:-unknown OS}) [${pkg_manager}]"
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"

  # =========================================================================
  # 1. OS PACKAGE UPGRADES
  # =========================================================================

  if [[ "$pkg_manager" == "apt" ]]; then
    echo -e "\n  ${CYAN}[$(timestamp)] [apt]${NC} Checking for package updates..."
    pct exec "$ctid" -- bash -c 'apt-get update -qq 2>&1' >/dev/null 2>&1

    local apt_upgrades; apt_upgrades=$(pct exec "$ctid" -- bash -c 'apt-get -s upgrade 2>/dev/null | grep "^Inst "' 2>/dev/null)
    local apt_count=0
    [[ -n "$apt_upgrades" ]] && apt_count=$(echo "$apt_upgrades" | grep -c "^Inst")

    if [[ "$apt_count" -gt 0 ]]; then
      ct_pkg=$((ct_pkg + apt_count))
      echo -e "  ${YELLOW}⬆  ${apt_count} package(s) upgradeable:${NC}"
      echo "$apt_upgrades" | while IFS= read -r line; do
        local pkg old new
        pkg=$(echo "$line" | awk '{print $2}')
        old=$(echo "$line" | awk -F'[][]' '{print $2}')
        new=$(echo "$line" | awk -F'[()]' '{print $2}' | awk '{print $1}')
        echo -e "     ${pkg}: ${old} → ${GREEN}${new}${NC}"
      done

      if [[ "$MODE" == "apply" ]]; then
        echo -e "  ${CYAN}[$(timestamp)] [apt]${NC} Applying upgrades..."
        local apt_output apt_exit
        apt_output=$(pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive${extra_env:+ $extra_env} apt-get upgrade -y 2>&1")
        apt_exit=$?
        echo "$apt_output" | grep -E '^(Unpacking|Setting up|Errors|E:|Processing|Need to)' | sed "s/^/     /"
        if [[ $apt_exit -eq 0 ]]; then
          echo -e "  ${GREEN}✔  apt upgrades applied${NC}"
        else
          echo -e "  ${RED}✘  apt upgrade failed (exit $apt_exit)${NC}"
          ct_error=true
        fi
      fi
    else
      echo -e "  ${GREEN}✔  OS packages are up to date${NC}"
    fi

  elif [[ "$pkg_manager" == "apk" ]]; then
    echo -e "\n  ${CYAN}[$(timestamp)] [apk]${NC} Checking for package updates..."
    local apk_upgrades; apk_upgrades=$(pct exec "$ctid" -- sh -c 'apk update >/dev/null 2>&1; apk list -u 2>/dev/null' 2>/dev/null)
    local apk_count=0
    [[ -n "$apk_upgrades" ]] && apk_count=$(echo "$apk_upgrades" | grep -c '[a-z]')

    if [[ "$apk_count" -gt 0 ]]; then
      ct_pkg=$((ct_pkg + apk_count))
      echo -e "  ${YELLOW}⬆  ${apk_count} package(s) upgradeable:${NC}"
      echo "$apk_upgrades" | sed 's/^/     /'

      if [[ "$MODE" == "apply" ]]; then
        echo -e "  ${CYAN}[$(timestamp)] [apk]${NC} Applying upgrades..."
        pct exec "$ctid" -- sh -c 'apk upgrade --no-cache 2>&1' | sed 's/^/     /'
        local apk_exit=${PIPESTATUS[0]}
        if [[ $apk_exit -eq 0 ]]; then
          echo -e "  ${GREEN}✔  apk upgrades applied${NC}"
        else
          echo -e "  ${RED}✘  apk upgrade failed (exit $apk_exit)${NC}"
          ct_error=true
        fi
      fi
    else
      echo -e "  ${GREEN}✔  OS packages are up to date${NC}"
    fi

  else
    echo -e "\n  ${YELLOW}⚠  Unknown package manager — skipping OS updates${NC}"
  fi

  if [[ "$APT_ONLY" == true ]]; then
    local CT_ELAPSED=$(( $(date +%s) - CT_START ))
    echo -e "  ${CYAN}── completed in ${CT_ELAPSED}s${NC}"
    local ct_failed_entry=""
    [[ "$ct_error" == true ]] && ct_failed_entry="$ctid ($ct_hostname)"
    local ct_skipped_entry=""
    [[ -n "$ct_skipped" ]] && ct_skipped_entry="$ctid ($ct_hostname): $ct_skipped"
    printf '%s|%s|%s|%s|%s\n' "$ct_pkg" "$ct_community" "$ct_docker" "$ct_failed_entry" "$ct_skipped_entry" >> "$results_file"
    return
  fi

  # =========================================================================
  # 2. COMMUNITY SCRIPT UPDATE
  # =========================================================================
  local has_update; has_update=$(pct exec "$ctid" -- sh -c 'test -f /usr/bin/update && echo yes || echo no' 2>/dev/null)

  if [[ "$has_update" == "yes" ]]; then
    ct_community=$((ct_community + 1))
    local update_cmd; update_cmd=$(pct exec "$ctid" -- cat /usr/bin/update 2>/dev/null)
    echo -e "\n  ${CYAN}[$(timestamp)] [community-script]${NC} Update mechanism found"

    if [[ "$MODE" == "apply" ]]; then
      echo -e "  ${CYAN}[$(timestamp)] [community-script]${NC} Running update..."
      # Write the script to a temp file to avoid shell expansion of its content,
      # then pipe 'yes' to auto-answer interactive prompts (read -p, etc.).
      local _tmp="/tmp/.pve_update_$$_${ctid}"
      printf '%s\n' "$update_cmd" | pct exec "$ctid" -- bash -c "cat > $_tmp"
      # CI=true / NPM_CONFIG_YES tell Node package managers (pnpm/npm) they're
      # non-interactive, so they skip TTY-gated prompts that 'yes |' can't answer.
      # tee streams the output live AND keeps a copy so we can replay the tail on
      # failure. Real pipeline (not $( )), so PIPESTATUS[1] is the timeout/pct exit.
      # 300s, not 120s: community scripts that rebuild a Node/Next.js app
      # (homepage runs pnpm install + pnpm build) routinely need 2-5 minutes in a
      # constrained LXC. A timeout kill surfaces as exit 124 in the failure tail.
      local _clog="/tmp/.pve_clog_$$_${ctid}"
      yes 2>/dev/null | timeout 300 pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export TERM=xterm
        export CI=true
        export NPM_CONFIG_YES=true
        ${extra_env:+export $extra_env; }
        bash $_tmp
      " 2>&1 | tee "$_clog"
      local community_exit=${PIPESTATUS[1]}
      pct exec "$ctid" -- rm -f "$_tmp" 2>/dev/null || true
      if [[ $community_exit -eq 0 ]]; then
        echo -e "  ${GREEN}✔  Community script update complete${NC}"
      elif grep -qiE 'storage too low|dangerously low|too low in unattended|low disk' "$_clog" 2>/dev/null; then
        # The community script aborted itself as a precondition (not enough free
        # disk), which is safe/correct — treat it as a skip, not a failure, so it
        # doesn't clutter the "Failed CTs" line. Free up space and re-run.
        ct_skipped="low disk space"
        echo -e "  ${YELLOW}⚠  Community script skipped — low disk space in this container.${NC}"
        echo -e "  ${YELLOW}   Free space (e.g. 'pct resize ${ctid} rootfs +2G') and re-run.${NC}"
      elif grep -qiE 'does not match the recommended|skipping update' "$_clog" 2>/dev/null; then
        # Same class as low disk: the community script refuses to run because the
        # container OS is older than the version it targets. Deliberately NOT
        # bypassed automatically — unlike UPDATE_HOMEBRIDGE_FORCE (a false
        # positive in our context), this guard is correct: the OS really is old,
        # and the project says bypassing may break the app with no support. That
        # is the operator's call, so surface it and let them decide.
        local _osmsg; _osmsg=$(grep -iE 'does not match the recommended' "$_clog" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
        ct_skipped="OS version mismatch"
        echo -e "  ${YELLOW}⚠  Community script skipped — container OS is older than it expects.${NC}"
        [[ -n "$_osmsg" ]] && echo -e "  ${YELLOW}   ${_osmsg}${NC}"
        echo -e "  ${YELLOW}   Upgrade the container OS, or opt in to the project's documented${NC}"
        echo -e "  ${YELLOW}   bypass inside CT ${ctid} (unsupported — may break the app).${NC}"
      else
        echo -e "  ${RED}✘  Community script failed (exit $community_exit) — last output:${NC}"
        tail -20 "$_clog" 2>/dev/null | sed 's/^/     /'
        ct_error=true
      fi
      rm -f "$_clog" 2>/dev/null || true
    else
      echo -e "  ${YELLOW}→  Run with --apply to execute community-script update${NC}"
    fi
  fi

  # =========================================================================
  # 3. DOCKER IMAGE UPDATES
  # =========================================================================
  local has_docker; has_docker=$(pct exec "$ctid" -- sh -c 'command -v docker >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)

  if [[ "$has_docker" == "yes" ]]; then
    echo -e "\n  ${CYAN}[$(timestamp)] [docker]${NC} Checking Docker containers..."

    local docker_info; docker_info=$(pct exec "$ctid" -- docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null)

    if [[ -n "$docker_info" ]]; then
      local compose_files; compose_files=$(pct exec "$ctid" -- sh -c '
        find /opt /root /home /srv /var -maxdepth 4 \
          \( -name "compose.yaml" -o -name "compose.yml" \
             -o -name "docker-compose.yaml" -o -name "docker-compose.yml" \) \
          2>/dev/null
      ' 2>/dev/null)

      while IFS='|' read -r cname cimage; do
        [[ -z "$cname" ]] && continue

        # Determine if the tag is pinned to a specific version (X.Y.Z or vX.Y.Z)
        local tag="${cimage##*:}"
        [[ "$tag" == "$cimage" ]] && tag="latest"  # no tag = latest

        local is_pinned=false
        if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+ && "$tag" != "latest" && ! "$tag" =~ ^[0-9]+$ ]]; then
          is_pinned=true
        fi

        if [[ "$is_pinned" == true ]]; then
          echo -e "  ${YELLOW}📌 ${cname}${NC} — ${cimage} (pinned version)"
          echo -e "     ${YELLOW}→ Update the tag in your compose file to upgrade${NC}"
          ct_docker=$((ct_docker + 1))
        else
          echo -e "  🐳 ${cname} — ${cimage}"

          if [[ "$MODE" == "apply" ]]; then
            echo -e "  ${CYAN}[$(timestamp)] [docker]${NC} Pulling ${cimage}..."
            local pull_output; pull_output=$(pct exec "$ctid" -- docker pull "$cimage" 2>&1)
            echo "$pull_output" | grep -E '^(Pulling|Digest|Status)' | sed 's/^/     /'

            if echo "$pull_output" | grep -q "Image is up to date"; then
              echo -e "  ${GREEN}✔  ${cimage} is already up to date${NC}"
            else
              echo -e "  ${GREEN}⬆  New image pulled for ${cimage}${NC}"
              ct_docker=$((ct_docker + 1))

              # Find the compose file that manages this container and recreate
              while IFS= read -r cf; do
                [[ -z "$cf" ]] && continue
                local managed; managed=$(pct exec "$ctid" -- sh -c "
                  docker compose -f '$cf' ps --format '{{.Names}}' 2>/dev/null | grep -qxF '$cname' && echo yes || echo no
                " 2>/dev/null)

                if [[ "$managed" == "yes" ]]; then
                  echo -e "  ${CYAN}[$(timestamp)] [docker]${NC} Recreating via ${cf}..."
                  pct exec "$ctid" -- sh -c "docker compose -f '$cf' up -d --force-recreate 2>&1" | sed 's/^/     /'
                  echo -e "  ${GREEN}✔  Container recreated${NC}"
                  break
                fi
              done <<< "$compose_files"
            fi
          else
            echo -e "     ${YELLOW}→ Run with --apply to pull & recreate${NC}"
          fi
        fi
      done <<< "$docker_info"
    fi

    # Clean up old images (timeout after 30s to avoid hangs)
    if [[ "$MODE" == "apply" ]]; then
      echo -e "  ${CYAN}[docker]${NC} Pruning unused images..."
      timeout 30 pct exec "$ctid" -- docker image prune -f >/dev/null 2>&1 || \
        echo -e "  ${YELLOW}⚠  Prune timed out or failed (non-critical)${NC}"
    fi
  fi

  local CT_ELAPSED=$(( $(date +%s) - CT_START ))
  echo -e "  ${CYAN}── completed in ${CT_ELAPSED}s${NC}"
  local ct_failed_entry=""
  [[ "$ct_error" == true ]] && ct_failed_entry="$ctid ($ct_hostname)"
  local ct_skipped_entry=""
  [[ -n "$ct_skipped" ]] && ct_skipped_entry="$ctid ($ct_hostname): $ct_skipped"
  printf '%s|%s|%s|%s|%s\n' "$ct_pkg" "$ct_community" "$ct_docker" "$ct_failed_entry" "$ct_skipped_entry" >> "$results_file"
}

# =============================================================================
# 1-3. RUN CONTAINERS IN PARALLEL
# =============================================================================
if [[ ${#CTS[@]} -gt 0 ]]; then
  _results=$(mktemp)
  declare -A _pid_outfile
  _pid_order=()

  for ctid in "${CTS[@]}"; do
    _outfile=$(mktemp)
    process_ct "$ctid" "$_results" > "$_outfile" 2>&1 &
    _pid=$!
    _pid_outfile[$_pid]="$_outfile"
    _pid_order+=("$_pid")
  done

  # Wait in submission order so CT blocks print in a predictable sequence.
  for _pid in "${_pid_order[@]}"; do
    wait "$_pid"
    cat "${_pid_outfile[$_pid]}"
    rm -f "${_pid_outfile[$_pid]}"
  done
  unset _pid_outfile

  # Aggregate per-CT results into the global counters.
  while IFS='|' read -r r_pkg r_comm r_docker r_failed r_skipped; do
    TOTAL_PKG=$((TOTAL_PKG + r_pkg))
    TOTAL_COMMUNITY=$((TOTAL_COMMUNITY + r_comm))
    TOTAL_DOCKER=$((TOTAL_DOCKER + r_docker))
    [[ -n "$r_failed" ]] && FAILED_CTS+=("$r_failed")
    [[ -n "$r_skipped" ]] && SKIPPED_CTS+=("$r_skipped")
  done < "$_results"
  rm -f "$_results"
fi

# =============================================================================
# SUMMARY
# =============================================================================
TOTAL_ELAPSED=$(( $(date +%s) - SCRIPT_START ))
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Summary  (${TOTAL_ELAPSED}s elapsed)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  PVE host updated:      $([[ "$INCLUDE_HOST" == true ]] && echo yes || echo no)"
echo -e "  Containers scanned:    ${#CTS[@]}"
echo -e "  Package upgrades:      ${TOTAL_PKG}"
echo -e "  Community-script CTs:  ${TOTAL_COMMUNITY}"
echo -e "  Docker images noted:   ${TOTAL_DOCKER}"

if [[ "$HOST_FAILED" == true ]]; then
  echo -e "  ${RED}PVE host:              dist-upgrade failed${NC}"
fi

if [[ ${#FAILED_CTS[@]} -gt 0 ]]; then
  echo -e "  ${RED}Failed CTs:            ${FAILED_CTS[*]}${NC}"
fi

# Skips are preconditions the community script declined (low disk, OS mismatch)
# — not failures, but list them so they don't silently look like successes.
if [[ ${#SKIPPED_CTS[@]} -gt 0 ]]; then
  echo -e "  ${YELLOW}Skipped (needs action):${NC}"
  for _s in "${SKIPPED_CTS[@]}"; do
    echo -e "  ${YELLOW}   - ${_s}${NC}"
  done
fi

if [[ "$HOST_REBOOT" == true ]]; then
  if [[ -n "$REBOOT_KERNEL" ]]; then
    echo -e "  ${YELLOW}Reboot required:       boot into ${REBOOT_KERNEL} (run 'reboot')${NC}"
  else
    echo -e "  ${YELLOW}Reboot required:       run 'reboot' on the PVE host${NC}"
  fi
fi

if [[ "$MODE" == "check" && "${PVE_UPDATE_NESTED:-}" != "1" ]]; then
  echo ""
  echo -e "  ${YELLOW}This was a CHECK-ONLY run. To apply updates:${NC}"
  echo -e "  ${BOLD}  ./pve-update.sh --apply${NC}            # host + all containers"
  echo -e "  ${BOLD}  ./pve-update.sh --apply 112 113${NC}    # specific containers"
  echo -e "  ${BOLD}  ./pve-update.sh --host-only --apply${NC} # Proxmox host only"
  echo -e "  ${BOLD}  ./pve-update.sh --apt-only --apply${NC} # OS patches only"
fi

echo ""
