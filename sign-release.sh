#!/usr/bin/env bash
# =============================================================================
# sign-release.sh — sign pve-update.sh so --self-update will accept it
# =============================================================================
# Run this after every change to pve-update.sh, before committing. It produces
# pve-update.sh.sig, a detached GPG signature that the script verifies against
# the public key pinned in PUBKEY_B64 before it replaces itself.
#
# Requires your GPG signing key. See the README "Signing releases" section for
# one-time setup (generating a key and pinning its public half).
#
# Optional: export SIGN_KEY=<fingerprint> to pick a specific signing key.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT="pve-update.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "Error: $SCRIPT not found next to this helper." >&2
  exit 1
fi

if grep -q 'PUBKEY_B64="PASTE_YOUR_BASE64_GPG_PUBKEY_HERE"' "$SCRIPT"; then
  echo "⚠  $SCRIPT still has the placeholder PUBKEY_B64 — pin your public key" >&2
  echo "   first (README → Signing releases, step 2). Signing anyway, but" >&2
  echo "   --self-update will reject this build until the real key is embedded." >&2
fi

# Sign the file AS-IS — the embedded public key is part of what gets signed, so
# always pin the key BEFORE signing, never the other way around.
gpg ${SIGN_KEY:+--local-user "$SIGN_KEY"} --batch --yes --detach-sign -o "${SCRIPT}.sig" "$SCRIPT"

echo "✔  Wrote ${SCRIPT}.sig"
echo "   Next: git add ${SCRIPT} ${SCRIPT}.sig && git commit && git push"
