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

exec 200>/var/lock/pve-update.lock
if ! flock -n 200; then
  echo "Error: another instance of pve-update.sh is already running." >&2
  exit 1
fi

timestamp() { date '+%H:%M:%S'; }
SCRIPT_START=$(date +%s)

MODE="check"
APT_ONLY=false
INCLUDE_HOST=true      # update the Proxmox host by default
HOST_ONLY=false        # --host-only: update only the host
NO_HOST=false          # --no-host: skip the host
TARGET_HOST=false      # set when 'host'/'pve' is passed as a target
TARGET_CTS=()

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)  MODE="apply"; shift ;;
    --check)  MODE="check"; shift ;;
    --apt-only) APT_ONLY=true; shift ;;
    --host-only) HOST_ONLY=true; shift ;;
    --no-host)   NO_HOST=true; shift ;;
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

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Proxmox Update Report — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}  Mode: ${CYAN}${MODE}${NC}${BOLD}  APT-only: ${APT_ONLY}  Host: ${INCLUDE_HOST}  Containers: ${#CTS[@]}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

TOTAL_PKG=0
TOTAL_COMMUNITY=0
TOTAL_DOCKER=0
FAILED_CTS=()
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

for ctid in "${CTS[@]}"; do
  CT_START=$(date +%s)

  # Verify the CT is running
  status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
  if [[ "$status" != "running" ]]; then
    echo -e "\n${YELLOW}⏭  CT $ctid — not running, skipping${NC}"
    continue
  fi

  ct_hostname=$(pct config "$ctid" 2>/dev/null | awk '/^hostname/{print $2}')

  # Detect OS and package manager — handles Alpine (ash/apk) vs Debian (bash/apt)
  os=$(pct exec "$ctid" -- sh -c '. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"' 2>/dev/null)
  pkg_manager="apt"
  if pct exec "$ctid" -- sh -c 'command -v apk >/dev/null 2>&1' 2>/dev/null; then
    pkg_manager="apk"
  elif ! pct exec "$ctid" -- sh -c 'command -v apt-get >/dev/null 2>&1' 2>/dev/null; then
    pkg_manager="unknown"
  fi

  # Detect apps that need extra env vars to upgrade non-interactively.
  extra_env=""
  if [[ "$pkg_manager" == "apt" ]] && pct exec "$ctid" -- sh -c 'command -v homebridge >/dev/null 2>&1' 2>/dev/null; then
    extra_env="UPDATE_HOMEBRIDGE_FORCE=1"
  fi

  echo ""
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}  CT ${ctid} — ${ct_hostname}${NC}  (${os:-unknown OS}) [${pkg_manager}]"
  echo -e "${BOLD}───────────────────────────────────────────────────────────────${NC}"

  # =========================================================================
  # 1. OS PACKAGE UPGRADES
  # =========================================================================
  ct_error=false

  if [[ "$pkg_manager" == "apt" ]]; then
    echo -e "\n  ${CYAN}[$(timestamp)] [apt]${NC} Checking for package updates..."
    pct exec "$ctid" -- bash -c 'apt-get update -qq 2>&1' >/dev/null 2>&1

    apt_upgrades=$(pct exec "$ctid" -- bash -c 'apt-get -s upgrade 2>/dev/null | grep "^Inst "' 2>/dev/null)
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
        echo -e "  ${CYAN}[$(timestamp)] [apt]${NC} Applying upgrades..."
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
    apk_upgrades=$(pct exec "$ctid" -- sh -c 'apk update >/dev/null 2>&1; apk list -u 2>/dev/null' 2>/dev/null)
    apk_count=0
    [[ -n "$apk_upgrades" ]] && apk_count=$(echo "$apk_upgrades" | grep -c '[a-z]')

    if [[ "$apk_count" -gt 0 ]]; then
      TOTAL_PKG=$((TOTAL_PKG + apk_count))
      echo -e "  ${YELLOW}⬆  ${apk_count} package(s) upgradeable:${NC}"
      echo "$apk_upgrades" | sed 's/^/     /'

      if [[ "$MODE" == "apply" ]]; then
        echo -e "  ${CYAN}[$(timestamp)] [apk]${NC} Applying upgrades..."
        pct exec "$ctid" -- sh -c 'apk upgrade --no-cache 2>&1' | sed 's/^/     /'
        apk_exit=${PIPESTATUS[0]}
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
    CT_ELAPSED=$(( $(date +%s) - CT_START ))
    echo -e "  ${CYAN}── completed in ${CT_ELAPSED}s${NC}"
    continue
  fi

  # =========================================================================
  # 2. COMMUNITY SCRIPT UPDATE
  # =========================================================================
  has_update=$(pct exec "$ctid" -- sh -c 'test -f /usr/bin/update && echo yes || echo no' 2>/dev/null)

  if [[ "$has_update" == "yes" ]]; then
    TOTAL_COMMUNITY=$((TOTAL_COMMUNITY + 1))
    update_cmd=$(pct exec "$ctid" -- cat /usr/bin/update 2>/dev/null)
    echo -e "\n  ${CYAN}[$(timestamp)] [community-script]${NC} Update mechanism found"

    if [[ "$MODE" == "apply" ]]; then
      echo -e "  ${CYAN}[$(timestamp)] [community-script]${NC} Running update..."
      # Write the script to a temp file to avoid shell expansion of its content,
      # then pipe 'yes' to auto-answer interactive prompts (read -p, etc.).
      _tmp="/tmp/.pve_update_$$"
      printf '%s\n' "$update_cmd" | pct exec "$ctid" -- bash -c "cat > $_tmp"
      yes 2>/dev/null | timeout 120 pct exec "$ctid" -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export TERM=xterm
        ${extra_env:+export $extra_env; }
        bash $_tmp
      " 2>&1
      community_exit=${PIPESTATUS[1]}
      pct exec "$ctid" -- rm -f "$_tmp" 2>/dev/null || true
      if [[ $community_exit -eq 0 ]]; then
        echo -e "  ${GREEN}✔  Community script update complete${NC}"
      else
        echo -e "  ${RED}✘  Community script failed (exit $community_exit)${NC}"
        ct_error=true
      fi
    else
      echo -e "  ${YELLOW}→  Run with --apply to execute community-script update${NC}"
    fi
  fi

  # =========================================================================
  # 3. DOCKER IMAGE UPDATES
  # =========================================================================
  has_docker=$(pct exec "$ctid" -- sh -c 'command -v docker >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null)

  if [[ "$has_docker" == "yes" ]]; then
    echo -e "\n  ${CYAN}[$(timestamp)] [docker]${NC} Checking Docker containers..."

    # Get running containers and their images
    docker_info=$(pct exec "$ctid" -- docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null)

    if [[ -n "$docker_info" ]]; then
      # Find compose files
      compose_files=$(pct exec "$ctid" -- sh -c '
        find /opt /root /home /srv /var -maxdepth 4 \
          \( -name "compose.yaml" -o -name "compose.yml" \
             -o -name "docker-compose.yaml" -o -name "docker-compose.yml" \) \
          2>/dev/null
      ' 2>/dev/null)

      while IFS='|' read -r cname cimage; do
        [[ -z "$cname" ]] && continue

        # Determine if the tag is pinned to a specific version (X.Y.Z or vX.Y.Z)
        tag="${cimage##*:}"
        [[ "$tag" == "$cimage" ]] && tag="latest"  # no tag = latest

        is_pinned=false
        if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+ && "$tag" != "latest" && ! "$tag" =~ ^[0-9]+$ ]]; then
          is_pinned=true
        fi

        if [[ "$is_pinned" == true ]]; then
          echo -e "  ${YELLOW}📌 ${cname}${NC} — ${cimage} (pinned version)"
          echo -e "     ${YELLOW}→ Update the tag in your compose file to upgrade${NC}"
          TOTAL_DOCKER=$((TOTAL_DOCKER + 1))
        else
          echo -e "  🐳 ${cname} — ${cimage}"

          if [[ "$MODE" == "apply" ]]; then
            echo -e "  ${CYAN}[$(timestamp)] [docker]${NC} Pulling ${cimage}..."
            pull_output=$(pct exec "$ctid" -- docker pull "$cimage" 2>&1)
            echo "$pull_output" | grep -E '^(Pulling|Digest|Status)' | sed 's/^/     /'

            if echo "$pull_output" | grep -q "Image is up to date"; then
              echo -e "  ${GREEN}✔  ${cimage} is already up to date${NC}"
            else
              echo -e "  ${GREEN}⬆  New image pulled for ${cimage}${NC}"
              TOTAL_DOCKER=$((TOTAL_DOCKER + 1))

              # Find the compose file that manages this container and recreate
              while IFS= read -r cf; do
                [[ -z "$cf" ]] && continue
                managed=$(pct exec "$ctid" -- sh -c "
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

  CT_ELAPSED=$(( $(date +%s) - CT_START ))
  [[ "$ct_error" == true ]] && FAILED_CTS+=("$ctid ($ct_hostname)")
  echo -e "  ${CYAN}── completed in ${CT_ELAPSED}s${NC}"
done

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

if [[ "$HOST_REBOOT" == true ]]; then
  if [[ -n "$REBOOT_KERNEL" ]]; then
    echo -e "  ${YELLOW}Reboot required:       boot into ${REBOOT_KERNEL} (run 'reboot')${NC}"
  else
    echo -e "  ${YELLOW}Reboot required:       run 'reboot' on the PVE host${NC}"
  fi
fi

if [[ "$MODE" == "check" ]]; then
  echo ""
  echo -e "  ${YELLOW}This was a CHECK-ONLY run. To apply updates:${NC}"
  echo -e "  ${BOLD}  ./pve-update.sh --apply${NC}            # host + all containers"
  echo -e "  ${BOLD}  ./pve-update.sh --apply 112 113${NC}    # specific containers"
  echo -e "  ${BOLD}  ./pve-update.sh --host-only --apply${NC} # Proxmox host only"
  echo -e "  ${BOLD}  ./pve-update.sh --apt-only --apply${NC} # OS patches only"
fi

echo ""
