#!/usr/bin/env bash
set -Eeuo pipefail

# Reports the command and source line that caused the iSH build to terminate.
report_build_failure() {
    local exit_code="$?"

    printf 'iSH build failed at %s:%s while running: %s\n' \
        "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}" "$BASH_COMMAND" >&2
    exit "$exit_code"
}

trap report_build_failure ERR

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../../.." && pwd)"
source_dir="$script_dir/sources/ish"
runner_dir="$repo_dir/apps/flutter/app/ios/Runner"

configuration="${1:?missing Xcode configuration}"
sdk_name="${2:?missing Xcode SDK name}"
platform_name="${3:?missing Xcode platform name}"
architectures="${4:?missing Xcode architectures}"

# --- Toolchain bootstrap -----------------------------------------------------
# Xcode run-script build phases often run with a minimal PATH
# (/usr/bin:/bin:/usr/sbin:/sbin), which does NOT include Homebrew or any
# user-installed meson/ninja/lld. CI installs the iSH toolchain via
# `brew install llvm lld meson ninja` (ios-app-package-build.yml). Prepend the
# Homebrew bins (and our managed Python venv, for local/dev runs) so this script
# locates meson/ninja/clang/lld regardless of the PATH Xcode hands us.
for brew_prefix in /usr/local /opt/homebrew; do
  if [ -d "$brew_prefix/opt/llvm/bin" ]; then
    export PATH="$brew_prefix/opt/llvm/bin:$PATH"
  fi
  if [ -d "$brew_prefix/opt/lld/bin" ]; then
    export PATH="$brew_prefix/opt/lld/bin:$PATH"
  fi
  if [ -d "$brew_prefix/bin" ]; then
    export PATH="$brew_prefix/bin:$PATH"
  fi
done
# Local/dev convenience: prefer a project-managed venv meson if present.
if [ -x "$script_dir/../../../.venv/bin/meson" ]; then
  export PATH="$script_dir/../../../.venv/bin:$PATH"
fi

for tool in meson ninja clang; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'iSH build error: required tool "%s" not found in PATH (%s)\n' \
      "$tool" "$PATH" >&2
    exit 1
  fi
done
# VDSO needs lld; warn (not fatal) if absent — the kernel ships a built-in
# aarch64 VDSO and the script only copies the external one as a fallback.
if ! command -v ld.lld >/dev/null 2>&1; then
  printf 'iSH build warning: ld.lld not found; external VDSO will be skipped (non-fatal)\n' >&2
fi

# Defined after arg parsing: configuration/platform_name are only known here.
build_products_dir="$repo_dir/apps/flutter/app/apple/ish-build/${configuration}-${platform_name}"

# A2: we build the iSH userspace-emulator static libraries with meson+ninja
# (kernel=ish + arm64 guest). There is no separate "linux" meson build dir
# anymore, and the old kernel=linux xcodebuild targets are gone.
python3 "$script_dir/fetch_sources.py"

# The old kernel=linux patch (0001-operit-managed-runtime-mount.patch) does not
# apply to kernel=ish, which has no live host-directory bind-mount. Skip it.
# if [ -d "$script_dir/patches" ]; then
#   for patch_path in "$script_dir"/patches/*.patch; do
#     [ -e "$patch_path" ] && /usr/bin/patch -d "$source_dir" -p1 -i "$patch_path"
#   done
# fi

guest_arch="${architectures%% *}"
[ -z "$guest_arch" ] && guest_arch="arm64"

ios_sdk="$(xcrun --sdk "$sdk_name" --show-sdk-path)"

build_dir="$source_dir/build-ios"
cross_file="$build_dir/ios-cross.txt"
mkdir -p "$build_dir"

cat > "$cross_file" << EOF
[binaries]
c = ['clang', '-arch', '$guest_arch', '-isysroot', '$ios_sdk', '-miphoneos-version-min=14.0']
ar = 'ar'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$ios_sdk/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$ios_sdk'
library_dirs = ['$ios_sdk/usr/lib']
EOF

# Configure once; reconfigure is a no-op when already configured.
if [ ! -f "$build_dir/build.ninja" ]; then
  # Pass the source directory explicitly: the script does not cd into it, and
  # build-ios is pre-created above, so meson would otherwise treat build-ios
  # as the source tree and fail to find meson.build.
  meson setup "$build_dir" "$source_dir" \
    --cross-file "$cross_file" \
    --buildtype=release \
    -Dlog="" \
    -Dlog_handler=nslog \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dguest_arch=arm64
    # guest_arch IS a real meson option in the OpenMinis/ish-arm64 tree
    # (meson_options.txt: guest_arch in ['x86','arm64']). It drives -DGUEST_ARM64
    # (meson.build:25-26) and which vdso/arm64 vs vdso/x86 is built. Must be
    # arm64 to match the aarch64 Alpine rootfs.
fi

ninja -C "$build_dir" libish.a libish_emu.a libfakefs.a
# VDSO is optional; the kernel ships a built-in aarch64 VDSO, but we also copy
# the external one into the app bundle as a fallback.
ninja -C "$build_dir" vdso/arm64/libvdso.so.elf \
  || echo "iSH VDSO build failed (non-fatal; built-in VDSO will be used)"

mkdir -p "$build_products_dir"

