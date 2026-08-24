#!/bin/bash
# Assemble the Operit2 iOS device-automation .deb (rootless) from built artifacts.
# Mac has no dpkg-deb, so packdeb.py constructs the ar package in Python.
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
# Rootless-only (this fork no longer ships a roothide build).
ENTITLEMENTS="$BASE/Runner.entitlements"
# Standalone LaunchDaemon agent daemon (restored 0.3.65): launched by launchd as
# the automation host on 127.0.0.1:8890 (TCP, so any user can bind it — the plist
# runs it as mobile). Gives lock-screen / background automation the foreground app
# can't (iOS suspends backgrounded apps). On-device postinst re-signs the daemon
# with ldid and registers its cdhash in the jailbreak trustcache via
# `jbctl trustcache add`, so AMFI does not SIGKILL it at exec (ExitCode 9).

# Single source of truth for the package version = the `Version:` field in
# DEBIAN/control. packdeb.py reads the SAME field, so bumping control bumps the
# .deb AND .ipa names automatically — no more editing 3 files by hand.
VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$BASE/DEBIAN/control")"
IOS="$BASE/.."                       # hosts/ios
TWEAK="$IOS/tweak"
FILES="$BASE/files"
# Standalone agent daemon (restored 0.3.65): prebuilt release binary from the
# Rust crate (hosts/ios/target/aarch64-apple-ios/release). Re-signed + trustcache
# registered on-device by postinst; build-time sign is just so it ships signed.
DAEMON="$IOS/target/aarch64-apple-ios/release/operit_agent_daemon"
[ -f "$DAEMON" ] || { echo "ERROR: daemon not built: $DAEMON"; exit 1; }

# --- sanity: tweak dylibs must exist ---
# Copy the FAT (arm64+arm64e) dylib, NOT the per-arch slice — A12+ devices are arm64e,
# an arm64-only dylib injected into an arm64e process (e.g. SpringBoard) fails / crashes.
# Build mode: THEOS_MODE=release → .theos/obj/（`make FINALPACKAGE=1` 产物，-O2+strip，体积小 35%）
#             默认 debug → .theos/obj/debug/（`make` 默认产物，带符号，方便调试）
THEOS_MODE="${THEOS_MODE:-debug}"
[ "$THEOS_MODE" = "release" ] && OBJ_DIR=".theos/obj" || OBJ_DIR=".theos/obj/debug"
echo "   [build_deb] tweak dylib mode: $THEOS_MODE (${OBJ_DIR}/)"
SB="$TWEAK/$OBJ_DIR/operit-sb.dylib"
APP="$TWEAK/$OBJ_DIR/operit-app.dylib"
[ -f "$SB" ] || { echo "ERROR: operit-sb.dylib not built (fat) at ${OBJ_DIR}/"; exit 1; }
[ -f "$APP" ] || { echo "ERROR: operit-app.dylib not built (fat) at ${OBJ_DIR}/"; exit 1; }

# --- stage files into rootless layout (relative to /var/jb) ---
# Standalone agent daemon (restored 0.3.65): stage the binary, pre-sign it on
# macOS, and ship the plist so postinst can re-sign + trustcache-register it.
mkdir -p "$FILES/usr/bin" "$FILES/Library/LaunchDaemons"
cp "$DAEMON" "$FILES/usr/bin/operit_agent_daemon"
# Pre-sign the daemon on macOS so it ships signed. The entitlements are
# used (same key set as the app): the daemon touches the jbroot and needs the
# On-device postinst re-signs with ldid and registers the new cdhash via
# `jbctl trustcache add` — THAT is what prevents AMFI SIGKILL.
echo "   ad-hoc signing daemon (macOS codesign) with entitlements ..."
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$FILES/usr/bin/operit_agent_daemon" 2>&1 | tail -3 || \
  echo "   (codesign unavailable; postinst re-signs on-device)"
# Ship the daemon LaunchDaemon plist. packdeb.py rewrites the daemon path for
# the rootless scheme (binary at /var/jb/usr/bin, not /usr/bin).
if [ ! -f "$FILES/Library/LaunchDaemons/ai.operit.agent.plist" ]; then
  echo "   WARN: daemon plist missing at files/Library/LaunchDaemons/"
fi

mkdir -p "$FILES/Library/MobileSubstrate/DynamicLibraries"
# Ship the APP's full entitlements into the deb so postinst can re-sign the
# frontend app on-device (no-sandbox + iokit Metal + keychain — the app needs
# all of those).
mkdir -p "$FILES/usr/share/operit"
cp "$ENTITLEMENTS" "$FILES/usr/share/operit/operit.entitlements"

cp "$SB" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.dylib"
cp "$TWEAK/operit-sb.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.plist"
cp "$APP" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.dylib"
cp "$TWEAK/operit-app.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.plist"

