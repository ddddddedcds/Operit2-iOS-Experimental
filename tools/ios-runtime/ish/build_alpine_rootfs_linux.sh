#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/../../.." && pwd)"
downloads_dir="$script_dir/downloads"
work_dir="$script_dir/build/rootfs"
rootfs_path="$repo_dir/apps/flutter/app/ios/Runner/ish-root.tar.gz"
root_archive="$downloads_dir/ish-root-appstore-apk.tar.gz"
apk_static_dir="$work_dir/apk-static"
root_dir="$work_dir/root"

# A2: the iSH guest is aarch64, so the rootfs must contain aarch64 Linux
# userspace binaries. x86/i386 binaries cannot execute under the arm64 guest,
# so the bridge's do_execve("/bin/sh") would fail with exec format error.
# We bootstrap from the official Alpine aarch64 minirootfs and layer the
# interpreter packages on top with apk.static (which runs on the x86_64 Linux
# build host and installs aarch64 packages via --arch aarch64).
root_url="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/aarch64/alpine-minirootfs-3.19.1-aarch64.tar.gz"
root_sha256="7ef5eef3a5b1d198dfb1610cde1ef5b0755ff5d838fb1e5e1b9f42b59214820f"
repository_base="https://dl-cdn.alpinelinux.org/alpine/v3.19"
repository_arch="aarch64"
host_arch="x86_64"
uv_version="0.12.1"
uv_archive="uv-aarch64-unknown-linux-musl.tar.gz"
uv_url="https://github.com/astral-sh/uv/releases/download/$uv_version/$uv_archive"
uv_sha256="ce218dad9eb48a39dd86160bec6291fac7275f20a9cabcc4bc10dd2c757208f8"
pnpm_version="10.12.1"
pnpm_archive="pnpm-$pnpm_version.tgz"
pnpm_url="https://registry.npmjs.org/pnpm/-/$pnpm_archive"
pnpm_sha256="889bac470ec93ccc3764488a19d6ba8f9c648ad5e50a9a6e4be3768a5de387a3"

packages=(
    bash
    python3
    py3-pip
    nodejs
    npm
    ca-certificates
)

# Downloads one artifact and verifies its SHA-256 digest.
download_checked() {
    local url="$1"
    local output="$2"
    local sha256="$3"

    mkdir -p "$(dirname "$output")"
    curl --http1.1 --noproxy '*' -fL --retry 3 --retry-all-errors -o "$output" "$url"
    printf '%s  %s\n' "$sha256" "$output" | sha256sum -c -
}

# Reads one APKINDEX entry for a host-native Alpine package.
apk_index_record() {
    local package_name="$1"
    local index_path="$downloads_dir/APKINDEX-main-$host_arch.tar.gz"

    curl --http1.1 --noproxy '*' -fL --retry 3 --retry-all-errors \
        -o "$index_path" \
        "$repository_base/main/$host_arch/APKINDEX.tar.gz"
    tar -xzO -f "$index_path" APKINDEX | awk -v package_name="$package_name" '
        BEGIN { RS = "" }
        found != 1 && $0 ~ ("(^|\\n)P:" package_name "(\\n|$)") {
            print
            found = 1
        }
    '
}

# Reads a named field from an APKINDEX package entry.
record_value() {
    local record="$1"
    local key="$2"

    awk -F: -v key="$key" '$1 == key && found != 1 { print substr($0, length(key) + 2); found = 1 }' <<< "$record"
}

# Prepares the host-native Alpine APK client used to populate the iSH rootfs.
install_apk_static() {
    local record
    local version
    local archive_name
    local archive_path

    mkdir -p "$downloads_dir"
    record="$(apk_index_record apk-tools-static)"
    version="$(record_value "$record" V)"
    test -n "$version"

    archive_name="apk-tools-static-$version.apk"
    archive_path="$downloads_dir/$archive_name"
    curl --http1.1 --noproxy '*' -fL --retry 3 --retry-all-errors \
        -o "$archive_path" \
        "$repository_base/main/$host_arch/$archive_name"

    rm -rf "$apk_static_dir"
    mkdir -p "$apk_static_dir"
    tar -xzf "$archive_path" -C "$apk_static_dir" sbin/apk.static
    chmod 755 "$apk_static_dir/sbin/apk.static"
}

