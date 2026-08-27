#!/usr/bin/env bash
# =============================================================================
# sign-release.sh — sign pve-update.sh so --self-update will accept it
# =============================================================================
# Run this after every change to pve-update.sh, before committing. It produces
# pve-update.sh.sig, a detached GPG signature that the script verifies against
# the public key pinned in PUBKEY_B64 before it replaces itself.
#
# The signing key is DERIVED from that pinned PUBKEY_B64, so there is exactly
# one source of truth and no way to sign with the wrong key by accident. This
# matters when the keyring holds more than one secret key: gpg's own default
# (with no default-key in gpg.conf) is whichever key it feels like, which is not
# necessarily the release key, and a signature from the wrong key is not
# detectable at signing time — it only shows up later as a rejected
# --self-update on someone else's machine.
#
# After signing, the signature is verified back against the pinned key and the
# run FAILS if it was made by anything else.
#
# Optional: export SIGN_KEY=<fingerprint> to override the derived key (e.g. when
# rotating keys, before the new public half is pinned). The post-sign check
# still runs, so an override that doesn't match the pinned key is refused.
#
# Requires your GPG signing key. See the README "Signing releases" section for
# one-time setup (generating a key and pinning its public half).
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

# --- Derive the expected signer from the key pinned in the script -------------
# Read the pinned public key, decode it, and take its primary fingerprint. This
# is the key --self-update will check against, so it is the only key worth
# signing with.
PINNED_B64=$(sed -n 's/^PUBKEY_B64="\(.*\)"$/\1/p' "$SCRIPT" | head -n1)
EXPECTED_FPR=""
if [[ -n "$PINNED_B64" && "$PINNED_B64" != "PASTE_YOUR_BASE64_GPG_PUBKEY_HERE" ]]; then
  EXPECTED_FPR=$(printf '%s' "$PINNED_B64" | base64 --decode 2>/dev/null \
    | gpg --show-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}') || true
fi

if [[ -z "$EXPECTED_FPR" ]]; then
  echo "Error: could not read a usable public key out of PUBKEY_B64 in $SCRIPT." >&2
  echo "       Pin the release key first, or set SIGN_KEY=<fingerprint>." >&2
  [[ -n "${SIGN_KEY:-}" ]] || exit 1
fi

KEY="${SIGN_KEY:-$EXPECTED_FPR}"

if [[ -n "${SIGN_KEY:-}" && -n "$EXPECTED_FPR" && "$SIGN_KEY" != "$EXPECTED_FPR" ]]; then
  echo "⚠  SIGN_KEY ($SIGN_KEY) is not the key pinned in $SCRIPT" >&2
  echo "   ($EXPECTED_FPR). Signing with it, but the check below will fail" >&2
  echo "   unless you are mid-rotation and about to re-pin." >&2
fi

# Confirm we actually hold the secret half before writing anything, so a missing
# key is a clear message instead of a gpg error mid-run.
if ! gpg --list-secret-keys "$KEY" >/dev/null 2>&1; then
  echo "Error: no secret key for $KEY in this keyring." >&2
  echo "       Import the release key, or set SIGN_KEY=<fingerprint>." >&2
  exit 1
fi

# Sign the file AS-IS — the embedded public key is part of what gets signed, so
# always pin the key BEFORE signing, never the other way around.
# Sign to a temp file and only move it into place once it has been checked: a
# failed or cancelled signing must never clobber a known-good ${SCRIPT}.sig.
TMPSIG="${SCRIPT}.sig.tmp.$$"
trap 'rm -f "$TMPSIG"' EXIT
gpg --local-user "$KEY" --batch --yes --detach-sign -o "$TMPSIG" "$SCRIPT"

# --- Fail closed: prove the signature came from the pinned key ----------------
# Without this the wrong-key case is silent here and only surfaces as a rejected
# --self-update on a user's machine. VALIDSIG carries both the signing key and
# the primary key fingerprint, so matching either is enough.
if [[ -n "$EXPECTED_FPR" ]]; then
  STATUS=$(gpg --status-fd=1 --verify "$TMPSIG" "$SCRIPT" 2>/dev/null || true)
  if ! grep -q "VALIDSIG.*${EXPECTED_FPR}" <<<"$STATUS"; then
    echo "✘  Signature was NOT made by the key pinned in $SCRIPT" >&2
    echo "   expected: $EXPECTED_FPR" >&2
    echo "   Discarded it rather than ship a build --self-update rejects;" >&2
    echo "   any existing ${SCRIPT}.sig was left untouched." >&2
    exit 1
  fi
fi

mv -f "$TMPSIG" "${SCRIPT}.sig"

echo "✔  Wrote ${SCRIPT}.sig"
echo "   Signed by: $EXPECTED_FPR (matches the key pinned in $SCRIPT)"
echo "   Next: git add ${SCRIPT} ${SCRIPT}.sig && git commit && git push"