# --- stage frontend app (override source with APP_SRC=... ; default = local build output) ---
APP_SRC="${APP_SRC:-/Users/mac/Downloads/Runner 2.app}"
if [ -d "$APP_SRC" ]; then
  echo "== staging frontend app: $APP_SRC =="
  # NOTE: use mv-to-tmp instead of `rm -rf` for the big app trees. A Runner.app
  # is ~1000+ files and bulk-delete guards (and slow recursive unlinks) get in
  # the way; renaming the directory is one syscall and the tmp copy is reaped by
  # the OS. Same trick for the Payload dir below.
  _stale="${TMPDIR:-/tmp}/operit-stale-$$-app"
  [ -d "$FILES/Applications" ] && mv "$FILES/Applications" "$_stale" 2>/dev/null || true
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
  # --- embed ScreenTimeMonitor app extension (DeviceActivityMonitor, iOS 16+) ---
  # Embed AFTER the app's --deep codesign so this ad-hoc sign is not overwritten
  # with the app's entitlements (the extension needs its own App Group keys).
  EXT_SRC="$BASE/../../../apps/flutter/app/ios/ScreenTimeMonitor/out/ScreenTimeMonitor.appex"
  EXT_ENT="$BASE/../../../apps/flutter/app/ios/ScreenTimeMonitor/Entitlements.plist"
  if [ -d "$EXT_SRC" ]; then
    mkdir -p "$FILES/Applications/Runner.app/PlugIns"
    cp -R "$EXT_SRC" "$FILES/Applications/Runner.app/PlugIns/ScreenTimeMonitor.appex"
    xattr -cr "$FILES/Applications/Runner.app/PlugIns/ScreenTimeMonitor.appex" 2>/dev/null || true
    if command -v ldid >/dev/null 2>&1; then
      ldid -S"$EXT_ENT" "$FILES/Applications/Runner.app/PlugIns/ScreenTimeMonitor.appex/ScreenTimeMonitor"
      echo "   signed ScreenTimeMonitor.appex (ldid)"
    else
      codesign --force --sign - --entitlements "$EXT_ENT" "$FILES/Applications/Runner.app/PlugIns/ScreenTimeMonitor.appex"
      echo "   signed ScreenTimeMonitor.appex (codesign)"
    fi
  else
    echo "   WARN: ScreenTimeMonitor.appex not built at $EXT_SRC; skipping extension"
  fi
  # --- embed LiveActivityWidget app extension (Dynamic Island / lock screen, iOS 16.1+) ---
  WID_SRC="$BASE/../../../apps/flutter/app/ios/LiveActivityWidget/out/LiveActivityWidget.appex"
  WID_ENT="$BASE/../../../apps/flutter/app/ios/LiveActivityWidget/Entitlements.plist"
  if [ -d "$WID_SRC" ]; then
    cp -R "$WID_SRC" "$FILES/Applications/Runner.app/PlugIns/LiveActivityWidget.appex"
    xattr -cr "$FILES/Applications/Runner.app/PlugIns/LiveActivityWidget.appex" 2>/dev/null || true
    if command -v ldid >/dev/null 2>&1; then
      ldid -S"$WID_ENT" "$FILES/Applications/Runner.app/PlugIns/LiveActivityWidget.appex/LiveActivityWidget"
      echo "   signed LiveActivityWidget.appex (ldid)"
    else
      codesign --force --sign - --entitlements "$WID_ENT" "$FILES/Applications/Runner.app/PlugIns/LiveActivityWidget.appex"
      echo "   signed LiveActivityWidget.appex (codesign)"
    fi
  else
    echo "   WARN: LiveActivityWidget.appex not built at $WID_SRC; skipping live activity widget"
  fi
  # --- embed ShieldConfig app extension (custom AI shield text, iOS 16+) ---
  SHIELD_SRC="$BASE/../../../apps/flutter/app/ios/ShieldConfig/out/OperitShieldConfig.appex"
  SHIELD_ENT="$BASE/../../../apps/flutter/app/ios/ShieldConfig/Entitlements.plist"
  if [ -d "$SHIELD_SRC" ]; then
    cp -R "$SHIELD_SRC" "$FILES/Applications/Runner.app/PlugIns/OperitShieldConfig.appex"
    xattr -cr "$FILES/Applications/Runner.app/PlugIns/OperitShieldConfig.appex" 2>/dev/null || true
    if command -v ldid >/dev/null 2>&1; then
      ldid -S"$SHIELD_ENT" "$FILES/Applications/Runner.app/PlugIns/OperitShieldConfig.appex/OperitShieldConfig"
      echo "   signed OperitShieldConfig.appex (ldid)"
    else
      codesign --force --sign - --entitlements "$SHIELD_ENT" "$FILES/Applications/Runner.app/PlugIns/OperitShieldConfig.appex"
      echo "   signed OperitShieldConfig.appex (codesign)"
    fi
  else
    echo "   WARN: OperitShieldConfig.appex not built at $SHIELD_SRC; skipping shield config extension"
  fi
  echo "   app staged: $(du -sh "$FILES/Applications/Runner.app" | cut -f1)"
  # --- produce IPA (app already ad-hoc signed above with $ENTITLEMENTS) ---
  IPA_NAME="operit2-ios_${VERSION}_iphoneos-arm64.ipa"
  IPA_OUT="$BASE/$IPA_NAME"
  echo "   building IPA: $IPA_NAME"
  ( cd "$FILES/Applications" \
      && { [ -d Payload ] && mv Payload "${TMPDIR:-/tmp}/operit-stale-$$-pre" 2>/dev/null || true; } \
      && mkdir Payload && cp -R Runner.app Payload/ \
      && rm -f "$IPA_OUT" && zip -q -r "$IPA_OUT" Payload \
      && mv Payload "${TMPDIR:-/tmp}/operit-stale-$$-post" 2>/dev/null || true )
  echo "   wrote $IPA_NAME ($(du -h "$IPA_OUT" | cut -f1))"
else
  echo "WARNING: APP_SRC not found ($APP_SRC); building backend-only deb"
fi

# --- pack ---
export OPERIT_PACK_SCHEME=rootless
python3 "$BASE/packdeb.py"
echo "done."