# --- fakefs_import (tools/fakefs.c) + libarchive ----------------------------
# The bridge (IshTerminalBridge.m) imports the bundled root archive via
# fakefs_import(). That function lives in tools/fakefs.c, which the kernel=ish
# meson build does NOT compile (libfakefs.a only contains fs/fake-db.c,
# fs/fake-migrate.c, fs/fake-rebuild.c). Upstream iSH compiles tools/fakefs.c
# directly into the iOS app target and links its own libarchive.xcodeproj. We
# replicate that here: build libarchive via its embedded Xcode project, compile
# tools/fakefs.c with clang, and append the object into libfakefs.a so the
# bridge links against it with no pbxproj changes.
libarchive_src="$source_dir/deps/libarchive.xcodeproj"
if [ -d "$libarchive_src" ]; then
  echo "Building libarchive (iSH deps) for fakefs_import"
  xcodebuild -project "$libarchive_src" -target libarchive \
    -sdk "$sdk_name" -configuration "$configuration" -arch arm64 \
    SYMROOT="$build_dir/libarchive-sym" >/dev/null 2>&1 \
    || { echo "iSH libarchive build failed" >&2; exit 1; }
  libarchive_a="$(find "$build_dir/libarchive-sym" -name 'libarchive.a' | head -1)"
  if [ -z "$libarchive_a" ]; then
    echo "iSH error: libarchive.a not produced" >&2
    exit 1
  fi
  cp "$libarchive_a" "$build_products_dir/libarchive.a"
  # Compile tools/fakefs.c against the iSH tree + libarchive headers.
  fakefs_o="$build_dir/fakefs.o"
  xcrun --sdk "$sdk_name" clang -x c -std=gnu11 \
    -DISH_INTERNAL -DGUEST_ARM64 \
    -arch arm64 -isysroot "$ios_sdk" -miphoneos-version-min=14.0 \
    -I "$source_dir" -I "$source_dir/deps/libarchive/libarchive" \
    -c "$source_dir/tools/fakefs.c" -o "$fakefs_o"
  # Append fakefs.o into a copy of libfakefs.a (kept in the products dir).
  cp "$build_dir/libfakefs.a" "$build_products_dir/libfakefs.a"
  xcrun --sdk "$sdk_name" libtool -static -arch_only arm64 \
    -o "$build_products_dir/libfakefs.a" "$build_products_dir/libfakefs.a" "$fakefs_o"
  echo "iSH fakefs_import support built (libfakefs.a += tools/fakefs.o)"
else
  echo "iSH warning: deps/libarchive.xcodeproj missing; fakefs_import will be unresolved" >&2
  cp "$build_dir/libfakefs.a" "$build_products_dir/libfakefs.a"
fi

# --- Deduplicate arm64 gadget symbols (upstream iSH bug) ---------------------
# The OpenMinis/ish-arm64 tree compiles BOTH gadgets-aarch64/bits.S and
# gadgets-aarch64/math.S into libish_emu.a, and both define the four gadgets
# rev32 / sxtw / uxtb / uxth. With -force_load the linker sees 4 duplicate
# symbols and fails. The implementations are functionally identical; we keep
# bits.S's copies and rebuild math.S without the 4 blocks, then swap the member
# inside libish_emu.a. This is a build-time workaround only — no upstream
# source is modified (the tree is re-cloned by fetch_sources.py every build).
math_s="$source_dir/asbestos/guest-arm64/gadgets-aarch64/math.S"
if [ -f "$math_s" ]; then
  # Line ranges of the duplicate .gadget blocks in math.S (pinned commit).
  #   sxtw 1420-1425, uxth 1454-1464, uxtb 1465-1482, rev32 3415-3435
  math_dedup_s="$build_dir/math_dedup.S"
  sed -e '1420,1425d' -e '1454,1464d' -e '1465,1482d' -e '3415,3435d' \
    "$math_s" > "$math_dedup_s"
  math_dedup_o="$build_dir/math_dedup.o"
  xcrun --sdk "$sdk_name" clang -x assembler-with-cpp -std=gnu11 \
    -DISH_INTERNAL -DGUEST_ARM64 \
    -arch arm64 -isysroot "$ios_sdk" -miphoneos-version-min=14.0 \
    -I "$source_dir" -I "$source_dir/asbestos/guest-arm64/gadgets-aarch64" \
    -I "$build_dir" -c "$math_dedup_s" -o "$math_dedup_o"
  # Swap the member inside the meson-built libish_emu.a.
  ar d "$build_dir/libish_emu.a" "asbestos_guest-arm64_gadgets-aarch64_math.S.o" 2>/dev/null || true
  ar r "$build_dir/libish_emu.a" "$math_dedup_o"
  echo "iSH gadget dedup done (libish_emu.a: math.S without rev32/sxtw/uxtb/uxth)"
fi

cp "$build_dir/libish.a" "$build_products_dir/"
cp "$build_dir/libish_emu.a" "$build_products_dir/"

if [ -f "$build_dir/vdso/arm64/libvdso.so.elf" ]; then
  cp "$build_dir/vdso/arm64/libvdso.so.elf" "$runner_dir/libvdso.so.elf"
  echo "Copied libvdso.so.elf -> $runner_dir"
fi

# Verifies that one static library exports a required C symbol.
verify_static_library_symbol() {
    local library_name="$1"
    local symbol_name="$2"

    printf 'Verifying iSH static library symbol: %s in %s\n' "$symbol_name" "$library_name"
    xcrun --sdk "$sdk_name" nm -gU "$build_products_dir/$library_name" \
        | awk -v expected="_$symbol_name" '$NF == expected { found = 1 } END { exit !found }'
}

verify_static_library_symbol libish.a mount_root
verify_static_library_symbol libish.a become_first_process
verify_static_library_symbol libish.a become_new_init_child
# task_start is defined in kernel/task.c, which is part of the kernel=ish
# `src` list -> it lands in libish.a, NOT libish_emu.a (that one only holds the
# asbestos emulator, emu_src). Verified against meson.build (kernel=ish branch).
verify_static_library_symbol libish.a task_start

echo "iSH (kernel=ish, arm64 guest) build complete: $build_products_dir"
