#!/bin/bash
# package_0.3.37.sh — assemble operit2-ios_0.3.37 .deb once the CI Runner.app is downloaded.
#
# What it does:
#   1. Rebuild operit_agent_daemon (aarch64-apple-ios) so it includes the host-wide
#      error logging (commit 632e924e) — writes every HostError to
#      /var/jb/var/mobile/.operit/operit-error.log on device.
#   2. Run build_deb.sh, which stages the frontend app from APP_SRC, copies the
#      (already-built) daemon + theos tweak dylibs, and packs packdeb.py ->
#      operit2-ios_0.3.37_iphoneos-arm64.deb
#
# Usage:
#   ./package_0.3.37.sh /path/to/Runner.app
#   or: APP_SRC=/path/to/Runner.app ./package_0.3.37.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS="$SCRIPT_DIR/.."

APP_SRC="${1:-$APP_SRC}"
if [ -z "$APP_SRC" ]; then
  echo "Usage: $0 /path/to/Runner.app"
  echo "  or: APP_SRC=/path/to/Runner.app $0"
  exit 1
fi
if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: Runner.app not found: $APP_SRC"
  exit 1
fi

echo "== frontend app: $APP_SRC =="

# 1) rebuild daemon (cheap insurance it matches source / has error logging)
echo "== rebuilding operit_agent_daemon (aarch64-apple-ios) =="
( cd "$IOS" && cargo build --release --target aarch64-apple-ios --bin operit_agent_daemon )

# 2) assemble the .deb (build_deb.sh reads APP_SRC)
echo "== assembling deb (0.3.37) =="
APP_SRC="$APP_SRC" exec bash "$SCRIPT_DIR/build_deb.sh"
