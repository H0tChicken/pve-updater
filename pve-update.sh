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
#   ./pve-update.sh --apply --exclude 129,130  # Leave CTs 129 + 130 alone
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
# pinned key aborts without touching the installed script. Runs whose output
# isn't a terminal skip the update check entirely. See the README to set up
# signing.
#
# --apply works in two steps over the same targets: it checks everything first
# (exactly what a check run reports), then applies only what that check found.
# It asks for a y/N between the two, so nothing changes until you say yes. Pass
# -y to skip the prompt. Without a terminal to ask on (plain 'ssh' without -t,
# a pipe, cron) --apply refuses to run unless -y is given.
#
# What it does:
#   0. PVE host: apt update && check/apply dist-upgrade (full-upgrade)
#   1. OS-level: apt/apk update && check/apply upgrades (Debian + Alpine)
#   2. *arr apps (Sonarr, Radarr, Prowlarr, ...): report the running version
#      against the newest one the app's own updater offers. Report only.
#   3. Community scripts: detect /usr/bin/update and run it (--apply), unless
#      the app already runs a newer major than the script last installed. A
#      failed run is rolled back to a ZFS snapshot of the CT's root disk taken
#      just before it, and its evidence kept in /var/log/pve-update/.
#   4. Docker: detect running containers, pull new images, and recreate only
#      the containers still running an older image (--apply). Locally built
#      images and failed pulls are reported, never recreated.
#
# The Proxmox host is included by default. Use 'host'/'pve' as a target,
# --host-only, or --no-host to control this. The host uses dist-upgrade
# (full-upgrade) per Proxmox best practice, and a reboot hint is shown when
# a new kernel/libs require it — the script never reboots automatically.
# New LXCs are automatically discovered — no configuration needed.
# VMs (qm) are not handled by this script.
#
# To keep the run away from a CT: --exclude 129,130. To defer a CT only while
# it's busy, put an executable at /etc/pve-updater/hooks/<ctid> on the host:
# it runs before each --apply touches that CT, gets the CT ID as $1, and a
# non-zero exit skips the CT until the next run.
#
# Optional /etc/default/pve-update (KEY=value, never sourced) sets an ntfy
# topic URL and token, PVE_UPDATE_NTFY and PVE_UPDATE_NTFY_TOKEN: an --apply
# run in which something failed then sends one push. A run with a failure
# exits 1.
#
# For Docker containers with PINNED version tags (e.g. traefik:v3.6.17),
# the script will warn you but NOT auto-update — you must manually change
# the tag in the compose file first. It WILL auto-pull :latest or
# unpinned tags.
# =============================================================================

set -o pipefail

# The console palette: CYAN for structure and labels, YELLOW (amber) for
# anything pending, GREEN for done, RED for holds and failures, DIM grey for
# the frame, WHITE for names. Terminals only: piped output gets plain text.
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[38;5;214m'
  CYAN='\033[0;36m'
  DIM='\033[38;5;240m'
  WHITE='\033[1;97m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' DIM='' WHITE='' BOLD='' NC=''
fi

# Columns $1 takes on screen. The colours above are still the literal text
# '\033[...m' wherever this is used, so they are cut as text; each UTF-8
# character then counts once whatever the locale (continuation bytes dropped).
vis_len() {
  printf '%s' "$1" | sed 's/\\033\[[0-9;]*m//g' | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '
}

# $2 copies of the character $1.
rep_char() {
  local out="" n=$2
  while (( n-- > 0 )); do out+="$1"; done
  printf '%s' "$out"
}

# Cards: one per host, CT and apply step. Open on the right, so long lines
# never need cutting.
CARD_W=64
BAR="${DIM}│${NC}"
# The subsystem code column, and the indent that lines up under it.
C_PKG="${BAR} ${CYAN}PKG${NC}  "
C_ARR="${BAR} ${CYAN}ARR${NC}  "
C_CS="${BAR} ${CYAN}CS${NC}   "
C_DKR="${BAR} ${CYAN}DKR${NC}  "
C_HOOK="${BAR} ${CYAN}HOOK${NC} "
C_SNAP="${BAR} ${CYAN}SNAP${NC} "
C_RBK="${BAR} ${CYAN}RBK${NC}  "
C_SYS="${BAR} ${CYAN}SYS${NC}  "
C_IND="${BAR}      "

# ┌─[A]─[B]… Each argument is one bracketed segment, colours included. The ─
# filler takes the header to CARD_W columns (none if it is already longer).
card_open() {
  local head="${DIM}┌" seg fill
  for seg in "$@"; do head+="─[${NC}${seg}${DIM}]"; done
  fill=$(( CARD_W - $(vis_len "$head") ))
  (( fill > 0 )) && head+="$(rep_char ─ "$fill")"
  echo -e "${head}${NC}"
}

# └──… Ns ─ with $1 seconds elapsed.
card_close() {
  local fill=$(( CARD_W - 1 - $(vis_len " ${1}s ─") ))
  echo -e "${DIM}└$(rep_char ─ "$fill")${NC} ${CYAN}${1}s${NC} ${DIM}─${NC}"
}

# ▰▰▰▱▱▱▱▱▱▱: one cell per pending package, full from ten up.
gauge() {
  local n=$1; (( n > 10 )) && n=10
  printf '%s' "${YELLOW}$(rep_char ▰ "$n")${DIM}$(rep_char ▱ $(( 10 - n )))${NC}"
}

# Dim [HH:MM:SS] for the lines that start a step.
ts() { printf '%s' "${DIM}[$(timestamp)]${NC}"; }

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "Error: 'pct' not found — this script requires Proxmox VE." >&2
  exit 1
fi

exec 200>/var/lock/pve-update.lock
if ! flock -n 200; then
  echo "Error: another instance of pve-update.sh is already running." >&2
  exit 1
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
      echo -e "${YELLOW}▲ UPDATE AVAILABLE${NC} — a newer version of pve-update.sh is on GitHub."
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
SELF_UPDATE=false
NO_UPDATE_CHECK=false
ASSUME_YES=false
EXCLUDE_CTS=()

# CT IDs separated by commas and/or spaces, e.g. "129,130" or "129 130".
add_excludes() {
  local id
  for id in ${1//,/ }; do
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
      echo "Invalid CT ID '$id' for --exclude (use e.g. --exclude 129,130)" >&2
      exit 1
    fi
    EXCLUDE_CTS+=("$id")
  done
}

# Optional settings that don't belong on a command line or in the repo: where
# to push an ntfy notification when something in a run fails, and its token.
# Read as KEY=value data, never sourced, and only these keys; a value already
# in the environment wins. No file means no push.
PVE_UPDATE_CONFIG="${PVE_UPDATE_CONFIG:-/etc/default/pve-update}"
PVE_UPDATE_LOG_DIR="${PVE_UPDATE_LOG_DIR:-/var/log/pve-update}"
# Where the per-CT busy hooks live (see act_ct); the tests point it elsewhere.
PVE_UPDATE_HOOK_DIR="${PVE_UPDATE_HOOK_DIR:-/etc/pve-updater/hooks}"
if [[ -r "$PVE_UPDATE_CONFIG" ]]; then
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ "$_line" =~ ^[[:space:]]*(PVE_UPDATE_NTFY|PVE_UPDATE_NTFY_TOKEN)=(.*)$ ]] || continue
    _k="${BASH_REMATCH[1]}" _v="${BASH_REMATCH[2]%$'\r'}"
    [[ "$_v" =~ ^\"(.*)\"$ || "$_v" =~ ^\'(.*)\'$ ]] && _v="${BASH_REMATCH[1]}"
    [[ -z "${!_k:-}" ]] && printf -v "$_k" '%s' "$_v"
  done < "$PVE_UPDATE_CONFIG"
  unset _line _k _v
fi

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
    --exclude)
      # Take the value here, or a bare ID would fall through to *) as a target.
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "--exclude needs a CT list, e.g. --exclude 129,130" >&2; exit 1
      fi
      add_excludes "$2"; shift 2 ;;
    --exclude=*) add_excludes "${1#--exclude=}"; shift ;;
    --version)
      echo "pve-update.sh  (sha256 $(self_sha | cut -c1-12))"
      exit 0 ;;
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

# --apply changes nothing until someone says yes at the prompt, and the prompt
# needs a terminal to read the answer from. Without one (plain 'ssh' without
# -t, a pipe, cron) refuse outright, before any check work, rather than apply
# with nobody asked. -y is the explicit way to apply without confirming. Gate on
# stdin (-t 0) only, NOT stdout: `read` reads stdin and its prompt goes to
# stderr, so `--apply | tee log` still prompts correctly.
if [[ "$MODE" == "apply" && "$ASSUME_YES" != true && ! -t 0 ]]; then
  echo "Error: no terminal to confirm on — run with 'ssh -t', or pass -y to apply without confirming." >&2
  exit 1
fi

if [[ "$SELF_UPDATE" == true ]]; then
  self_update
  exit 0
fi

# Best-effort "new version available" notice — interactive runs only, so piped
# or logged runs stay quiet and don't depend on the network.
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