# Installs the aarch64-musl uv and uvx binaries for the iSH arm64 guest.
install_uv() {
    local archive_path="$downloads_dir/$uv_archive"
    local extract_dir="$work_dir/uv"

    download_checked "$uv_url" "$archive_path" "$uv_sha256"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive_path" -C "$extract_dir"
    install -m 755 "$extract_dir/${uv_archive%.tar.gz}/uv" "$root_dir/usr/bin/uv"
    install -m 755 "$extract_dir/${uv_archive%.tar.gz}/uvx" "$root_dir/usr/bin/uvx"
}

# Installs the Node-compatible pnpm distribution without requiring an x86 Alpine package.
install_pnpm() {
    local archive_path="$downloads_dir/$pnpm_archive"
    local pnpm_directory="$root_dir/usr/lib/node_modules/pnpm"

    download_checked "$pnpm_url" "$archive_path" "$pnpm_sha256"
    rm -rf "$pnpm_directory"
    mkdir -p "$pnpm_directory"
    tar -xzf "$archive_path" -C "$pnpm_directory" --strip-components=1
    cat > "$root_dir/usr/bin/pnpm" <<'EOF'
#!/bin/sh
exec /usr/bin/node /usr/lib/node_modules/pnpm/bin/pnpm.cjs "$@"
EOF
    chmod 755 "$root_dir/usr/bin/pnpm"
}

# Writes the shared Alpine user environment into the iSH rootfs.
write_rootfs_config() {
    cat > "$root_dir/etc/apk/repositories" <<EOF
$repository_base/main
$repository_base/community
EOF

    mkdir -p \
        "$root_dir/dev" \
        "$root_dir/proc" \
        "$root_dir/sys" \
        "$root_dir/tmp" \
        "$root_dir/sdcard" \
        "$root_dir/storage" \
        "$root_dir/host-root" \
        "$root_dir/home/operit" \
        "$root_dir/etc/profile.d"
    chmod 1777 "$root_dir/tmp"

    cat > "$root_dir/etc/profile.d/operit.sh" <<'EOF'
export HOME=/home/operit
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
    printf 'operit-ios-ish\n' > "$root_dir/etc/hostname"
    printf '%s\n' "$repository_arch" > "$root_dir/etc/operit-ios-ish-arch"
    printf '%s\n' "$repository_base" > "$root_dir/etc/operit-alpine-repository"
}

# Builds the iSH aarch64 Alpine rootfs with the interpreter packages.
build_rootfs() {
    mkdir -p "$downloads_dir" "$work_dir" "$(dirname "$rootfs_path")"
    download_checked "$root_url" "$root_archive" "$root_sha256"

    rm -rf "$root_dir"
    mkdir -p "$root_dir"
    tar -xzf "$root_archive" -C "$root_dir"
    write_rootfs_config

    # The minirootfs already carries a populated apk database, so we add the
    # extra interpreter packages on top (no --initdb, which would wipe the db).
    env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u http_proxy -u https_proxy -u all_proxy \
        "$apk_static_dir/sbin/apk.static" \
        --root "$root_dir" \
        --arch "$repository_arch" \
        --keys-dir "$root_dir/etc/apk/keys" \
        --repositories-file "$root_dir/etc/apk/repositories" \
        --no-cache \
        --no-scripts \
        add "${packages[@]}"
    install_uv
    install_pnpm

    rm -rf "$root_dir/var/cache/apk"
    mkdir -p "$root_dir/var/cache/apk"
    tar --numeric-owner --sort=name --mtime='UTC 2026-01-01' -cf - -C "$root_dir" . | gzip -n > "$rootfs_path"
}

install_apk_static
build_rootfs
