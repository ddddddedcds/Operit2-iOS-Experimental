#!/bin/bash
# Assemble the Operit2 iOS device-automation .deb (rootless) from built artifacts.
# Mac has no dpkg-deb, so packdeb.py constructs the ar package in Python.
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
# Package scheme: rootless (default) or roothide. Override with OPERIT_PACK_SCHEME=roothide.
SCHEME="${OPERIT_PACK_SCHEME:-rootless}"
# roothide needs 4 extra entitlements (platform-application + AppBundles +
# AppDataContainers); those must NOT be applied to a plain rootless build, where
# platform-application can break app launch. Pick the file per scheme.
if [ "$SCHEME" = "roothide" ]; then
  ENTITLEMENTS="$BASE/Runner.roothide.entitlements"
else
  ENTITLEMENTS="$BASE/Runner.entitlements"
fi
# The daemon is a STANDALONE LaunchDaemon. It is launched by launchd as ROOT
# (plist UserName=root) because on iOS a mobile user cannot create a Unix domain
# socket in /var/mobile/.operit — it gets EACCES even though the directory is
# mobile-writable for regular files; only root can bind the socket. It therefore
# uses the SAME 4-key set as the app (platform-application + no-sandbox +
# AppBundles + AppDataContainers), which roothide requires for any binary that
# touches the jbroot. Running as root bypasses the mobile socket restriction.
DAEMON_ENTITLEMENTS="$ENTITLEMENTS"
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
# Sign with DAEMON_ENTITLEMENTS (= the scheme's 4-key set: platform-application +
# no-sandbox + AppBundles + AppDataContainers), which roothide requires for any
# binary that touches the jbroot. The actual EACCES-on-socket fix is running the
# daemon as ROOT (plist UserName=root); a mobile user cannot bind a Unix socket
# in /var/mobile/.operit even though the dir is mobile-writable for plain files.
# Sign the daemon. roothide's AMFI REJECTS Apple ad-hoc codesign (SIGKILL on
# exec -> launchctl ExitCode 9, agent.sock never appears); the roothide-ecosystem
# signer is `ldid`. Prefer macOS ldid (stable) when building the roothide scheme;
# fall back to codesign for rootless / when ldid is absent.
if [ "$SCHEME" = "roothide" ] && [ -x /usr/local/bin/ldid ]; then
  echo "   signing daemon (macOS ldid) with entitlements ..."
  /usr/local/bin/ldid -S"$DAEMON_ENTITLEMENTS" "$FILES/usr/bin/operit_agent_daemon" 2>&1 | tail -3 || \
    echo "   (ldid failed; daemon will need 'sudo ldid -S' on-device)"
else
  echo "   ad-hoc signing daemon (macOS codesign) with daemon entitlements ..."
  codesign --force --sign - --entitlements "$DAEMON_ENTITLEMENTS" "$FILES/usr/bin/operit_agent_daemon" 2>&1 | tail -3 || \
    echo "   (codesign unavailable; daemon will need 'sudo ldid -S' on-device)"
fi
# Ship the entitlements file into the deb so postinst can re-sign the daemon
# on-device with the EXACT same keys. A bare `ldid -S` (no file) would strip
# platform-application + no-sandbox; under roothide that breaks the daemon
# (sandbox/file-access failures) on top of the signature-trust problem.
mkdir -p "$FILES/usr/share/operit"
cp "$ENTITLEMENTS" "$FILES/usr/share/operit/operit.entitlements"

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
  codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$FILES/Applications/Runner.app" 2>&1 | tail -3 || \
    echo "   (codesign unavailable; rely on postinst ldid + AppSync Unified)"
  echo "   app staged: $(du -sh "$FILES/Applications/Runner.app" | cut -f1)"
  # --- produce IPA (app already ad-hoc signed above with $ENTITLEMENTS) ---
  IPA_NAME="operit2-ios_0.3.55_$( [ "$SCHEME" = "roothide" ] && echo iphoneos-arm64e || echo iphoneos-arm64 ).ipa"
  IPA_OUT="$BASE/$IPA_NAME"
  echo "   building IPA: $IPA_NAME"
  ( cd "$FILES/Applications" && rm -rf Payload && mkdir Payload && cp -R Runner.app Payload/ && zip -q -r "$IPA_OUT" Payload && rm -rf Payload )
  echo "   wrote $IPA_NAME ($(du -h "$IPA_OUT" | cut -f1))"
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
for s in [b'operit-agent daemon v', b'OK|pong', '设备上下文'.encode(), b'frontmost_app', b'127.0.0.1', b'operit.sock', b'0.3.9', '屏幕未变化'.encode()]:
    if s in data:
        print("  [OK]  ", s[:30])
    else:
        print("  [MISS]", s[:30]); ok=False
if not ok:
    print("STALE BUILD — rerun: cargo clean && cargo build --release --target aarch64-apple-ios --bin operit_agent_daemon")
    sys.exit(1)
PY
echo "  all key strings present."

# --- roothide layout fixups ---
# Under roothide the process rootfs view IS the jbroot, so the launchd plist must
# reference paths WITHOUT the /var/jb prefix (e.g. /usr/bin/... and /var/mobile);
# otherwise the daemon binary / HOME would point at a non-existent /var/jb path.
if [ "$SCHEME" = "roothide" ]; then
  echo "   roothide scheme: rewriting launchd plist paths for real-root anchor"
  PLIST="$FILES/Library/LaunchDaemons/ai.operit.agent.plist"
  if [ -f "$PLIST" ]; then
    # 1) drop the /var/jb prefix (roothide has no /var/jb; daemon lives in the
    #    jbroot container at /usr/bin/...).
    sed -i '' 's#/var/jb##g' "$PLIST"
    # 2) the launchd plist already references /var/mobile/.operit (no /var/jb
    #    prefix under roothide). The daemon and app exchange the agent control
    #    channel + config over loopback TCP (127.0.0.1:8890), which is shared
    #    across the per-process /var remap, so no /rootfs re-anchoring is needed.
  fi
fi

# --- pack ---
export OPERIT_PACK_SCHEME="$SCHEME"
python3 "$BASE/packdeb.py"
echo "done."
