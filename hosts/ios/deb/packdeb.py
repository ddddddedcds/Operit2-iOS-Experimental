#!/usr/bin/env python3
"""Build operit-ios .deb (Mac has no dpkg-deb, so construct the ar package in Python).

Preserves setuid bits from the source tree (any file whose mode has 0o4000).
Computed from files/ + DEBIAN/.
"""
import os, io, tarfile, gzip, stat

ROOT = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(ROOT, "files")
DEBIAN = os.path.join(ROOT, "DEBIAN")
OUT = os.path.join(ROOT, "operit2-ios_0.3.35_iphoneos-arm64.deb")

# Rootless relocation done at PACKAGE time: prefix every data.tar member with
# "var/jb/" so a plain `dpkg -i` (what Sileo/Filza invoke, WITHOUT --root=/var/jb)
# extracts straight into the writable /var/jb tree instead of the read-only real
# "/". This makes the deb installable through Sileo/local-deb the same way repo
# packages do. NOTE: do NOT install with `dpkg --root=/var/jb` anymore — that would
# double-prefix to /var/jb/var/jb. Use plain `sudo dpkg -i` (or Sileo/Filza).
JB_PREFIX = "var/jb/"


def tar_add(tar, path, arcname, mode=None):
    st = os.stat(path)
    ti = tarfile.TarInfo(arcname)
    ti.size = st.st_size
    ti.mtime = int(st.st_mtime)
    ti.uid = 0
    ti.gid = 0
    ti.type = tarfile.REGTYPE
    # preserve full permission bits; explicit mode wins, else source mode as-is
    ti.mode = mode if mode is not None else (st.st_mode & 0o7777)
    with open(path, "rb") as f:
        tar.addfile(ti, f)


def _is_junk(name):
    return name == ".DS_Store" or name.startswith("._")


def make_data_tar():
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
        # GNU format (NOT default PAX): old iOS dpkg rejects PAX type 'x' headers.
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for dp, dns, fns in os.walk(FILES):
                dns[:] = [d for d in dns if not _is_junk(d)]
                darc = os.path.relpath(dp, FILES)
                if darc != ".":
                    st = os.stat(dp)
                    arc_dir = JB_PREFIX + darc
                    if not arc_dir.endswith("/"):
                        arc_dir += "/"
                    ti = tarfile.TarInfo(arc_dir)
                    ti.type = tarfile.DIRTYPE
                    # Normalize dirs to 0755: app-bundle dirs MUST be world-traversable
                    # or the mobile user (which runs the app) cannot open embedded
                    # frameworks like Flutter.framework (a 0700 source dir caused dyld
                    # "Library not loaded" at launch).
                    ti.mode = 0o755
                    ti.uid = 0
                    ti.gid = 0
                    ti.mtime = int(st.st_mtime)
                    tar.addfile(ti)
                for fn in sorted(fns):
                    if _is_junk(fn):
                        continue
                    fp = os.path.join(dp, fn)
                    arc = JB_PREFIX + os.path.relpath(fp, FILES)
                    src_mode = os.stat(fp).st_mode
                    # Normalize file perms: ensure world-readable; if any exec bit is set,
                    # make executable for all (so mobile can load/run app binaries &
                    # frameworks). Preserve setuid/setgid bits from the source.
                    m = src_mode & 0o7777
                    m |= 0o004
                    if m & 0o111:
                        m |= 0o111
                    tar_add(tar, fp, arc, mode=m)
    return buf.getvalue()


def compute_installed_size_kb():
    total = 0
    for dp, dns, fns in os.walk(FILES):
        dns[:] = [d for d in dns if not _is_junk(d)]
        for fn in fns:
            if _is_junk(fn):
                continue
            try:
                total += os.path.getsize(os.path.join(dp, fn))
            except OSError:
                pass
    return max(1, (total + 1023) // 1024)


def make_control_tar():
    # NOTE: intentionally ship NO maintainer scripts (postinst/prerm). On rootless
    # jailbreaks the dpkg admindir/info layout and the absence of /bin/bash|/bin/sh
    # make script execution fail with ENOENT. All setup (app ad-hoc signing, file
    # modes, ownership) is done at build time on macOS, so no postinst is needed.
    items = []
    ctrl = open(os.path.join(DEBIAN, "control"), "rb").read()
    kb = compute_installed_size_kb()
    lines = [l for l in ctrl.split(b"\n") if not l.lower().startswith(b"installed-size:")]
    body = b"\n".join(lines).rstrip() + b"\n"
    ctrl = body + ("Installed-Size: %d\n" % kb).encode()
    items.append(("control", ctrl, 0o644))
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for name, content, mode in items:
                ti = tarfile.TarInfo(name)
                ti.size = len(content)
                ti.mode = mode
                ti.uid = 0
                ti.gid = 0
                tar.addfile(ti, io.BytesIO(content))
    return buf.getvalue()


def ar_pack_custom(out, members):
    """Fallback pure-Python ar writer (SVR4/GNU format)."""
    with open(out, "wb") as f:
        f.write(b"!<arch>\n")
        for name, data in members:
            if len(name) > 15:
                raise ValueError(f"member name too long for classic ar: {name!r}")
            name_field = (name + "/").ljust(16)[:16]
            header = (
                name_field
                + "0".rjust(12)
                + "0".rjust(6)
                + "0".rjust(6)
                + "100644".rjust(8)
                + str(len(data)).rjust(10)
                + "`\n"
            )
            f.write(header.encode("ascii"))
            f.write(data)
            if len(data) % 2:
                f.write(b"\n")


def ar_pack(out, members):
    """Prefer the system `ar` command (BSD format); fall back to custom writer."""
    import tempfile, subprocess, shutil
    if shutil.which("ar") is None:
        ar_pack_custom(out, members)
        return
    tmp = tempfile.mkdtemp(prefix="packdeb_")
    try:
        paths = []
        for name, data in members:
            p = os.path.join(tmp, name)
            with open(p, "wb") as f:
                f.write(data)
            paths.append(p)
        # Remove old archive so `ar rc` creates a fresh one (avoids duplicate members when
        # existing archive uses a different name convention, e.g. trailing '/').
        if os.path.exists(out):
            os.remove(out)
        cmd = ["ar", "rc", out] + paths
        proc = subprocess.run(cmd, capture_output=True)
        if proc.returncode != 0 or not os.path.exists(out):
            print("system ar failed, falling back to custom writer:", proc.stderr.decode().strip())
            ar_pack_custom(out, members)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    data = make_data_tar()
    ctrl = make_control_tar()
    ar_pack(OUT, [("debian-binary", b"2.0\n"), ("control.tar.gz", ctrl), ("data.tar.gz", data)])
    print(f"wrote {OUT}  ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
