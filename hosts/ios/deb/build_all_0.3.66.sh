#!/bin/bash
# Build all three Operit2 0.3.66 products from a CI-built UNSIGNED Runner.app:
#   1. rootless deb  (iphoneos-arm64)   + matching .ipa
#   2. roothide deb  (iphoneos-arm64e)  + matching .ipa
#   3. nonjb .ipa    (re-signed with Runner-nonjb.entitlements)
#
# The daemon binary is the already-validated 0.3.65 build
# (hosts/ios/target/aarch64-apple-ios/release/operit_agent_daemon, built 2026-08-04
# 14:12). It does NOT call binary_root(), so the 0.3.66 terminal fix does not
# touch it — we keep the validated binary to avoid re-introducing risk.
#
# Usage:
#   APP_SRC=/path/to/Runner.app bash build_all_0.3.66.sh
#   build_all_0.3.66.sh /path/to/Runner.app
set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${1:-${APP_SRC:-/Users/mac/Downloads/Runner.app}}"
if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: APP_SRC not found: $APP_SRC"
  echo "Usage: APP_SRC=/path/to/Runner.app bash $0"
  exit 1
fi
cd "$BASE"
VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' DEBIAN/control)"
echo "=== VERSION=$VERSION  APP_SRC=$APP_SRC ==="

# 1) rootless
echo; echo "########## rootless ##########"
APP_SRC="$APP_SRC" OPERIT_PACK_SCHEME=rootless bash build_deb.sh

# 2) roothide
echo; echo "########## roothide ##########"
APP_SRC="$APP_SRC" OPERIT_PACK_SCHEME=roothide bash build_deb.sh

# 3) nonjb .ipa — re-sign with nonjb entitlements, zip into Payload
echo; echo "########## nonjb .ipa ##########"
NONJB_ENT="$BASE/Runner-nonjb.entitlements"
OUT_IPA="$BASE/operit2-ios_${VERSION}_nonjb.ipa"
TMP="$(mktemp -d)"
cp -R "$APP_SRC" "$TMP/Runner.app"
xattr -cr "$TMP/Runner.app" 2>/dev/null || true
rm -rf "$TMP/Runner.app/_CodeSignature" 2>/dev/null || true
echo "   ad-hoc signing app (nonjb) with $NONJB_ENT ..."
codesign --force --deep --sign - --entitlements "$NONJB_ENT" "$TMP/Runner.app" 2>&1 | tail -3 || echo "   (codesign failed; user must re-sign for sideload)"
rm -f "$OUT_IPA"
( cd "$TMP" && mkdir -p Payload && cp -R Runner.app Payload/ && zip -q -r "$OUT_IPA" Payload )
rm -rf "$TMP"
echo "   wrote $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"

# ---- verify ----
echo; echo "########## verify ##########"
for f in "operit2-ios_${VERSION}_iphoneos-arm64.deb" \
         "operit2-ios_${VERSION}_iphoneos-arm64.ipa" \
         "operit2-ios_${VERSION}_iphoneos-arm64e.deb" \
         "operit2-ios_${VERSION}_iphoneos-arm64e.ipa" \
         "operit2-ios_${VERSION}_nonjb.ipa"; do
  if [ -f "$BASE/$f" ]; then echo "  OK   $f ($(du -h "$BASE/$f" | cut -f1))"; else echo "  MISSING  $f"; fi
done
echo "done."
