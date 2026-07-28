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
SB=$(find "$TWEAK/.theos/obj/debug/arm64" -name 'operit-sb.dylib' 2>/dev/null | head -1)
APP=$(find "$TWEAK/.theos/obj/debug/arm64" -name 'operit-app.dylib' 2>/dev/null | head -1)
[ -n "$SB" ] || { echo "ERROR: operit-sb.dylib not built"; exit 1; }
[ -n "$APP" ] || { echo "ERROR: operit-app.dylib not built"; exit 1; }

# --- stage files into rootless layout (relative to /var/jb) ---
mkdir -p "$FILES/usr/bin" "$FILES/Library/MobileSubstrate/DynamicLibraries" "$FILES/Library/LaunchDaemons"
cp "$DAEMON" "$FILES/usr/bin/operit_agent_daemon"
cp "$SB" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.dylib"
cp "$TWEAK/operit-sb.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-sb.plist"
cp "$APP" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.dylib"
cp "$TWEAK/operit-app.plist" "$FILES/Library/MobileSubstrate/DynamicLibraries/operit-app.plist"
cp "$BASE/files/Library/LaunchDaemons/ai.operit.agent.plist" "$FILES/Library/LaunchDaemons/ai.operit.agent.plist" 2>/dev/null || true

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
