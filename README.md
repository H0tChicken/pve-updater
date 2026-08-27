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

## Keeping the script up to date

On any interactive run the script checks GitHub and prints a one-line notice if a
newer version exists. It **never** updates itself automatically. To pull the
latest version:

```bash
./pve-update.sh --self-update       # download, GPG-verify, diff+confirm, replace
./pve-update.sh --self-update -y    # ...skip the diff/confirm prompt
./pve-update.sh --version           # show the running script's checksum
./pve-update.sh --no-update-check   # suppress the "new version" check for one run
```

`--self-update` downloads the script **and a detached GPG signature**, verifies
the signature against a public key pinned inside the running script, shows a diff
and asks for confirmation, then does an atomic in-place replace. It **fails
closed**: a missing/invalid signature, the wrong key, a missing pinned key, or a
failed syntax check all abort without touching the installed file. Downloads are
HTTPS-only (no protocol downgrade). The systemd timer runs skip the check
entirely, so scheduled updates never depend on the network.

Because the trusted key lives in the *currently-running* script, a malicious push
to the GitHub repo cannot rotate it — an attacker would need your private signing
key, which never touches the repo or the hypervisor. This is the one protection
that actually defends against repo/token compromise (checksums in the same repo
do not — an attacker who can push code can update them too).

### Signing releases (required for `--self-update`)

`--self-update` refuses to run until you complete this one-time setup. Verification
uses `gpgv`, which is already installed on every Proxmox host.

**1. Generate a signing key** (once, on a machine you control — not the hypervisor):

```bash
gpg --quick-generate-key "PVE Updater" ed25519 sign never
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
```

Keep the **private** key safe and off the repo.

**2. Pin the public key** in `pve-update.sh` — replace the `PUBKEY_B64` placeholder
with the output of:

```bash
gpg --export "$FPR" | base64 | tr -d '\n'
```

**3. Sign and commit** after every change to the script (pin the key *before*
signing — the embedded key is part of what gets signed):

```bash
./sign-release.sh    # -> pve-update.sh.sig   (export SIGN_KEY=$FPR to pick a key)
git add pve-update.sh pve-update.sh.sig
git commit -m "Release" && git push
```

> First-time note: existing installs still carry the placeholder key, so
> `--self-update` on them will refuse until you `curl` down one fresh copy that
> has your real key pinned (see [Install](#install)). After that, `--self-update`
> takes over and every future update is signature-checked.

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
./pve-update.sh --apply -y            # Apply without the confirm prompt
./pve-update.sh --self-update         # Update this script from GitHub
```

When you run `--apply` in a terminal, the script first previews what's available
(a check pass over the same targets) and asks **`Apply these updates now? [y/N]`**
before changing anything — answer `n` and nothing is touched. Pass `-y` to skip
the prompt. The systemd timer runs with no terminal, so it always applies
unattended (the prompt is skipped automatically).

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

- **Docker pinned tags** (e.g. `nginx:1.25.3`) are reported but never auto-updated — change the tag in your compose file first. The summary counts them separately (`Images pinned (manual bump)`) from images the script actually updated, because only the pinned ones need you to edit a file
- **Check mode and Docker**: a `--check` run asks each unpinned image's registry whether the tag still resolves to the image you're running, so its count matches what `--apply` would do. It's read-only — no layers are downloaded and no container is recreated. If a registry can't be reached (private repo needing auth, locally-built image, or Docker Hub's anonymous rate limit — a sweep of many containers can trip its 429) the image is reported as not checked rather than guessed at, and a `Images not checked` line appears in the summary so a `0` above it is never mistaken for all-clear. Running `docker login` inside the container raises the Hub limit
- **Reboots** are never triggered automatically — the script flags when one is needed and which kernel to boot into
- **Homebridge** containers: `UPDATE_HOMEBRIDGE_FORCE=1` is set only on containers where `dpkg -s homebridge` confirms the package is installed, so the homebridge package's "must not be upgraded from the UI Terminal" guard doesn't block unattended upgrades. Other containers are left alone
- **Low disk space**: if a community script aborts itself because the container is low on disk, that's reported as a **skip** (not a failure) — free space (e.g. `pct resize <id> rootfs +2G`) and re-run
- **Community scripts** are written to a temp file before execution to prevent shell injection from script content
