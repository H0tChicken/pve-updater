# pve-update.sh

A single-file Proxmox VE update script that checks and applies updates across the PVE host and all running LXC containers in one pass — no configuration required.

## What it does

- **PVE host** — `apt dist-upgrade` (full-upgrade, per Proxmox best practice) with kernel-aware reboot detection
- **LXC containers** — apt (Debian/Ubuntu) and apk (Alpine) package upgrades, run in parallel
- **Community scripts** — detects and runs [tteck](https://community-scripts.github.io/ProxmoxVE/) `/usr/bin/update` hooks
- **Docker** — pulls new images and recreates containers via compose; warns on pinned version tags

New containers are discovered automatically. VMs (`qm`) are not handled.

## Requirements

- Proxmox VE 7+
- Run as root on the PVE host

## Install

```bash
curl -sO https://raw.githubusercontent.com/H0tChicken/pve-updater/main/pve-update.sh
chmod +x pve-update.sh
```

## Usage

```bash
./pve-update.sh                       # Check host + all running CTs
./pve-update.sh --apply               # Apply updates to host + all CTs
./pve-update.sh --apply 100 112       # Apply to specific CTs only (host skipped)
./pve-update.sh --apply host 100      # Apply to host + CT 100
./pve-update.sh --check 112 113       # Check specific CTs only
./pve-update.sh --host-only --apply   # PVE host only
./pve-update.sh --apt-only --apply    # OS packages only (skip community scripts + Docker)
./pve-update.sh --apply --no-host     # All CTs, skip PVE host
```

## Automatic updates (systemd timer)

```bash
sudo ./pve-update.sh --install-timer          # Install weekly timer (default)
sudo ./pve-update.sh --install-timer daily    # Install daily timer
```

View logs after a scheduled run:

```bash
journalctl -u pve-update.service
```

Remove the timer:

```bash
systemctl disable --now pve-update.timer
rm /etc/systemd/system/pve-update.{service,timer}
```

## Notes

- **Docker pinned tags** (e.g. `nginx:1.25.3`) are reported but never auto-updated — change the tag in your compose file first
- **Reboots** are never triggered automatically — the script flags when one is needed and which kernel to boot into
- **Homebridge** containers are auto-detected and receive `UPDATE_HOMEBRIDGE_FORCE=1` so upgrades proceed non-interactively
- **Community scripts** are written to a temp file before execution to prevent shell injection from script content
