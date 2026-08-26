#!/bin/bash
# Assemble the Operit2 NON-jailbroken IPA: AI chat shell + embedded iSH
# terminal (kernel=ish, aarch64 Alpine guest), running in the standard iOS
# sandbox. No private entitlements (no no-sandbox), no tweak/daemon/appex —
# the jailbreak-only pieces are intentionally excluded.
#
# Install: the IPA is ad-hoc signed. Sideload it with Sideloadly/AltStore
# using your own Apple ID certificate (the tool re-signs the whole bundle on
# install). Entitlements that survive re-signing: standard keys only
# (iokit-user-client-class for Metal is honored even under ad-hoc/Dev cert).
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$BASE/Runner-nonjb.entitlements"
# Version source = same single source of truth as the rootless deb.
VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$BASE/DEBIAN/control")"
FILES="$BASE/files-nonjb"

APP_SRC="${APP_SRC:-/Users/mac/Downloads/Runner.app}"
[ -d "$APP_SRC" ] || { echo "ERROR: APP_SRC not found: $APP_SRC"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "ERROR: $ENTITLEMENTS missing"; exit 1; }

# --- stage app (fresh staging dir; no daemon/dylibs/appex in nonjb) ---
rm -rf "$FILES"
mkdir -p "$FILES/Applications"
cp -R "$APP_SRC" "$FILES/Applications/Runner.app"
xattr -cr "$FILES/Applications/Runner.app" 2>/dev/null || true
rm -rf "$FILES/Applications/Runner.app/_CodeSignature" 2>/dev/null || true

# --- sign with NONJB entitlements (standard sandbox, no private keys) ---
echo "== ad-hoc signing app (NONJB entitlements, standard sandbox) =="
codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" \
    "$FILES/Applications/Runner.app" 2>&1 | tail -2
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "FATAL: codesign of Runner.app FAILED — nonjb IPA would be unsigned"
    exit 1
fi
codesign --verify --verbose=1 "$FILES/Applications/Runner.app" 2>&1 | tail -1

# --- pack IPA ---
IPA_NAME="operit2-ios_${VERSION}_nonjb_iphoneos-arm64.ipa"
IPA_OUT="$BASE/$IPA_NAME"
echo "== building IPA: $IPA_NAME =="
( cd "$FILES/Applications" \
    && mkdir -p Payload && cp -R Runner.app Payload/ \
    && rm -f "$IPA_OUT" && zip -q -r "$IPA_OUT" Payload \
    && rm -rf Payload )
echo "wrote $IPA_NAME ($(du -h "$IPA_OUT" | cut -f1))"
echo ""
echo "NOTE: ad-hoc signed — install via Sideloadly/AltStore (re-signs with your Apple ID)."