# --exclude wins too, even over a CT named explicitly as a target.
if [[ ${#EXCLUDE_CTS[@]} -gt 0 ]]; then
  _kept=()
  for _c in "${CTS[@]}"; do
    [[ " ${EXCLUDE_CTS[*]} " == *" $_c "* ]] || _kept+=("$_c")
  done
  CTS=("${_kept[@]}")
fi

# Each CT once, in the order given: '101 101' would otherwise run two jobs in
# the same CT that share one state file.
declare -A _seen=()
_kept=()
for _c in "${CTS[@]}"; do
  [[ -n "${_seen[$_c]:-}" ]] || _kept+=("$_c")
  _seen[$_c]=1
done
CTS=("${_kept[@]}")
unset _seen _kept

if [[ "$INCLUDE_HOST" != true && ${#CTS[@]} -eq 0 ]]; then
  echo "Nothing to do — no host selected and no running containers."
  exit 0
fi

# A plain `ssh root@pve ./pve-update.sh` allocates no TTY, which silently
# drops colors and the live progress line. (--apply without -y already refused
# above.) Only SSH sessions set SSH_CONNECTION, so this hint only reaches them.
if [[ -n "${SSH_CONNECTION:-}" && ! -t 0 ]]; then
  echo "Note: no terminal detected over SSH — run 'ssh -t' for colors and live progress." >&2
fi

# Banner and status strip, once per run. The strip's rows are padded by their
# visible width, so the box closes on the right whatever is in it.
HOST_NAME=$(hostname 2>/dev/null)
_rows=(
  "${CYAN}●${NC} HOST ${WHITE}${HOST_NAME^^}${NC}   MODE ${CYAN}▸${NC} ${WHITE}${MODE^^}${NC}   UNITS ${WHITE}${#CTS[@]}${NC}   $(date '+%Y-%m-%d %H:%M:%S')"
  "PVE HOST ${CYAN}▸${NC} $([[ "$INCLUDE_HOST" == true ]] && echo INCLUDED || echo SKIPPED)   APT-ONLY ${CYAN}▸${NC} $([[ "$APT_ONLY" == true ]] && echo ON || echo OFF)"
)
[[ ${#EXCLUDE_CTS[@]} -gt 0 ]] && _rows+=("EXCLUDED ${CYAN}▸${NC} ${EXCLUDE_CTS[*]}")
_box_w=60
for _r in "${_rows[@]}"; do (( $(vis_len "$_r") + 2 > _box_w )) && _box_w=$(( $(vis_len "$_r") + 2 )); done
echo ""
echo -e "${CYAN}▓▓▒▒░░ ${WHITE}P V E · U P D A T E R${NC}  ${CYAN}░░▒▒▓▓${NC}   ${DIM}FLEET SYS // $(self_sha | cut -c1-8)${NC}"
echo -e "${DIM}┏$(rep_char ━ "$_box_w")┓${NC}"
for _r in "${_rows[@]}"; do
  echo -e "${DIM}┃${NC} ${_r}$(rep_char ' ' $(( _box_w - 1 - $(vis_len "$_r") )))${DIM}┃${NC}"
done
echo -e "${DIM}┗$(rep_char ━ "$_box_w")┛${NC}"
unset _rows _r _box_w

# Filled from the per-CT results by tally_results, once after the check and
# again after the apply.
TOTAL_PKG=0
TOTAL_COMMUNITY=0
# Two different outcomes, two different counters: images we pulled (or would
# pull), vs images stuck on a pinned tag that only a compose-file edit can move.
TOTAL_DOCKER_UPDATED=0
TOTAL_DOCKER_PINNED=0
TOTAL_DOCKER_UNKNOWN=0
TOTAL_APP_FOUND=0
TOTAL_APP_BEHIND=0
TOTAL_APP_UNKNOWN=0
TOTAL_TODO_CTS=0
FAILED_CTS=()
FAIL_PRIO=0          # highest ntfy priority any failure asked for
SKIPPED_CTS=()
NO_PATH_APPS=()
HOST_PKG=0
HOST_FAILED=false
NTFY_NOTE=""         # the push's outcome, for the status board
# Names this run's snapshots and failure-log dirs.
RUN_ID=$(date -d "@$SCRIPT_START" '+%Y%m%d-%H%M%S')
HOST_REBOOT=false
REBOOT_KERNEL=""

# Everything one run hands from its check to its apply (per-CT state, results,
# output) lives here, and goes when the script exits however it exits. The
# traps are set here and nowhere else: self_update has its own EXIT trap, but
# it exits before this point, so the two never meet.
RUN_DIR=$(mktemp -d) || { echo "Error: mktemp failed." >&2; exit 1; }
_live_status=false
[[ -t 1 ]] && _live_status=true
_clear_status() { [[ "$_live_status" == true ]] && printf '\r\033[K'; }
# CT jobs of the phase in progress (pid → output file), for _on_signal.
declare -A _PHASE_OUT=()
_in_signal=false
_applying=false      # true from the start of the apply step: changes may follow
_host_acting=false   # true while the host's dist-upgrade runs

# Ctrl-C or a kill while CT jobs run. The jobs never see Ctrl-C (bash ignores
# SIGINT in a script's background jobs) and a kill only reaches this shell, so
# they carry on, possibly mid-upgrade, whatever happens here. Exiting now
# would delete RUN_DIR under them and lose their reports. Wait for them, show
# what they did, then exit. A second Ctrl-C during the wait lands here again
# and just goes back to waiting.
#
# Interrupted during the apply step, something may already have changed, so
# the run still ends the way a finished one does: the board (marked as
# interrupted) and the failure push. Only CTs whose apply job ran are on it;
# a CT whose job never started reported nothing. An interrupted check or
# prompt changed nothing and just exits.
_on_signal() {
  [[ "$_in_signal" == true ]] && return
  _in_signal=true
  _clear_status
  local -a live=()
  local pid
  for pid in "${!_PHASE_OUT[@]}"; do kill -0 "$pid" 2>/dev/null && live+=("$pid"); done
  if [[ ${#live[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}‖ HOLDING — WAITING FOR ${#live[@]} CT(S) ALREADY IN PROGRESS${NC}" >&2
    echo -e "  Stopping mid-upgrade isn't safe; exiting once they finish." >&2
    # wait returns early when another signal arrives, so loop until each is gone.
    for pid in "${live[@]}"; do
      while kill -0 "$pid" 2>/dev/null; do wait "$pid" 2>/dev/null; done
    done
  fi
  for pid in "${!_PHASE_OUT[@]}"; do cat "${_PHASE_OUT[$pid]}" 2>/dev/null; done
  if [[ "$_applying" == true ]]; then
    # From here Ctrl-C and kill are ignored, by curl too, so a second one
    # can't cut the report short. curl's own timeout bounds the push.
    trap '' INT TERM
    # A dist-upgrade cut off part-way may have left dpkg half-configured.
    [[ "$_host_acting" == true ]] && HOST_FAILED=true
    tally_results "$RUN_DIR/act_ct.results"
    send_failure_push
    print_summary interrupted
  fi
  exit "$1"
}

# Leave a clean line if the run is interrupted mid-redraw.
trap '_clear_status; rm -rf "$RUN_DIR"' EXIT
trap '_on_signal 130' INT
trap '_on_signal 143' TERM

# Highest of the comma-separated versions in $1, or nothing if it's empty.
max_version() {
  [[ -n "${1//,/}" ]] || return 0
  printf '%s\n' ${1//,/ } | sort -V | tail -n1
}

# True when version $1 is a newer MAJOR than version $2 (either may start with
# 'v'). False whenever either side isn't a plain number, so a missing marker or
# an app that didn't answer can never trip it.
major_ahead() {
  local a="${1#v}" b="${2#v}"
  a="${a%%.*}"; b="${b%%.*}"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && (( 10#$a > 10#$b ))
}

# The ZFS dataset that holds CT $1's root disk, or nothing (return 1) when it
# isn't a ZFS subvol. Root disk only: mount points (data volumes, bind mounts)
# are never snapshotted or rolled back.
ct_rootfs_dataset() {
  local vol path ds
  vol=$(pct config "$1" 2>/dev/null | sed -n 's/^rootfs: *\([^,]*\).*/\1/p')
  [[ -n "$vol" ]] || return 1
  path=$(pvesm path "$vol" 2>/dev/null) || return 1
  ds=$(zfs list -H -o name "$path" 2>/dev/null) || return 1
  # A path on some other dataset (a 'dir' storage that sits on ZFS) resolves to
  # that dataset: only the CT's own subvol will do.
  [[ "$ds" == */"${vol#*:}" ]] || return 1
  echo "$ds"
}

# Services running in CT $1, one per line (nothing on a CT without systemd).
ct_running_services() {
  pct exec "$1" -- sh -c 'systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk "{print \$1}"' \
    </dev/null 2>/dev/null
}

# Lines of $1 that aren't in $2 (both newline-separated lists).
list_minus() {
  comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
}

# After a community script failed in a CT: keep the evidence, roll the rootfs
# back to the pre-update snapshot, start the CT, and check that what the script
# stopped is running again. Called from act_ct, whose locals it reads (ctid,
# ct_hostname, cs_slug, cs_snap, cs_before, cs_t0, _clog, community_exit) and
# sets (ct_fail_note, ct_fail_prio). Prints into act_ct's card.
#
# The evidence goes first because the rollback wipes it from inside the CT.
# A rollback restarts the whole CT and loses what it wrote since the snapshot:
# a few minutes, during which the script had stopped the app anyway.
cs_recover() {
  local dir="${PVE_UPDATE_LOG_DIR}/${RUN_ID}-ct${ctid}-${cs_slug:-unknown}"
  mkdir -p "$dir" && chmod 700 "$dir"
  local after down mins oom=false
  after=$(ct_running_services "$ctid")
  down=$(list_minus "$cs_before" "$after")
  mins=$(( ( $(date +%s) - cs_t0 ) / 60 + 2 ))

  sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$_clog" > "$dir/community-script.log" 2>/dev/null
  # Community scripts log to /tmp/create-lxc-*.log, with a .errinfo on failure.
  pct exec "$ctid" -- sh -c "for f in \$(find /tmp -maxdepth 1 -name 'create-lxc-*' -mmin -$mins 2>/dev/null); do echo \"==> \$f <==\"; tail -n 300 \"\$f\"; done" \
    </dev/null > "$dir/ct-tmp-logs.txt" 2>&1
  pct exec "$ctid" -- sh -c "command -v journalctl >/dev/null && journalctl --no-pager -q -S @$cs_t0 | tail -n 1000" \
    </dev/null > "$dir/ct-journal.txt" 2>&1
  # A cgroup OOM kill names the CT on the line before the kill itself.
  journalctl -k --no-pager -q -S "@$cs_t0" 2>/dev/null | grep -A1 -E "oom_memcg=/lxc/${ctid}([,/]|$)" > "$dir/kernel.txt"
  [[ -s "$dir/kernel.txt" ]] && oom=true
  {
    echo "running before the update:";  printf '%s\n' "$cs_before" | sed '/^$/d; s/^/  /'
    echo "running after it failed:";     printf '%s\n' "$after" | sed '/^$/d; s/^/  /'
    echo "stopped by the update:";       printf '%s\n' "$down" | sed '/^$/d; s/^/  /'
  } > "$dir/services.txt"

  local rolled=false restarted=false was_running=false
  # Only a CT this stops itself gets started again: one someone else stopped
  # while the script ran stays stopped.
  [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" == "running" ]] && was_running=true
  if [[ -n "$cs_snap" ]]; then
    echo -e "${C_RBK}$(ts) STOPPING CT ${ctid}, ROLLING BACK TO ${cs_snap}"
    pct shutdown "$ctid" --timeout 60 --forceStop 1 >/dev/null 2>&1 || pct stop "$ctid" >/dev/null 2>&1
    if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" == "stopped" ]]; then
      zfs rollback "$cs_snap" 2>>"$dir/rollback.err" && rolled=true
      # Back up either way: an old rootfs is better than a CT left stopped.
      if [[ "$was_running" == true ]]; then
        pct start "$ctid" >>"$dir/rollback.err" 2>&1 && restarted=true
      fi
      [[ "$rolled" == true ]] && zfs destroy "$cs_snap" 2>>"$dir/rollback.err"
    fi
  fi

  # Wait up to a minute for what the script stopped to come back. Without a
  # rollback nothing was restarted, so there's nothing to wait for.
  local ct_up=false still="$down" i
  for (( i = 0; i < 12; i++ )); do
    (( i > 0 )) && sleep 5
    if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
      [[ "$restarted" == true ]] && continue   # still booting
      break
    fi
    ct_up=true
    still=$(list_minus "$down" "$(ct_running_services "$ctid")")
    [[ -z "$still" || "$restarted" != true ]] && break
  done
  local still_csv; still_csv=$(printf '%s\n' "$still" | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')
  local down_csv;  down_csv=$(printf '%s\n' "$down" | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')

  local what="community script failed (exit ${community_exit}"
  [[ "$oom" == true ]] && what+=", out of memory at the CT's limit"
  [[ "$community_exit" -eq 124 ]] && what+=", timed out"
  what+=")"
  local outcome label
  if [[ "$rolled" == true && "$ct_up" == true && -z "$still" ]]; then
    ct_fail_prio=4 label="↺ ROLLED BACK"
    outcome="rolled back to the pre-update snapshot, ${down_csv:-the CT} running again"
  elif [[ "$rolled" == true && "$was_running" != true ]]; then
    ct_fail_prio=5 label="✖ ROLLED BACK, LEFT STOPPED"
    outcome="rolled back; the CT was already stopped when the script failed, so it was left stopped"
  elif [[ "$rolled" == true ]]; then
    ct_fail_prio=5 label="✖ ROLLED BACK, NOT RECOVERED"
    outcome="rolled back, but $([[ "$ct_up" == true ]] && echo "still not running: ${still_csv}" || echo "the CT didn't start")"
  elif [[ -n "$cs_snap" ]]; then
    ct_fail_prio=5 label="✖ ROLLBACK FAILED"
    outcome="rollback failed, snapshot kept: ${cs_snap}; $([[ "$ct_up" == true ]] && echo "CT running${still_csv:+, not running: ${still_csv}}" || echo "CT not running")"
  else
    ct_fail_prio=4 label="✖ NOT ROLLED BACK"
    outcome="not rolled back (no snapshot)"
    if [[ "$ct_up" != true ]]; then ct_fail_prio=5; outcome+=", CT not running"
    elif [[ -n "$still" ]]; then ct_fail_prio=5; outcome+=", still not running: ${still_csv}"
    fi
  fi
  add_fail_note "${what}; ${outcome}; log: ${dir}"
  printf '%s (%s): %s\n' "$ctid" "$ct_hostname" "$ct_fail_note" > "$dir/summary.txt"
  # Amber when everything is back up, red when something may still be down.
  local colour="$YELLOW"; [[ "$ct_fail_prio" -ge 5 ]] && colour="$RED"
  echo -e "${C_RBK}${colour}${label}${NC} — ${outcome}"
  echo -e "${C_IND}Evidence: ${dir}"
}

# Add $1 to what act_ct reports for its CT's failure (its ct_fail_note), so
# the board and the push name every step that failed there.
add_fail_note() {
  ct_fail_note="${ct_fail_note:+$ct_fail_note; }$1"
}

# Push one ntfy message: <priority> <title> <tags> <body>. The token goes to
# curl on stdin (-K -) so it never shows up in argv; the body goes in a file
# so a leading '@' in it can't be read as a file name.
ntfy_push() {
  local f rc; f=$(mktemp) || return 1
  printf '%s' "$4" > "$f"
  { if [[ -n "${PVE_UPDATE_NTFY_TOKEN:-}" ]]; then printf 'header = "Authorization: Bearer %s"\n' "$PVE_UPDATE_NTFY_TOKEN"; fi; } |
    curl -fsS --max-time 15 -K - -H "Title: $2" -H "Priority: $1" -H "Tags: $3" --data-binary "@$f" "$PVE_UPDATE_NTFY" >/dev/null 2>&1
  rc=$?
  rm -f "$f"
  return $rc
}

# =============================================================================
# 0. PVE HOST OS UPGRADES  (run directly on the hypervisor, no pct exec)
# =============================================================================
# The check half: refresh the package lists and list what dist-upgrade would
# install. HOST_PKG is what the apply half acts on.
scan_host() {
  local host_start; host_start=$(date +%s)
  HOST_NAME=$(hostname 2>/dev/null)
  local pveline; pveline=$(pveversion 2>/dev/null | head -n1)

  echo ""
  card_open "${CYAN}HOST" "${WHITE}${HOST_NAME^^}" "${CYAN}${pveline:-Proxmox VE} · APT"
  echo -e "${C_PKG}$(ts) CHECKING FOR PACKAGE UPDATES"
  apt-get update -qq >/dev/null 2>&1

  local apt_upgrades
  # Proxmox recommends dist-upgrade (full-upgrade), not plain upgrade.
  apt_upgrades=$(apt-get -s dist-upgrade 2>/dev/null | grep "^Inst ")
  HOST_PKG=0
  [[ -n "$apt_upgrades" ]] && HOST_PKG=$(echo "$apt_upgrades" | grep -c "^Inst")

  if [[ "$HOST_PKG" -gt 0 ]]; then
    echo -e "${C_PKG}$(gauge "$HOST_PKG")  ${YELLOW}${HOST_PKG} PENDING${NC}"
    echo "$apt_upgrades" | while IFS= read -r line; do
      pkg=$(echo "$line" | awk '{print $2}')
      old=$(echo "$line" | awk -F'[][]' '{print $2}')
      new=$(echo "$line" | awk -F'[()]' '{print $2}' | awk '{print $1}')
      echo -e "${C_IND}${pkg}  ${old} ${CYAN}━▶${NC} ${GREEN}${new}${NC}"
    done
  else
    echo -e "${C_PKG}${GREEN}✔ UP TO DATE${NC}"
  fi

  check_host_reboot

  card_close $(( $(date +%s) - host_start ))
}

# The apply half. Uses the package lists scan_host just refreshed, so it
# installs the same set the check listed.
act_host() {
  local host_start; host_start=$(date +%s)
  echo ""
  card_open "${CYAN}HOST" "${WHITE}${HOST_NAME^^}" "${YELLOW}EXECUTE"
  echo -e "${C_PKG}$(ts) APPLYING UPGRADES (dist-upgrade)"
  # Stream the progress lines as they happen instead of capturing and
  # printing at the end — a big dist-upgrade can take minutes, and over SSH
  # that looked like a hang. Line-buffered so it streams even when piped.
  # Exit status comes from apt-get itself: under pipefail, grep matching
  # nothing would otherwise read as a failed upgrade.
  local apt_exit ind; ind=$(printf '%b' "$C_IND")
  DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1 \
    | grep --line-buffered -E '^(Unpacking|Setting up|Errors|E:|Processing|Need to)' \
    | sed -u "s/^/${ind}/"
  apt_exit=${PIPESTATUS[0]}
  if [[ $apt_exit -eq 0 ]]; then
    echo -e "${C_PKG}${GREEN}✔ APPLIED — apt dist-upgrade${NC}"
  else
    echo -e "${C_PKG}${RED}✖ FAULT — apt dist-upgrade failed (exit $apt_exit)${NC}"
    HOST_FAILED=true
  fi

  # The upgrade may have staged a new kernel.
  check_host_reboot

  card_close $(( $(date +%s) - host_start ))
}

# Reboot detection. Proxmox ships no /run/reboot-required, so a kernel
# update would otherwise go unnoticed. Compare the running kernel against
# the newest installed one (each installed ABI has a dir in /lib/modules)
# and flag a reboot when a newer kernel is staged. Never reboot automatically.
# Runs after the check and again after the apply; the second time it only
# speaks when it finds something the first one didn't.
check_host_reboot() {
  local running_kernel newest_kernel kernel="" reboot_needed=false
  running_kernel=$(uname -r)
  newest_kernel=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1)

  if [[ -n "$newest_kernel" && "$newest_kernel" != "$running_kernel" \
        && "$(max_version "$newest_kernel,$running_kernel")" == "$newest_kernel" ]]; then
    reboot_needed=true
    kernel="$newest_kernel"
  fi
  if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    reboot_needed=true
  fi

  [[ "$reboot_needed" == true ]] || return 0
  [[ "$HOST_REBOOT" == true && "$kernel" == "$REBOOT_KERNEL" ]] && return 0
  HOST_REBOOT=true
  REBOOT_KERNEL="$kernel"
  if [[ -n "$REBOOT_KERNEL" ]]; then
    echo -e "${C_SYS}${YELLOW}⚠ REBOOT REQUIRED${NC} — running ${running_kernel}, ${REBOOT_KERNEL} installed"
  else
    echo -e "${C_SYS}${YELLOW}⚠ REBOOT REQUIRED${NC} to finish applying updates"
  fi
}

# =============================================================================
# *ARR APP VERSIONS  (Sonarr, Radarr, Prowlarr, Lidarr, Readarr, Whisparr)
# =============================================================================
# Runs inside a CT (POSIX sh). For each *arr app laid out the standard way
# (/var/lib/<app>/config.xml, as both the community scripts and the Servarr
# install guide do it), asks the app's own API what it is running and which
# versions its updater offers. One line per app, then '#done' so the caller
# can tell "no *arr apps here" from "the check never ran":
#   app|running|branch|update mechanism|UpdateAutomatically|/root/.<app>|offered,...|started|note
# The API key is read and used only in here: curl gets it on stdin (-K -), so
# it never shows up in argv, and it is never printed. An empty 'running' means
# /system/status didn't answer (note says why when it's known: no curl in the
# CT). An empty 'offered' means /update didn't; that one asks servarr.com, so
# it fails on its own (DNS hiccups) more often.
# 'started' is the version of the app's most recent start, from its own log,
# read only when a community script installed it (the marker exists): it lets
# the major-version guard work while the app is down or its API won't answer.
# The most recent start rather than the highest ever, so a deliberate rollback
# isn't held against the app until its logs rotate out.
# ARR_ONLY="app ..." in the environment limits a re-check to those apps and
# skips the log read and the servarr.com call (the caller still has the list).
# Sonarr, Radarr and Whisparr serve /api/v3; Prowlarr, Lidarr and Readarr /api/v1.
ARR_NAMES="sonarr radarr whisparr prowlarr lidarr readarr"
ARR_PROBE='
x() { sed -n "s:.*<$1>\([^<]*\)</$1>.*:\1:p" "$cfg" | head -n1; }
api() { printf "header = \"X-Api-Key: %s\"\n" "$key" | curl -fsS --max-time "$2" -K - "$url/$1" 2>/dev/null; }
f() { printf "%s" "$st" | grep -oE "\"$1\": *\"[^\"]*\"" | head -n1 | sed "s/.*: *\"//; s/\"\$//"; }
for spec in sonarr:v3 radarr:v3 whisparr:v3 prowlarr:v1 lidarr:v1 readarr:v1; do
  app=${spec%%:*}; cfg=/var/lib/$app/config.xml
  [ -f "$cfg" ] || continue
  case " ${ARR_ONLY:-$app} " in *" $app "*) ;; *) continue ;; esac
  marker=$(head -n1 "/root/.$app" 2>/dev/null | tr -d " \r|") started=""
  [ -n "$marker" ] && [ -z "${ARR_ONLY:-}" ] && started=$(grep -hE "Starting [A-Za-z]+ - .* - Version [0-9.]+" \
    "/var/lib/$app/logs/$app.txt" /var/lib/$app/logs/$app.[0-9]*.txt 2>/dev/null |
    sort | tail -n1 | sed "s/.* Version //")
  if ! command -v curl >/dev/null 2>&1; then
    printf "%s|||||%s||%s|no curl\n" "$app" "$marker" "$started"; continue
  fi
  port=$(x Port); base=$(x UrlBase); bind=$(x BindAddress); key=$(x ApiKey)
  base=${base%/}; case "$base" in ""|/*) ;; *) base="/$base" ;; esac
  case "$bind" in ""|"*"|0.0.0.0|::|"[::]") bind=127.0.0.1 ;; \[*) ;; *:*) bind="[$bind]" ;; esac
  url="http://$bind:${port:-0}$base/api/${spec#*:}"
  st=$(api system/status 10)
  running=$(f version) offered=""
  [ -n "$running" ] && [ -z "${ARR_ONLY:-}" ] && offered=$(api update 20 | grep -oE "\"version\": *\"[0-9.]+\"" | grep -oE "[0-9][0-9.]*" | tr "\n" ",")
  printf "%s|%s|%s|%s|%s|%s|%s|%s|\n" "$app" "$running" "$(f branch)" "$(f packageUpdateMechanism)" \
    "$(x UpdateAutomatically)" "$marker" "${offered%,}" "$started"
done
echo "#done"
'

# Append one CT's line to $results_file. Called from inside scan_ct and act_ct
# and reads their locals (bash scoping is dynamic), so the column order — which
# tally_results reads back — lives only here.
emit_result() {
  local failed="" skipped="" no_path="" prio=0
  if [[ "$ct_error" == true ]]; then
    failed="$ctid ($ct_hostname)${ct_fail_note:+: $ct_fail_note}"
    prio=${ct_fail_prio:-0}; (( prio > 0 )) || prio=4
  fi
  [[ -n "$ct_skipped" ]] && skipped="$ctid ($ct_hostname): $ct_skipped"
  [[ -n "$ct_no_path" ]] && no_path="$ctid ($ct_hostname): ${ct_no_path%, }"
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$ct_pkg" "$ct_community" \
    "$ct_docker_updated" "$ct_docker_pinned" "$ct_docker_unknown" \
    "$ct_app_found" "$ct_app_behind" "$ct_app_unknown" "$failed" "$skipped" "$no_path" \
    "$ct_todo" "$prio" >> "$results_file"
}

# What act_ct needs from scan_ct, written as 'declare' lines that act_ct sources
# back into its own locals. declare -p quotes every value itself, so whatever
# came out of the CT (/usr/bin/update, image names) comes back as data, never
# as code.
save_state() {
  declare -p ct_hostname pkg_manager extra_env ct_pkg ct_community ct_docker_pinned \
    ct_docker_unknown docker_local ct_app_found ct_app_behind ct_app_unknown ct_no_path ct_skipped \
    ct_todo has_update update_cmd cs_slug cs_ds guard_reason arr_apps arr_offered \
    arr_behind arr_by_cs compose_files docker_todo > "$state_file"
}

# =============================================================================
# PER-CONTAINER CHECK  (called in parallel — one subprocess per CT)
# =============================================================================
# Read-only: reports what each step would do and changes nothing. In apply
# mode it also saves its findings to $3 for act_ct, so the apply never asks the
# CT, the package mirrors or the registries the same questions again.
scan_ct() {
  local ctid="$1"
  local results_file="$2"
  local state_file="$3"
  local CT_START; CT_START=$(date +%s)
  local ct_pkg=0 ct_community=0 ct_docker_updated=0 ct_docker_pinned=0 ct_docker_unknown=0
  local ct_app_found=0 ct_app_behind=0 ct_app_unknown=0
  local ct_no_path=""   # *arr apps nothing updates without a manual click
  local ct_skipped=""   # reason, when a community script declined a precondition
  local ct_error=false
  local ct_hostname=""
  local ct_todo=0       # 1 when the apply has something to do here
  # Set by the steps below and handed to act_ct. Declared up front so an
  # --apt-only run, which stops after step 1, still saves all of them.
  local has_update=no update_cmd="" cs_slug="" guard_reason="" compose_files=""
  local cs_ds=""            # ZFS dataset of the root disk, for the apply's snapshot
  local docker_local=0      # locally built images: nothing to pull, never checked
  local -a docker_todo=()   # name|image of each container the apply pulls for
  local -A arr_offered=() arr_behind=() arr_by_cs=()
  local -a arr_apps=()

  # Verify the CT is running
  local status; status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
  if [[ "$status" != "running" ]]; then
    echo ""
    echo -e "${DIM}┌─[${NC}${CYAN}DECK ${ctid}${NC}${DIM}]─${NC} ${YELLOW}‖ NOT RUNNING — SKIPPED${NC}"
    emit_result
    return
  fi

  ct_hostname=$(pct config "$ctid" 2>/dev/null | awk '/^hostname/{print $2}')

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
  # is set. Don't probe for the 'homebridge' binary — it lives under the
  # package's private node runtime and hb-service isn't consistently on PATH.
  # Ask dpkg instead: the package is named 'homebridge', so a plain 'dpkg -s'
  # is an exact, cheap answer, and the flag gets set only where it applies.
  local extra_env=""
  if [[ "$pkg_manager" == "apt" ]]; then
    local has_homebridge; has_homebridge=$(pct exec "$ctid" -- sh -c 'dpkg -s homebridge >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)
    [[ "$has_homebridge" == "yes" ]] && extra_env="UPDATE_HOMEBRIDGE_FORCE=1"
  fi

  echo ""
  card_open "${CYAN}DECK ${ctid}" "${WHITE}${ct_hostname^^}" "${CYAN}${os:-unknown OS} · ${pkg_manager^^}"

  # =========================================================================
  # 1. OS PACKAGE UPGRADES
  # =========================================================================

  if [[ "$pkg_manager" == "apt" ]]; then
    echo -e "${C_PKG}$(ts) CHECKING FOR PACKAGE UPDATES"
    pct exec "$ctid" -- bash -c 'apt-get update -qq 2>&1' >/dev/null 2>&1

    local apt_upgrades; apt_upgrades=$(pct exec "$ctid" -- bash -c 'apt-get -s upgrade 2>/dev/null | grep "^Inst "' 2>/dev/null)
    local apt_count=0
    [[ -n "$apt_upgrades" ]] && apt_count=$(echo "$apt_upgrades" | grep -c "^Inst")

    if [[ "$apt_count" -gt 0 ]]; then
      ct_pkg=$((ct_pkg + apt_count))
      echo -e "${C_PKG}$(gauge "$apt_count")  ${YELLOW}${apt_count} PENDING${NC}"
      echo "$apt_upgrades" | while IFS= read -r line; do
        local pkg old new
        pkg=$(echo "$line" | awk '{print $2}')
        old=$(echo "$line" | awk -F'[][]' '{print $2}')
        new=$(echo "$line" | awk -F'[()]' '{print $2}' | awk '{print $1}')
        echo -e "${C_IND}${pkg}  ${old} ${CYAN}━▶${NC} ${GREEN}${new}${NC}"
      done
    else
      echo -e "${C_PKG}${GREEN}✔ UP TO DATE${NC}"
    fi

  elif [[ "$pkg_manager" == "apk" ]]; then
    echo -e "${C_PKG}$(ts) CHECKING FOR PACKAGE UPDATES"
    local apk_upgrades; apk_upgrades=$(pct exec "$ctid" -- sh -c 'apk update >/dev/null 2>&1; apk list -u 2>/dev/null' 2>/dev/null)
    local apk_count=0
    [[ -n "$apk_upgrades" ]] && apk_count=$(echo "$apk_upgrades" | grep -c '[a-z]')

    if [[ "$apk_count" -gt 0 ]]; then
      ct_pkg=$((ct_pkg + apk_count))
      echo -e "${C_PKG}$(gauge "$apk_count")  ${YELLOW}${apk_count} PENDING${NC}"
      local ind; ind=$(printf '%b' "$C_IND")
      echo "$apk_upgrades" | sed "s/^/${ind}/"
    else
      echo -e "${C_PKG}${GREEN}✔ UP TO DATE${NC}"
    fi

  else
    echo -e "${C_PKG}${YELLOW}⚠ UNKNOWN PACKAGE MANAGER${NC} — skipping OS updates"
  fi

  if [[ "$APT_ONLY" == true ]]; then
    finish_scan
    return
  fi

  # Read the community-script entrypoint up front: the app report below needs
  # to know which app it updates, not just that one exists. It names its
  # script as SCRIPT_SLUG (current format) or as .../ct/<slug>.sh (older).
  local has_update=no update_cmd="" cs_slug=""
  if update_cmd=$(pct exec "$ctid" -- cat /usr/bin/update 2>/dev/null); then
    has_update=yes
    cs_slug=$(printf '%s\n' "$update_cmd" | sed -n 's/^export SCRIPT_SLUG="\([A-Za-z0-9._-]*\)".*/\1/p' | head -n1)
    [[ -z "$cs_slug" ]] && cs_slug=$(printf '%s\n' "$update_cmd" | grep -oE '/ct/[A-Za-z0-9._-]+\.sh' | head -n1 | sed 's#.*/##; s/\.sh$//')
    # Renamed scripts keep their old slug in the CT: alpine-<app>, <app>-v4.
    cs_slug="${cs_slug,,}"; cs_slug="${cs_slug#alpine-}"
    [[ "$cs_slug" =~ ^(.+)-v[0-9]+$ ]] && cs_slug="${BASH_REMATCH[1]}"
  fi

  # =========================================================================
  # 2. *ARR APP VERSIONS  (report only — never updates anything itself)
  # =========================================================================
  # A self-updating app (or one moved by hand to a release the community
  # script doesn't track) would otherwise never show up here at all: only apt
  # and the community script's "found" line ever mention it (issue #4).
  #
  # The major-version guard for step 3 is decided here too, once per app, so
  # the report and the guard can't disagree. A community script deploys the
  # release IT tracks (Sonarr's is pinned to v4, and even an unpinned one
  # installs the latest stable, older than a pre-release major), and
  # /root/.<app> records what it last installed. If a newer major has run
  # since (moved by hand or by the app's own updater), the script would lay
  # the older major over a database already migrated forward, which can't be
  # undone. It fails closed when the version that ran can't be read: an
  # irreversible downgrade costs more than one deferred update. Without a
  # marker there is nothing to compare against, and holding the script back
  # would never clear (it is what writes the marker, and the Readarr and
  # Whisparr scripts never write one), so that only gets a warning.
  local -A arr_marker=() arr_offered=() arr_behind=() arr_by_cs=() arr_hold=() arr_hold_major=()
  local -a arr_apps=()
  local arr_info arr_probe_ok=false
  arr_info=$(pct exec "$ctid" -- sh -c "$ARR_PROBE" </dev/null 2>/dev/null)
  [[ "$arr_info" == *"#done"* ]] && arr_probe_ok=true
  arr_info=$(printf '%s\n' "$arr_info" | grep -v '^#')
  if [[ -n "$arr_info" ]]; then
    echo -e "${C_ARR}$(ts) CHECKING *ARR APP VERSIONS"
    while IFS='|' read -r a_app a_run a_branch a_mech a_auto a_marker a_offered a_started a_note; do
      [[ -z "$a_app" ]] && continue
      ct_app_found=$((ct_app_found + 1))
      arr_apps+=("$a_app")
      arr_marker[$a_app]="$a_marker"
      arr_offered[$a_app]="$a_offered"

      # Which apps the community script updates: the one it names, or, when
      # its entrypoint can't be read, every app it left a marker for.
      if [[ "$has_update" == "yes" ]] && { [[ "$cs_slug" == "$a_app" ]] || [[ -z "$cs_slug" && -n "$a_marker" ]]; }; then
        arr_by_cs[$a_app]=1
        local g_ver; g_ver=$(max_version "$a_run,$a_started")
        if [[ -z "$a_marker" ]]; then
          :   # nothing to compare: warned about in step 3
        elif [[ -z "$g_ver" ]]; then
          arr_hold[$a_app]="couldn't tell which ${a_app} version last ran (API down, no start in its log)"
        elif major_ahead "$g_ver" "$a_marker"; then
          arr_hold_major[$a_app]=1
          arr_hold[$a_app]="${a_app} has run ${g_ver}, a newer major than the community script's ${a_marker}"
        fi
      fi

      if [[ "$a_note" == "no curl" ]]; then
        ct_app_unknown=$((ct_app_unknown + 1))
        echo -e "${C_ARR}${WHITE}${a_app}${NC}   ${YELLOW}⚠ NOT CHECKED${NC} — curl isn't installed in this CT"
        continue
      elif [[ -z "$a_run" ]]; then
        ct_app_unknown=$((ct_app_unknown + 1))
        echo -e "${C_ARR}${WHITE}${a_app}${NC}   ${YELLOW}⚠ NOT CHECKED${NC} — its API didn't answer"
        continue
      fi
      local a_label="${WHITE}${a_app}${NC} ${a_run}${a_branch:+ (${a_branch})}"
      if [[ -z "$a_offered" ]]; then
        ct_app_unknown=$((ct_app_unknown + 1))
        echo -e "${C_ARR}${a_label}   ${YELLOW}⚠ NOT CHECKED${NC} — no update list (couldn't reach servarr.com?)"
      else
        local a_newest; a_newest=$(max_version "$a_run,$a_offered")
        if [[ "$a_newest" == "$a_run" ]]; then
          echo -e "${C_ARR}${a_label}   ${GREEN}✔ NEWEST BUILD${NC}"
        else
          ct_app_behind=$((ct_app_behind + 1))
          arr_behind[$a_app]=1
          echo -e "${C_ARR}${a_label} ${CYAN}━▶${NC} ${GREEN}${a_newest}${NC}   ${YELLOW}▲ BEHIND${NC}"
        fi
      fi
      # Which path, if any, keeps this app current. The *arr apps default to
      # the built-in updater, and on Linux UpdateAutomatically defaults to
      # off: the app then only OFFERS updates in its UI and installs nothing.
      if [[ "${a_mech,,}" == "builtin" || -z "$a_mech" ]]; then
        if [[ "${a_auto,,}" == "true" ]]; then
          echo -e "${C_IND}→ updates itself (built-in updater, automatic)"
        elif [[ -n "${arr_hold[$a_app]:-}" ]]; then
          echo -e "${C_IND}${RED}→ Nothing updates it — the community script is held back (below)${NC}"
        elif [[ -n "${arr_by_cs[$a_app]:-}" ]]; then
          echo -e "${C_IND}→ updated by the community script (--apply)"
        else
          ct_no_path+="${a_app}, "
          echo -e "${C_IND}${YELLOW}→ No automatic update path — turn on automatic updates in the app${NC}"
          echo -e "${C_IND}${YELLOW}  (Settings → General → Updates) or update it from System → Updates${NC}"
        fi
      else
        echo -e "${C_IND}→ updated by its package (update mechanism: ${a_mech})"
      fi
    done <<< "$arr_info"
  fi

  # =========================================================================
  # 3. COMMUNITY SCRIPT UPDATE
  # =========================================================================
  if [[ "$has_update" == "yes" ]]; then
    ct_community=$((ct_community + 1))
    echo -e "${C_CS}$(ts) UPDATE MECHANISM FOUND"

    # Apply the guard decided in step 2. Skipped as "needs action", like the
    # low-disk and OS refusals. Decided here in the check, and act_ct only runs
    # a script this left unguarded, so what the check reports is what happens.
    local guard_reason="" g_app=""
    if [[ "$arr_probe_ok" != true && -n "$cs_slug" && " $ARR_NAMES " == *" $cs_slug "* ]]; then
      # The script is for an *arr app, but the check above never ran (pct
      # exec failed), so nothing was compared. Fail closed.
      g_app="$cs_slug"
      guard_reason="couldn't check ${cs_slug} in this CT (the app check didn't run)"
    else
      if [[ -z "$cs_slug" && ${#arr_by_cs[@]} -gt 0 ]]; then
        echo -e "${C_CS}${YELLOW}⚠ TARGET UNKNOWN${NC} — couldn't tell which app /usr/bin/update is for; guarding ${!arr_by_cs[*]}"
      fi
      for g_app in "${arr_apps[@]}"; do
        guard_reason="${arr_hold[$g_app]:-}"
        [[ -n "$guard_reason" ]] && break
      done
      if [[ -z "$guard_reason" ]]; then
        for g_app in "${arr_apps[@]}"; do
          [[ -n "${arr_by_cs[$g_app]:-}" && -z "${arr_marker[$g_app]}" ]] || continue
          echo -e "${C_CS}${YELLOW}⚠ GUARD NOT APPLIED${NC} — ${g_app}: no /root/.${g_app} to compare against"
        done
      fi
    fi

    if [[ -n "$guard_reason" ]]; then
      ct_skipped="$guard_reason"
      local g_verb="skipped"; [[ "$MODE" != "apply" ]] && g_verb="would be skipped"
      echo -e "${C_CS}${RED}✖ WITHHELD${NC} — community script ${g_verb}: ${guard_reason}."
      if [[ -n "${arr_hold_major[$g_app]:-}" ]]; then
        echo -e "${C_IND}Running it could put the older major over a database that has already been"
        echo -e "${C_IND}migrated forward. Update ${g_app} with its own updater, and remove"
        echo -e "${C_IND}/usr/bin/update in CT ${ctid} if the script no longer applies."
      elif [[ "$arr_probe_ok" != true ]]; then
        echo -e "${C_IND}Re-run; if it keeps happening, check that 'pct exec ${ctid} -- sh' works."
      else
        echo -e "${C_IND}Without it a newer major can't be ruled out. Start ${g_app} and re-run."
      fi
    elif [[ "$MODE" == "apply" ]]; then
      echo -e "${C_CS}${YELLOW}▲ PENDING${NC} — community-script update runs in the apply step"
      # Where the apply's pre-update snapshot goes (read-only lookup; empty
      # when the root disk isn't a ZFS subvol, which the apply reports).
      cs_ds=$(ct_rootfs_dataset "$ctid") || cs_ds=""
    else
      echo -e "${C_CS}${YELLOW}▲ PENDING${NC} — run with --apply to execute community-script update"
    fi
  fi

  # =========================================================================
  # 4. DOCKER IMAGE UPDATES
  # =========================================================================
  local has_docker; has_docker=$(pct exec "$ctid" -- sh -c 'command -v docker >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)

  if [[ "$has_docker" == "yes" ]]; then
    echo -e "${C_DKR}$(ts) CHECKING DOCKER CONTAINERS"

    # The image ref each container was created from (.Config.Image), not
    # 'docker ps' {{.Image}}: once a container's tag has moved on to a newer
    # image (a manual pull, or a run whose recreate failed), ps shows a bare
    # image ID instead, which can't be pulled or compared, so the container
    # would stay on the old image for good.
    local docker_info; docker_info=$(pct exec "$ctid" -- sh -c '
      ids=$(docker ps -q) && [ -n "$ids" ] &&
        docker inspect --format "{{.Name}}|{{.Config.Image}}" $ids | sed "s#^/##"
    ' </dev/null 2>/dev/null)

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
          echo -e "${C_DKR}${YELLOW}⊘${NC} ${WHITE}${cname}${NC} — ${cimage}   ${YELLOW}PINNED VERSION${NC}"
          echo -e "${C_IND}${YELLOW}→ Update the tag in your compose file to upgrade${NC}"
          ct_docker_pinned=$((ct_docker_pinned + 1))
        else
          echo -e "${C_DKR}◆ ${WHITE}${cname}${NC} — ${cimage}"

          # The check must not pull, so ask the registry instead of the
          # daemon and compare digests. RepoDigests is the right local side:
          # it holds the digest of the manifest/index that was pulled for this
          # tag, and it means the same thing under both the classic and the
          # containerd image store. '.Id' does NOT — under containerd it is
          # the index digest, under the classic store the config digest — so
          # comparing '.Id' against a remote config digest silently reports
          # every image as stale on a containerd host (verified: Docker 29.x
          # with the containerd snapshotter). 'buildx imagetools inspect'
          # returns the index digest the tag resolves to right now, which is
          # exactly what RepoDigests can be compared against. Registry read
          # only: no layers are fetched and no container is touched.
          local local_digest remote_out remote_digest
          # Image refs come from container metadata, so pass the ref as a
          # positional arg rather than interpolating it into the sh -c string.
          # Every pct exec in this loop gets </dev/null: the loop reads the
          # container list on stdin, and a call that read it would swallow the
          # containers after this one.
          local_digest=$(pct exec "$ctid" -- sh -c \
            'docker image inspect --format "{{index .RepoDigests 0}}" "$1" 2>/dev/null' _ "$cimage" </dev/null 2>/dev/null)
          local_digest="${local_digest##*@}"
          if [[ -z "$local_digest" ]]; then
            # No RepoDigest at all: built locally, never pulled from a
            # registry, so there is nothing to compare or pull. Only the
            # classic store leaves it empty: the containerd store gives a
            # local build a digest of its own (verified: Docker 29.8), so
            # there the registry query below fails instead, and so does the
            # apply's pull, which is what keeps it from being recreated.
            ct_docker_unknown=$((ct_docker_unknown + 1))
            docker_local=$((docker_local + 1))
            echo -e "${C_IND}${YELLOW}⚠ NOT CHECKED${NC} — no registry digest (locally built image)"
            continue
          fi

          # The registry only says whether the TAG is current. The container
          # can still run an older image than the tag points at locally (a
          # manual pull, or a run whose recreate failed), and the apply only
          # recreates what this check queues. '.Image' on a container and
          # '.Id' on an image are the same kind of ID from the same local
          # store, so they compare cleanly under both the classic and the
          # containerd store.
          local running_id tag_id
          # shellcheck disable=SC2016  # "$1" is the inner sh's, as everywhere here
          running_id=$(pct exec "$ctid" -- sh -c \
            'docker inspect --format "{{.Image}}" "$1" 2>/dev/null' _ "$cname" </dev/null 2>/dev/null)
          tag_id=$(pct exec "$ctid" -- sh -c \
            'docker image inspect --format "{{.Id}}" "$1" 2>/dev/null' _ "$cimage" </dev/null 2>/dev/null)
          if [[ -n "$running_id" && -n "$tag_id" && "$running_id" != "$tag_id" ]]; then
            ct_docker_updated=$((ct_docker_updated + 1))
            docker_todo+=("${cname}|${cimage}")
            if [[ "$MODE" == "apply" ]]; then
              echo -e "${C_IND}${YELLOW}▲ PENDING${NC} — running an older image than ${cimage}; the apply step pulls the tag and recreates it if the pull succeeds"
            else
              echo -e "${C_IND}${YELLOW}▲ PENDING${NC} — running an older image than ${cimage}; run with --apply to recreate"
            fi
            continue
          fi

          # 2>&1: the error text is what tells a rate limit apart from a
          # genuine failure, and both are worth reporting differently.
          remote_out=$(pct exec "$ctid" -- sh -c \
            'docker buildx imagetools inspect --format "{{.Manifest.Digest}}" "$1" 2>&1' _ "$cimage" </dev/null 2>/dev/null)
          # Anchored, so a digest quoted inside an error message can never be
          # mistaken for a successful answer.
          remote_digest=$(printf '%s\n' "$remote_out" | grep -oE '^sha256:[0-9a-f]{64}$' | head -n1)

          if [[ -n "$remote_digest" ]]; then
            if [[ "$local_digest" == "$remote_digest" ]]; then
              echo -e "${C_IND}${GREEN}✔ UP TO DATE${NC}"
            else
              ct_docker_updated=$((ct_docker_updated + 1))
              docker_todo+=("${cname}|${cimage}")
              if [[ "$MODE" == "apply" ]]; then
                echo -e "${C_IND}${YELLOW}▲ UPDATE AVAILABLE${NC} — pulled & recreated in the apply step"
              else
                echo -e "${C_IND}${YELLOW}▲ UPDATE AVAILABLE${NC} — run with --apply to pull & recreate"
              fi
            fi
          else
            # Never guess: count it as unchecked so the summary can say the
            # count is incomplete instead of implying everything is current.
            # The apply still tries a pull: that answers the same question,
            # and recreates only if it brought a new image.
            ct_docker_unknown=$((ct_docker_unknown + 1))
            docker_todo+=("${cname}|${cimage}")
            local retry="retry later"
            [[ "$MODE" == "apply" ]] && retry="the apply step tries a pull"
            if [[ "$remote_out" == *"429"* || "$remote_out" == *"oo many requests"* ]]; then
              # Docker Hub's anonymous cap, which a multi-CT sweep really does
              # trip. Transient, and 'docker login' inside the CT raises it.
              echo -e "${C_IND}${YELLOW}⚠ NOT CHECKED${NC} — Docker Hub rate limit (429); ${retry}"
            else
              echo -e "${C_IND}${YELLOW}⚠ NOT CHECKED${NC} — could not query the registry"
            fi
          fi
        fi
      done <<< "$docker_info"
    fi
  fi

  finish_scan
}

# The end of every scan_ct that got as far as checking: decide whether the
# apply has anything to do here, report, and save the state for act_ct. A
# community script always counts: only running it tells whether it had work.
finish_scan() {
  if [[ "$ct_pkg" -gt 0 || ${#docker_todo[@]} -gt 0 ]] \
     || [[ "$has_update" == "yes" && -z "$guard_reason" ]]; then
    ct_todo=1
  fi
  card_close $(( $(date +%s) - CT_START ))
  emit_result
  [[ "$MODE" == "apply" ]] && save_state
}

# =============================================================================
# PER-CONTAINER APPLY  (called in parallel, after the check and the prompt)
# =============================================================================
# Acts only on what scan_ct found and saved to $3: no package-list refresh, no
# registry query, and no app check except the one after a community script.
# A CT with nothing to do prints nothing.
act_ct() {
  local ctid="$1"
  local results_file="$2"
  local state_file="$3"
  # No state: the CT wasn't running when it was checked.
  [[ -f "$state_file" ]] || return 0
  local CT_START; CT_START=$(date +%s)
  # shellcheck source=/dev/null
  source "$state_file"
  # The check's Docker counts said what a pull would change; from the hook on,
  # these say what did. Until then ct_docker_unknown keeps the check's count,
  # which is what a CT that does nothing (or is deferred) reports.
  local ct_error=false ct_docker_updated=0
  local ct_fail_note="" ct_fail_prio=0   # set when a failed community script was recovered (or not)
  if [[ "$ct_todo" != 1 ]]; then
    emit_result
    return
  fi

  echo ""
  card_open "${CYAN}DECK ${ctid}" "${WHITE}${ct_hostname^^}" "${YELLOW}EXECUTE"
  # Prefix for command output streamed into the card.
  local ind; ind=$(printf '%b' "$C_IND")

  # Optional per-CT busy guard. Some workloads can't be restarted at any moment
  # (a live session, a long job), and a -y run has no one to ask. If
  # the host has an executable /etc/pve-updater/hooks/<ctid>, it runs right
  # before the apply touches this CT (so after the prompt, and only when there
  # is something to do) with the CT ID as $1, and a non-zero exit (or no answer
  # within 60s) defers the whole CT to the next run, untouched. A check never
  # runs it. No hook file means no change in behavior.
  local hook="${PVE_UPDATE_HOOK_DIR}/${ctid}"
  if [[ -x "$hook" ]]; then
    local hook_out hook_exit
    hook_out=$(timeout 60 "$hook" "$ctid" </dev/null 2>&1)
    hook_exit=$?
    if [[ $hook_exit -ne 0 ]]; then
      local why="exit $hook_exit"
      [[ $hook_exit -eq 124 ]] && why="timed out after 60s"
      echo -e "${C_HOOK}${YELLOW}‖ DEFERRED${NC} — by ${hook} (${why}); nothing changed in this CT"
      [[ -n "$hook_out" ]] && printf '%s\n' "$hook_out" | tail -n 5 | sed "s/^/${ind}/"
      # Keep a guard hold from the check: it still needs action after this.
      ct_skipped="${ct_skipped:+$ct_skipped; }deferred by hook ($why)"
      ct_pkg=0 ct_community=0
      card_close $(( $(date +%s) - CT_START ))
      emit_result
      return
    fi
    [[ -n "$hook_out" ]] && printf '%s\n' "$hook_out" | tail -n 5 | sed "s/^/$(printf '%b' "$C_HOOK")/"
  fi

  # Someone may have stopped the CT while the prompt waited. Leave it as they
  # left it: no upgrade, no snapshot, and no rollback that would start it.
  if [[ "$(pct status "$ctid" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    echo -e "${C_SYS}${YELLOW}‖ STOPPED SINCE SCAN${NC} — not touched"
    ct_skipped="${ct_skipped:+$ct_skipped; }stopped since the check"
    ct_pkg=0 ct_community=0
    card_close $(( $(date +%s) - CT_START ))
    emit_result
    return
  fi
  ct_docker_unknown=$docker_local

  # =========================================================================
  # 1. OS PACKAGE UPGRADES
  # =========================================================================
  # The package lists are the ones the check just refreshed, so this installs
  # the set it listed.
  if [[ "$ct_pkg" -gt 0 && "$pkg_manager" == "apt" ]]; then
    echo -e "${C_PKG}$(ts) APPLYING UPGRADES"
    local apt_output apt_exit
    apt_output=$(pct exec "$ctid" -- bash -c "DEBIAN_FRONTEND=noninteractive${extra_env:+ $extra_env} apt-get upgrade -y 2>&1")
    apt_exit=$?
    echo "$apt_output" | grep -E '^(Unpacking|Setting up|Errors|E:|Processing|Need to)' | sed "s/^/${ind}/"
    if [[ $apt_exit -eq 0 ]]; then
      echo -e "${C_PKG}${GREEN}✔ APPLIED — apt upgrades${NC}"
    else
      echo -e "${C_PKG}${RED}✖ FAULT — apt upgrade failed (exit $apt_exit)${NC}"
      ct_error=true
      add_fail_note "apt upgrade failed (exit $apt_exit)"
    fi
  elif [[ "$ct_pkg" -gt 0 && "$pkg_manager" == "apk" ]]; then
    echo -e "${C_PKG}$(ts) APPLYING UPGRADES"
    pct exec "$ctid" -- sh -c 'apk upgrade --no-cache 2>&1' | sed "s/^/${ind}/"
    local apk_exit=${PIPESTATUS[0]}
    if [[ $apk_exit -eq 0 ]]; then
      echo -e "${C_PKG}${GREEN}✔ APPLIED — apk upgrades${NC}"
    else
      echo -e "${C_PKG}${RED}✖ FAULT — apk upgrade failed (exit $apk_exit)${NC}"
      ct_error=true
      add_fail_note "apk upgrade failed (exit $apk_exit)"
    fi
  fi

  # =========================================================================
  # 3. COMMUNITY SCRIPT UPDATE  (not when the guard held it back)
  # =========================================================================
  if [[ "$has_update" == "yes" && -z "$guard_reason" ]]; then
    local g_app
    # Roll-back point. A community script stops the app, replaces its files
    # and bumps /root/.<app> before it builds, so a failure part-way leaves
    # the app down, and every later run then sees "no update available". An
    # instant ZFS snapshot of the rootfs lets a failure go back to exactly
    # what was running (cs_recover). Root disk only, see ct_rootfs_dataset;
    # the check found the dataset. What runs is read here, not in the check:
    # it has to be what was running the moment before the script, after the
    # package upgrade above.
    local cs_snap="" cs_failed=false cs_t0 cs_before cs_old
    cs_t0=$(date +%s)
    cs_before=$(ct_running_services "$ctid")
    if [[ -n "$cs_ds" ]]; then
      cs_old=$(zfs list -H -t snapshot -o name -d 1 "$cs_ds" 2>/dev/null | grep '@pve-update-' | paste -sd' ' -)
      [[ -n "$cs_old" ]] && echo -e "${C_SNAP}${YELLOW}⚠ LEFT OVER${NC} — snapshot(s) from an earlier run: ${cs_old}"
      if zfs snapshot "${cs_ds}@pve-update-${RUN_ID}" 2>/dev/null; then
        cs_snap="${cs_ds}@pve-update-${RUN_ID}"
        echo -e "${C_SNAP}$(ts) TAKEN ${cs_snap} (rolled back if the update fails)"
      else
        echo -e "${C_SNAP}${YELLOW}⚠ NO SNAPSHOT${NC} — couldn't snapshot ${cs_ds}, so a failed update can't be rolled back"
      fi
    else
      echo -e "${C_SNAP}${YELLOW}⚠ NO SNAPSHOT${NC} — root disk is not on ZFS, so a failed update can't be rolled back"
    fi
    echo -e "${C_CS}$(ts) RUNNING UPDATE"
    # Write the script to a temp file to avoid shell expansion of its content,
    # then pipe 'yes' to auto-answer interactive prompts (read -p, etc.).
    local _tmp="/tmp/.pve_update_$$_${ctid}"
    printf '%s\n' "$update_cmd" | pct exec "$ctid" -- bash -c "cat > $_tmp"
    # CI=true / NPM_CONFIG_YES tell Node package managers (pnpm/npm) they're
    # non-interactive, so they skip TTY-gated prompts that 'yes |' can't answer.
    # tee streams the output live AND keeps a copy so we can replay the tail on
    # failure (sed -u indents it into the card as it streams). Real pipeline
    # (not $( )), so PIPESTATUS[1] is the timeout/pct exit.
    # 300s, not 120s: community scripts that rebuild a Node/Next.js app
    # (homepage runs pnpm install + pnpm build) routinely need 2-5 minutes in a
    # constrained LXC. A timeout kill surfaces as exit 124 in the failure tail.
    local _clog="/tmp/.pve_clog_$$_${ctid}"
    yes 2>/dev/null | timeout 300 pct exec "$ctid" -- bash -c "
      export DEBIAN_FRONTEND=noninteractive
      export TERM=xterm
      export CI=true
      export NPM_CONFIG_YES=true
      # The community-scripts engine runs under 'set -u' and reads HOME when
      # it installs per-tool runtimes (uv, deno, pnpm). A non-login 'pct exec'
      # shell never sets HOME, so without this the update aborts with 'HOME:
      # unbound variable' -- sometimes after the script has already stopped
      # the app's service, leaving it down until the next run. These scripts
      # run as root inside the CT.
      export HOME=/root
      ${extra_env:+export $extra_env; }
      bash $_tmp
    " 2>&1 | tee "$_clog" | sed -u "s/^/${ind}/"
    local community_exit=${PIPESTATUS[1]}
    pct exec "$ctid" -- rm -f "$_tmp" 2>/dev/null || true
    if [[ $community_exit -eq 0 ]]; then
      echo -e "${C_CS}${GREEN}✔ COMPLETE — community script update${NC}"
      # The check read the app versions before this ran. Ask again for the
      # apps it updates that were behind, so the summary isn't stale. The
      # script has just restarted the app, and a .NET app takes a while to
      # answer again: retry until a minute has passed. Compared against the
      # update list fetched above, so each try is one local status call.
      local -a a_left=()
      for g_app in "${arr_apps[@]}"; do
        [[ -n "${arr_behind[$g_app]:-}" && -n "${arr_by_cs[$g_app]:-}" ]] && a_left+=("$g_app")
      done
      local a_name a_now a_newest a_deadline=$((SECONDS + 60))
      local -A a_seen=()
      while [[ ${#a_left[@]} -gt 0 ]]; do
        a_seen=()
        while IFS='|' read -r a_name a_now _; do
          [[ -n "$a_now" && " ${a_left[*]} " == *" $a_name "* ]] || continue
          a_seen[$a_name]=1
          a_newest=$(max_version "$a_now,${arr_offered[$a_name]}")
          if [[ "$a_newest" == "$a_now" ]]; then
            ct_app_behind=$((ct_app_behind - 1))
            echo -e "${C_ARR}${WHITE}${a_name}${NC} now on ${a_now}   ${GREEN}✔ NEWEST BUILD${NC}"
          else
            echo -e "${C_ARR}${WHITE}${a_name}${NC} still on ${a_now} ${CYAN}━▶${NC} ${GREEN}${a_newest}${NC}   ${YELLOW}▲ BEHIND${NC}"
          fi
        done < <(pct exec "$ctid" -- env ARR_ONLY="${a_left[*]}" sh -c "$ARR_PROBE" </dev/null 2>/dev/null)
        local -a a_next=()
        for a_name in "${a_left[@]}"; do [[ -n "${a_seen[$a_name]:-}" ]] || a_next+=("$a_name"); done
        a_left=("${a_next[@]}")
        [[ ${#a_left[@]} -gt 0 && $SECONDS -lt $a_deadline ]] || break
        sleep 5
      done
      for a_name in "${a_left[@]}"; do
        echo -e "${C_ARR}${WHITE}${a_name}${NC}   ${YELLOW}⚠ NOT RE-CHECKED${NC} — didn't answer within a minute of the update"
      done
    elif grep -qiE 'storage too low|dangerously low|too low in unattended|low disk' "$_clog" 2>/dev/null; then
      # The community script aborted itself as a precondition (not enough free
      # disk), which is safe/correct — treat it as a skip, not a failure, so it
      # doesn't clutter the "Failed CTs" line. Free up space and re-run.
      ct_skipped="low disk space"
      echo -e "${C_CS}${RED}✖ WITHHELD${NC} — community script skipped: low disk space in this container."
      echo -e "${C_IND}Free space (e.g. 'pct resize ${ctid} rootfs +2G') and re-run."
    elif grep -qiE 'does not match the recommended|skipping update' "$_clog" 2>/dev/null; then
      # Same class as low disk: the community script refuses to run because the
      # container OS is older than the version it targets. Deliberately NOT
      # bypassed automatically — unlike UPDATE_HOMEBRIDGE_FORCE, which clears a
      # guard that misfires on us, this one is correct: the OS really is old,
      # and the project says bypassing may break the app with no support. That
      # is the operator's call, so surface it and let them decide.
      local _osmsg; _osmsg=$(grep -iE 'does not match the recommended' "$_clog" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//')
      ct_skipped="OS version mismatch"
      echo -e "${C_CS}${RED}✖ WITHHELD${NC} — community script skipped: container OS is older than it expects."
      [[ -n "$_osmsg" ]] && echo -e "${C_IND}${_osmsg}"
      echo -e "${C_IND}Upgrade the container OS, or opt in to the project's documented"
      echo -e "${C_IND}bypass inside CT ${ctid} (unsupported — may break the app)."
    else
      echo -e "${C_CS}${RED}✖ FAULT — community script failed (exit $community_exit); last output:${NC}"
      tail -20 "$_clog" 2>/dev/null | sed "s/^/${ind}/"
      ct_error=true
      cs_failed=true
      cs_recover
    fi
    # Success, or a script that declined before changing anything: the
    # snapshot has done its job. cs_recover keeps it if a rollback failed.
    [[ -n "$cs_snap" && "$cs_failed" != true ]] && zfs destroy "$cs_snap" 2>/dev/null
    rm -f "$_clog" 2>/dev/null || true
  fi

  # =========================================================================
  # 4. DOCKER IMAGE UPDATES  (only the containers the check queued)
  # =========================================================================
  local item cname cimage pulled=0
  for item in "${docker_todo[@]}"; do
    cname="${item%%|*}" cimage="${item#*|}"
    echo -e "${C_DKR}◆ ${WHITE}${cname}${NC} — ${cimage}"
    # Recreating restarts whatever the container is doing, so only do it
    # when the container really runs an older image than its tag now
    # points at. That is decided from image IDs, never from the text
    # 'docker pull' prints: a pull that FAILS prints no "Image is up to
    # date", and reading that silence as "new image" force-recreated
    # locally built containers on every run (issue #3). Refs are passed
    # as positional args, as in the check, and </dev/null keeps pct exec
    # from reading stdin.
    echo -e "${C_DKR}$(ts) PULLING ${cimage}"
    local pull_output pull_exit
    pull_output=$(pct exec "$ctid" -- sh -c 'docker pull "$1" 2>&1' _ "$cimage" </dev/null 2>&1)
    pull_exit=$?
    if [[ $pull_exit -ne 0 ]]; then
      # Nothing new arrived, so there is nothing to recreate. Not
      # checked, like a registry the check couldn't reach.
      ct_docker_unknown=$((ct_docker_unknown + 1))
      if [[ "$pull_output" == *"429"* || "$pull_output" == *"oo many requests"* ]]; then
        echo -e "${C_IND}${YELLOW}⚠ NOT PULLED${NC} — Docker Hub rate limit (429); retry later"
      else
        local pull_err
        pull_err=$(printf '%s\n' "$pull_output" | grep -iE 'error|denied|not found|unauthorized' | head -n1)
        [[ -z "$pull_err" ]] && pull_err=$(printf '%s\n' "$pull_output" | grep -v '^[[:space:]]*$' | tail -n1)
        local pull_hint=""
        [[ "$pull_output" == *"repository does not exist"* ]] && pull_hint=" (locally built image?)"
        echo -e "${C_IND}${YELLOW}⚠ NOT PULLED${NC}${pull_hint} — pull failed (exit ${pull_exit}): ${pull_err}"
      fi
      continue
    fi
    pulled=$((pulled + 1))
    echo "$pull_output" | grep -E '^(Digest|Status)' | sed "s/^/${ind}/"

    # '.Image' on a container and '.Id' on an image are the same kind of
    # ID from the same local store, so they compare cleanly under both
    # the classic and the containerd store (unlike '.Id' vs a REMOTE
    # digest — see scan_ct). It also catches a second container on
    # the same tag, whose own pull finds nothing new because the first
    # container's pull already fetched it.
    local running_id tag_id
    running_id=$(pct exec "$ctid" -- sh -c \
      'docker inspect --format "{{.Image}}" "$1" 2>/dev/null' _ "$cname" </dev/null 2>/dev/null)
    tag_id=$(pct exec "$ctid" -- sh -c \
      'docker image inspect --format "{{.Id}}" "$1" 2>/dev/null' _ "$cimage" </dev/null 2>/dev/null)
    if [[ -z "$running_id" || -z "$tag_id" ]]; then
      ct_docker_unknown=$((ct_docker_unknown + 1))
      echo -e "${C_IND}${YELLOW}⚠ NOT CHECKED${NC} — could not read the container's or the tag's image ID"
      continue
    fi
    if [[ "$running_id" == "$tag_id" ]]; then
      echo -e "${C_IND}${GREEN}✔ UP TO DATE${NC}"
      continue
    fi

    echo -e "${C_IND}${GREEN}✔ NEW IMAGE${NC} — ${cimage}"
    ct_docker_updated=$((ct_docker_updated + 1))

    # Recreate just this container's service. A bare 'up -d' would also
    # start stopped services and recreate any drifted one in the same
    # file, and --force-recreate restarted every service in it.
    local svc recreated=false
    svc=$(pct exec "$ctid" -- sh -c \
      'docker inspect --format "{{index .Config.Labels \"com.docker.compose.service\"}}" "$1" 2>/dev/null' \
      _ "$cname" </dev/null 2>/dev/null)
    if [[ -n "$svc" ]]; then
      while IFS= read -r cf; do
        [[ -z "$cf" ]] && continue
        local managed; managed=$(pct exec "$ctid" -- sh -c \
          'docker compose -f "$1" ps --format "{{.Names}}" 2>/dev/null | grep -qxF "$2" && echo yes || echo no' \
          _ "$cf" "$cname" </dev/null 2>/dev/null)

        if [[ "$managed" == "yes" ]]; then
          recreated=true
          echo -e "${C_DKR}$(ts) RECREATING ${svc} via ${cf}"
          pct exec "$ctid" -- sh -c 'docker compose -f "$1" up -d --no-deps "$2" 2>&1' \
            _ "$cf" "$svc" </dev/null | sed "s/^/${ind}/"
          local up_exit=${PIPESTATUS[0]}
          if [[ $up_exit -eq 0 ]]; then
            echo -e "${C_IND}${GREEN}✔ RECREATED${NC}"
          else
            echo -e "${C_IND}${RED}✖ FAULT — recreate failed (exit ${up_exit}); ${cname} is still on the old image${NC}"
            ct_error=true
            add_fail_note "docker recreate of ${cname} failed (exit ${up_exit})"
          fi
          break
        fi
      done <<< "$compose_files"
    fi
    if [[ "$recreated" != true ]]; then
      echo -e "${C_IND}${YELLOW}⚠ NOT RECREATED${NC} — no compose file found for ${cname}; new image pulled, recreate the container yourself"
    fi
  done

  # Clean up the images the recreates left unused (timeout after 30s to
  # avoid hangs). Nothing was pulled, nothing new to clean up.
  if [[ $pulled -gt 0 ]]; then
    echo -e "${C_DKR}PRUNING UNUSED IMAGES"
    timeout 30 pct exec "$ctid" -- docker image prune -f >/dev/null 2>&1 || \
      echo -e "${C_DKR}${YELLOW}⚠ PRUNE TIMED OUT OR FAILED${NC} (non-critical)"
  fi

  card_close $(( $(date +%s) - CT_START ))
  emit_result
}

# =============================================================================
# 1-4. RUN CONTAINERS IN PARALLEL
# =============================================================================
# Runs $1 (scan_ct, or act_ct after the prompt) for every CT at once, one
# subprocess each, then tallies their results. $RUN_DIR/<ctid>.state carries
# each CT's findings from the check over to the apply.
run_phase() {
  local phase="$1" results="$RUN_DIR/$1.results"
  : > "$results"
  local -A pid_ctid=()
  local -a pending=() still=()
  _PHASE_OUT=()
  local ctid pid outfile
  for ctid in "${CTS[@]}"; do
    outfile="$RUN_DIR/$phase.$ctid.out"
    # </dev/null: pct exec reads stdin, and the confirm prompt needs the
    # terminal's for itself.
    "$phase" "$ctid" "$results" "$RUN_DIR/$ctid.state" > "$outfile" 2>&1 </dev/null &
    pid=$!
    _PHASE_OUT[$pid]="$outfile"
    pid_ctid[$pid]="$ctid"
    pending+=("$pid")
  done

  # Print each CT's block as soon as that CT finishes, rather than in submission
  # order — otherwise one slow CT (a multi-minute community-script rebuild)
  # hides every other CT's finished output, which over SSH looks like a hang.
  # Polled with kill -0 rather than 'wait -n -p' (bash 5.1+) for portability,
  # and so each tick can redraw the live status line on a terminal.
  # The spinner is an array, not a string to slice: under a C locale a slice
  # would cut a multibyte character in half.
  local total=${#pending[@]} wait_start el line cols label=SCAN
  local -a spin=(◴ ◷ ◶ ◵)
  [[ "$phase" == act_ct ]] && label=EXECUTE
  wait_start=$(date +%s)
  while [[ ${#pending[@]} -gt 0 ]]; do
    still=()
    for pid in "${pending[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still+=("$pid")
      else
        wait "$pid" 2>/dev/null
        _clear_status
        cat "${_PHASE_OUT[$pid]}"
        rm -f "${_PHASE_OUT[$pid]}"
        unset '_PHASE_OUT[$pid]'
      fi
    done
    pending=("${still[@]}")
    [[ ${#pending[@]} -eq 0 ]] && break

    if [[ "$_live_status" == true ]]; then
      el=$(( $(date +%s) - wait_start ))
      line="${spin[el % 4]} ${label} $(( total - ${#pending[@]} ))/${total} · $(( el / 60 ))m$(printf '%02d' $(( el % 60 )))s · AWAITING DECK"
      for pid in "${pending[@]}"; do line+=" ${pid_ctid[$pid]}"; done
      # Truncate to the terminal width: a wrapped line breaks the \r redraw.
      # Colour goes on after, so it never counts toward the width.
      cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}'); [[ "$cols" =~ ^[0-9]+$ && $cols -gt 10 ]] || cols=80
      [[ ${#line} -ge $cols ]] && line="${line:0:$(( cols - 3 ))}…"
      printf '\r\033[K%b%s%b' "$CYAN" "$line" "$NC"
    fi
    sleep 1
  done
  _clear_status

  tally_results "$results"
}

# Sum the per-CT lines in $1 into the global counters (host packages
# included), replacing whatever the previous phase left there.
tally_results() {
  TOTAL_PKG=$HOST_PKG TOTAL_COMMUNITY=0
  TOTAL_DOCKER_UPDATED=0 TOTAL_DOCKER_PINNED=0 TOTAL_DOCKER_UNKNOWN=0
  TOTAL_APP_FOUND=0 TOTAL_APP_BEHIND=0 TOTAL_APP_UNKNOWN=0 TOTAL_TODO_CTS=0
  FAILED_CTS=() SKIPPED_CTS=() NO_PATH_APPS=() FAIL_PRIO=0
  local r_pkg r_comm r_dock_upd r_dock_pin r_dock_unk r_app_found r_app_behind r_app_unk r_failed r_skipped r_no_path r_todo r_prio
  while IFS='|' read -r r_pkg r_comm r_dock_upd r_dock_pin r_dock_unk r_app_found r_app_behind r_app_unk r_failed r_skipped r_no_path r_todo r_prio; do
    TOTAL_PKG=$((TOTAL_PKG + r_pkg))
    TOTAL_COMMUNITY=$((TOTAL_COMMUNITY + r_comm))
    TOTAL_DOCKER_UPDATED=$((TOTAL_DOCKER_UPDATED + r_dock_upd))
    TOTAL_DOCKER_PINNED=$((TOTAL_DOCKER_PINNED + r_dock_pin))
    TOTAL_DOCKER_UNKNOWN=$((TOTAL_DOCKER_UNKNOWN + r_dock_unk))
    TOTAL_APP_FOUND=$((TOTAL_APP_FOUND + r_app_found))
    TOTAL_APP_BEHIND=$((TOTAL_APP_BEHIND + r_app_behind))
    TOTAL_APP_UNKNOWN=$((TOTAL_APP_UNKNOWN + r_app_unk))
    TOTAL_TODO_CTS=$((TOTAL_TODO_CTS + r_todo))
    [[ -n "$r_failed" ]] && FAILED_CTS+=("$r_failed")
    (( ${r_prio:-0} > FAIL_PRIO )) && FAIL_PRIO=$r_prio
    [[ -n "$r_skipped" ]] && SKIPPED_CTS+=("$r_skipped")
    [[ -n "$r_no_path" ]] && NO_PATH_APPS+=("$r_no_path")
  done < <(cat "$1" 2>/dev/null)   # none yet: interrupted before any apply job
}

# One ntfy push per apply run, and only when something failed: P5 when a CT
# may still be down (a rollback that didn't bring it back, or a snapshot
# kept), P4 for a failure that was recovered or left nothing down. Skips and
# holds are listed on the board and don't push. A clean run sends nothing.
# Sets NTFY_NOTE for the board.
send_failure_push() {
  [[ -n "${PVE_UPDATE_NTFY:-}" ]] || return 0
  [[ "$HOST_FAILED" == true || ${#FAILED_CTS[@]} -gt 0 ]] || return 0
  local prio=$FAIL_PRIO body="" nfail=${#FAILED_CTS[@]} title tags f
  if [[ "$HOST_FAILED" == true ]]; then
    body+="PVE host: dist-upgrade failed"$'\n'; nfail=$((nfail + 1)); (( prio < 4 )) && prio=4
  fi
  for f in "${FAILED_CTS[@]}"; do body+="FAILED ${f}"$'\n'; done
  title="pve-update on $(hostname -s 2>/dev/null || echo pve): ${nfail} failed"
  tags="warning"; (( prio >= 5 )) && tags="rotating_light"
  if ntfy_push "$prio" "$title" "$tags" "${body%$'\n'}"; then
    NTFY_NOTE="${GREEN}✔ SENT${NC} (P${prio})"
  else
    NTFY_NOTE="${RED}✖ PUSH FAILED${NC} (P${prio}) — check PVE_UPDATE_NTFY in ${PVE_UPDATE_CONFIG}"
  fi
}

# =============================================================================
# SUMMARY
# =============================================================================
# $1 is "pending" for the one between the check and the apply; it then counts
# what the apply would do. Otherwise it counts what this run did ("interrupted"
# when the apply step was cut short, see _on_signal).
print_summary() {
  TOTAL_ELAPSED=$(( $(date +%s) - SCRIPT_START ))
  local title="CHECK"
  if [[ "$1" == "pending" ]]; then
    title="SCAN"
  elif [[ "$1" == "interrupted" ]]; then
    title="AFTER ACTION — ${RED}INTERRUPTED${CYAN}"
  elif [[ "$MODE" == "apply" ]]; then
    title="AFTER ACTION"
  fi
  # Counters: a number that needs you is red; the rest are just facts.
  local hold=${#SKIPPED_CTS[@]} fault=${#FAILED_CTS[@]}
  [[ "$HOST_FAILED" == true ]] && fault=$((fault + 1))
  local hold_c="$WHITE" fault_c="$WHITE"
  (( hold > 0 )) && hold_c="$RED"
  (( fault > 0 )) && fault_c="$RED"
  local sep="  ${DIM}│${NC}  "
  local row=" ${CYAN}PKG${NC} ${WHITE}${TOTAL_PKG}${NC}${sep}${CYAN}IMG${NC} ${WHITE}${TOTAL_DOCKER_UPDATED}${NC}"
  row+="${sep}${CYAN}PIN${NC} ${WHITE}${TOTAL_DOCKER_PINNED}${NC}${sep}${CYAN}HOLD${NC} ${hold_c}${hold}${NC}"
  row+="${sep}${CYAN}FAULT${NC} ${fault_c}${fault}${NC}"
  # An image the registry wouldn't answer for is neither "up to date" nor "has
  # an update" — say so rather than let IMG 0 read as all-clear.
  if [[ "$TOTAL_DOCKER_UNKNOWN" -gt 0 ]]; then
    row+="${sep}${YELLOW}UNCHECKED ${TOTAL_DOCKER_UNKNOWN}${NC}"
  fi
  # *arr apps are reported, never updated here (their own updater or the
  # community script does that), so the same wording fits both modes. Only on
  # hosts that run any: elsewhere a permanent "0" would just be noise.
  if [[ "$TOTAL_APP_FOUND" -gt 0 ]]; then
    row+="${sep}${CYAN}ARR BEHIND${NC} ${WHITE}${TOTAL_APP_BEHIND}${NC}"
    if [[ "$TOTAL_APP_UNKNOWN" -gt 0 ]]; then
      row+="${sep}${YELLOW}ARR UNCHECKED ${TOTAL_APP_UNKNOWN}${NC}"
    fi
  fi

  echo ""
  local head="${DIM}━━${NC} ${WHITE}STATUS BOARD${NC} ${CYAN}// ${title}${NC} "
  echo -e "${head}${DIM}$(rep_char ━ $(( CARD_W - $(vis_len "$head") )))${NC}"
  echo -e "$row"
  # Until the apply has run, IMG counts what a pull WOULD change; after it,
  # what a pull did.
  local img_note="images with updates"
  [[ "$MODE" == "apply" && "$1" != "pending" ]] && img_note="images updated"
  echo -e " ${DIM}IMG = ${img_note} · PIN = pinned (manual bump) · HOLD = skipped · FAULT = failed${NC}"
  echo -e " ${CYAN}UNITS${NC} ${#CTS[@]} scanned · ${CYAN}CS${NC} ${TOTAL_COMMUNITY} community-script CTs · ${CYAN}PVE HOST${NC} $([[ "$INCLUDE_HOST" == true ]] && echo included || echo skipped) · ${CYAN}ELAPSED${NC} ${TOTAL_ELAPSED}s"
  [[ "$TOTAL_DOCKER_UNKNOWN" -gt 0 || "$TOTAL_APP_UNKNOWN" -gt 0 ]] && \
    echo -e " ${DIM}UNCHECKED: see the per-container detail above${NC}"

  if [[ "$HOST_FAILED" == true ]]; then
    echo ""
    echo -e " ${RED}✖ HOST FAULT${NC}      dist-upgrade failed on the PVE host"
  fi

  if [[ ${#FAILED_CTS[@]} -gt 0 ]]; then
    echo ""
    echo -e " ${CYAN}FAILED CTS${NC}"
    for _s in "${FAILED_CTS[@]}"; do
      echo -e "   ${RED}✖${NC} ${_s}"
    done
  fi

  # Skips are preconditions the community script declined (low disk, OS mismatch)
  # or that the major-version guard refused — not failures, but list them so
  # they don't silently look like successes.
  if [[ ${#SKIPPED_CTS[@]} -gt 0 ]]; then
    echo ""
    echo -e " ${CYAN}SKIPPED — NEEDS ACTION${NC}"
    for _s in "${SKIPPED_CTS[@]}"; do
      echo -e "   ${RED}✖${NC} ${_s}"
    done
  fi

  # Nothing fails here, so nothing else would ever say it: these apps only move
  # when someone clicks Update in their UI.
  if [[ ${#NO_PATH_APPS[@]} -gt 0 ]]; then
    echo ""
    echo -e " ${CYAN}NO AUTOMATIC APP UPDATES${NC}"
    for _s in "${NO_PATH_APPS[@]}"; do
      echo -e "   ${YELLOW}⚠${NC} ${_s}"
    done
  fi

  if [[ "$HOST_REBOOT" == true ]]; then
    echo ""
    if [[ -n "$REBOOT_KERNEL" ]]; then
      echo -e " ${CYAN}REBOOT REQUIRED${NC}   ${YELLOW}boot into ${REBOOT_KERNEL}${NC} (run 'reboot')"
    else
      echo -e " ${CYAN}REBOOT REQUIRED${NC}   run 'reboot' on the PVE host"
    fi
  fi

  if [[ -n "$NTFY_NOTE" && "$1" != "pending" ]]; then
    echo ""
    echo -e " ${CYAN}NTFY${NC}              ${NTFY_NOTE}"
  fi

  if [[ "$MODE" == "check" ]]; then
    echo ""
    echo -e " ${CYAN}CHECK-ONLY RUN${NC} — nothing was changed. To apply updates:"
    echo -e "   ${BOLD}./pve-update.sh --apply${NC}            # host + all containers"
    echo -e "   ${BOLD}./pve-update.sh --apply 112 113${NC}    # specific containers"
    echo -e "   ${BOLD}./pve-update.sh --host-only --apply${NC} # Proxmox host only"
    echo -e "   ${BOLD}./pve-update.sh --apt-only --apply${NC} # OS patches only"
  fi

  echo ""
}

# =============================================================================
# CHECK, CONFIRM, APPLY
# =============================================================================
[[ "$INCLUDE_HOST" == true ]] && scan_host
run_phase scan_ct

if [[ "$MODE" == "apply" ]]; then
  print_summary pending
  if [[ "$HOST_PKG" -eq 0 && "$TOTAL_TODO_CTS" -eq 0 ]]; then
    echo -e " ${GREEN}● ALL UNITS NOMINAL — NOTHING TO APPLY${NC}"
    echo ""
    exit 0
  fi

  # CONFIRM-BEFORE-APPLY GATE. Everything above only looked; nothing changes
  # until this point. Asks for a y/N unless -y/--yes was given (a run without
  # a terminal and without -y was refused before the check). It fails safe:
  # if stdin ever hit EOF here, read leaves _reply empty → "no changes". The
  # apply acts on what the check found rather than checking again: the
  # packages are the ones listed above, while a Docker pull or a community
  # script takes whatever is newest when it runs.
  if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "$(echo -e " ${YELLOW}▶▶${NC} ${WHITE}ARM UPDATE SEQUENCE? [Y/N]${NC} ")" _reply
    if [[ ! "$_reply" =~ ^[Yy]$ ]]; then
      echo -e " ${YELLOW}■ STAND DOWN — NO CHANGES MADE${NC}"
      echo ""
      exit 0
    fi
  fi

  echo ""
  _head="${DIM}━━${NC} ${YELLOW}▶▶ EXECUTING UPDATE SEQUENCE${NC} ${DIM}// $(date '+%H:%M:%S')${NC} "
  echo -e "${_head}${DIM}$(rep_char ━ $(( CARD_W - $(vis_len "$_head") )))${NC}"
  # From here an interrupt still gets the end-of-run report (_on_signal).
  _applying=true
  if [[ "$HOST_PKG" -gt 0 ]]; then
    _host_acting=true
    act_host
    _host_acting=false
  fi
  run_phase act_ct
  send_failure_push
fi

print_summary

# Non-zero when anything failed, so a calling script or shell can tell
# (otherwise 0: an 'if' that didn't run its branch returns 0).
if [[ "$HOST_FAILED" == true || ${#FAILED_CTS[@]} -gt 0 ]]; then
  exit 1
fi
