#!/bin/bash
# Assemble the Operit2 iOS device-automation .deb (rootless) from built artifacts.
# Mac has no dpkg-deb, so packdeb.py constructs the ar package in Python.
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
IOS="$BASE/.."                       # hosts/ios
TWEAK="$IOS/tweak"
DAEMON="$IOS/target/aarch64-apple-ios/release/operit_agent_daemon"
FILES="$BASE/files"

# --- sanity: artifacts must exist ---
[ -f "$DAEMON" ] || { echo "ERROR: daemon not built: $DAEMON"; exit 1; }
# Copy the FAT (arm64+arm64e) dylib, NOT the per-arch slice — A12+ devices are arm64e,
# an arm64-only dylib injected into an arm64e process (e.g. SpringBoard) fails / crashes.
SB="$TWEAK/.theos/obj/debug/operit-sb.dylib"
APP="$TWEAK/.theos/obj/debug/operit-app.dylib"
[ -f "$SB" ] || { echo "ERROR: operit-sb.dylib not built (fat)"; exit 1; }
[ -f "$APP" ] || { echo "ERROR: operit-app.dylib not built (fat)"; exit 1; }

# --- stage files into rootless layout (relative to /var/jb) ---
mkdir -p "$FILES/usr/bin" "$FILES/Library/MobileSubstrate/DynamicLibraries" "$FILES/Library/LaunchDaemons"
cp "$DAEMON" "$FILES/usr/bin/operit_agent_daemon"
# ad-hoc sign the daemon (standalone LaunchDaemon binary) so AMFI does not SIGKILL it
# on exec. An unsigned daemon -> launchctl reports ExitCode 9 and agent.sock never appears.
# NOTE: sign WITH entitlements (app-sandbox=false) so it can reach /var/jb/var/mobile/.operit/*.
echo "   ad-hoc signing daemon (macOS codesign) with entitlements ..."
codesign --force --sign - --entitlements "$BASE/Runner.entitlements" "$FILES/usr/bin/operit_agent_daemon" 2>&1 | tail -3 || \
  echo "   (codesign unavailable; daemon will need 'sudo ldid -S' on-device)"
cp "$SB" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.dylib"
cp "$TWEAK/operit-sb.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.plist"
cp "$APP" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.dylib"
cp "$TWEAK/operit-app.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.plist"
cp "$BASE/files/Library/LaunchDaemons/ai.operit.agent.plist" "$FILES/Library/LaunchDaemons/ai.operit.agent.plist" 2>/dev/null || true

# --- stage frontend app (override source with APP_SRC=... ; default = local build output) ---
APP_SRC="${APP_SRC:-/Users/mac/Downloads/Runner 2.app}"
if [ -d "$APP_SRC" ]; then
  echo "== staging frontend app: $APP_SRC =="
  rm -rf "$FILES/Applications"
  mkdir -p "$FILES/Applications"
  cp -R "$APP_SRC" "$FILES/Applications/Runner.app"
  # drop any download quarantine / resource-fork xattrs; strip stale sig if any
  xattr -cr "$FILES/Applications/Runner.app" 2>/dev/null || true
  rm -rf "$FILES/Applications/Runner.app/_CodeSignature" 2>/dev/null || true
  # pre-sign the app on macOS (ad-hoc) so it arrives signed on-device —
  # avoids depending on ldid being present in the device postinst.
  # IMPORTANT: sign WITH entitlements. A bare ad-hoc sign (no --entitlements)
  # strips the original entitlements and the app loses
  # com.apple.security.iokit-user-client-class (AGXDeviceUserClient /
  # IOSurfaceRootUserClient) -> the kernel System Policy denies Metal/IOSurface
  # at launch and Flutter's Impeller engine aborts (SIGABRT). app-sandbox=false
  # lets the app reach /var/jb/var/mobile/.operit/agent.sock and its own caches.
  echo "   ad-hoc signing app (macOS codesign) with entitlements ..."
  codesign --force --deep --sign - --entitlements "$BASE/Runner.entitlements" "$FILES/Applications/Runner.app" 2>&1 | tail -3 || \
    echo "   (codesign unavailable; rely on postinst ldid + AppSync Unified)"
  echo "   app staged: $(du -sh "$FILES/Applications/Runner.app" | cut -f1)"
else
  echo "WARNING: APP_SRC not found ($APP_SRC); building backend-only deb"
fi

# --- verify key protocol strings before packaging (cargo cache guard) ---
# Use byte-level search (macOS `strings` drops wide UTF-8, giving false MISS).
echo "== verifying daemon binary strings (byte-level) =="
python3 - "$FILES/usr/bin/operit_agent_daemon" <<'PY'
import sys
data=open(sys.argv[1],'rb').read()
ok=True
for s in [b'operit-agent daemon v', b'OK|pong', '设备上下文'.encode(), b'frontmost_app', b'agent.sock', b'operit.sock', b'0.3.9', '屏幕未变化'.encode()]:
    if s in data:
        print("  [OK]  ", s[:30])
    else:
        print("  [MISS]", s[:30]); ok=False
if not ok:
    print("STALE BUILD — rerun: cargo clean && cargo build --release --target aarch64-apple-ios --bin operit_agent_daemon")
    sys.exit(1)
PY
echo "  all key strings present."

# --- pack ---
python3 "$BASE/packdeb.py"
echo "done."
