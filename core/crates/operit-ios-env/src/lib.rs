//! iOS (jailbreak) environment root resolution and capability detection.
//!
//! Replaces hardcoded `/var/jb` literals across the iOS host, daemon, terminal
//! and Flutter bridge with runtime-resolved roots:
//!
//! * `binary_root()` — where mach-o binaries live (daemon / tweak dylib / app).
//!   On roothide this MUST NOT be under `/var` or `/tmp` (hard constraint from
//!   the roothide loader; binaries placed there are rejected at load time).
//! * `data_root()` — where logs / sockets / config / screenshots live. The real
//!   `/var/mobile/.operit` is writable even on roothide (it is data, not a
//!   mach-o binary, so the `/var` ban does not apply).
//!
//! On non-iOS targets `binary_root()` is `None` and `data_root()` falls back to
//! a portable directory. The legacy code wrote to `/var/jb` off-device, which
//! silently failed as a non-root user; we now use a real, writable location so
//! diagnostics survive.

use std::path::{Path, PathBuf};

/// Active jailbreak environment on the device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JailbreakType {
    /// Unknown / undetermined — treated like rootless for safety.
    Unknown,
    /// Dopamine / ElleKit style: everything under a fixed `/var/jb`.
    Rootless,
    /// roothide (Dopamine2-roothide / relaxin): random jbroot injected via the
    /// `JBROOT` environment variable; mach-o must avoid `/var` and `/tmp`.
    RootHide,
    /// No jailbreak: daemon / tweak are absent; only the local sandbox works.
    NonJailbreak,
}

/// Resolved filesystem roots for the current environment.
#[derive(Debug, Clone)]
pub struct Roots {
    /// mach-o binary root. `None` when binaries cannot be placed (non-jb).
    pub binary: Option<PathBuf>,
    /// data root (logs / sockets / config / screens). Always present.
    pub data: PathBuf,
}

impl Roots {
    pub fn data(&self) -> &Path {
        &self.data
    }
    pub fn binary(&self) -> Option<&Path> {
        self.binary.as_deref()
    }
}

/// Test whether this process can write to `/var/mobile/.operit`.
///
/// On roothide the app runs unsandboxed inside the jbroot container, so this
/// path is writable and resolves to the (per-process-remapped) jbroot data dir.
/// On a stock, non-jailbroken, sandboxed app this path is NOT writable, which is
/// how we distinguish roothide from plain NonJailbreak. (TrollStore is
/// intentionally out of scope, so "unsandboxed + writable" is unambiguous.)
///
/// We deliberately do NOT probe the `.jbroot-*` / `/.jbroot` markers: those live
/// in the *real-root* filesystem view and are invisible to the jbroot-injected
/// app, which is exactly why the old marker-based detection silently fell
/// through to NonJailbreak on roothide.
fn operit_data_writable() -> bool {
    let p = Path::new("/var/mobile/.operit");
    if std::fs::create_dir_all(p).is_err() {
        return false;
    }
    // If we are root and just created it, leave it writable for the app (mobile).
    relax_dir_permissions(p);
    let probe = p.join(".writetest");
    match std::fs::write(&probe, b"x") {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            true
        }
        Err(_) => false,
    }
}

/// Physical jbroot prefix of the CURRENT executable, e.g.
/// `/var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F`.
///
/// `None` when this binary was not installed by roothide.
///
/// This is the authoritative roothide test: roothide installs the whole
/// jailbreak tree inside `/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`,
/// so every binary it ships (app, daemon, tweak dylib) carries that segment in
/// its own path. Verified on device:
///   `/var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F/Applications/Runner.app/Runner`
pub fn self_jbroot_prefix() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let s = exe.to_string_lossy();
    let idx = s.find("/.jbroot-")?;
    let after = &s[idx + 1..];
    let end = after.find('/').map(|i| idx + 1 + i).unwrap_or(s.len());
    Some(PathBuf::from(&s[..end]))
}

/// True when `path` is a symbolic link (without following it).
fn is_symlink(path: &str) -> bool {
    std::fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

/// Locate the roothide jbroot container prefix WITHOUT relying on our own
/// executable path.
///
/// roothide installs every jailbreak file (app, daemon, dylib, frameworks)
/// under `/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`. An app/tweak can
/// read its own `.jbroot-` segment from `current_exe()` / `Bundle.main`, but a
/// daemon's `current_exe()` is REMAPPED to `/usr/bin` by roothide (the segment
/// is hidden), so `self_jbroot_prefix()` returns `None` for daemons. We discover
/// the prefix by scanning that well-known directory instead.
fn scan_jbroot_prefix() -> Option<PathBuf> {
    let base = Path::new("/var/containers/Bundle/Application/");
    let entries = std::fs::read_dir(base).ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let s = name.to_string_lossy();
        if s.starts_with(".jbroot-") {
            return Some(entry.path());
        }
    }
    None
}

/// Detect the active jailbreak environment at runtime.
///
/// Resolution order (NEVER test bare `/var/jb` existence as "rootless" — see
/// below):
/// 1. our own path contains `/.jbroot-` ⇒ roothide (app / tweak / dylib).
/// 2. `/var/jb` is a SYMLINK ⇒ roothide. On roothide `/var/jb` is a compat-layer
///    symlink pointing at `/` (so `/var/jb/usr/lib` *does* exist there); on
///    rootless `/var/jb` is a real directory. This is the reliable daemon test.
/// 3. `/var/jb/usr/lib` exists AND `/var/jb` is a real directory ⇒ rootless.
/// 4. `/var/mobile/.operit` writable ⇒ jailbroken with unknown flavour, treated
///    as roothide (unsandboxed).
/// 5. Otherwise ⇒ non-jailbreak (local sandbox only).
///
/// WHY NOT `Path::new("/var/jb/usr/lib").exists()` alone?
/// On a real roothide device `/var/jb` is a symlink to `/`, so `/var/jb/usr/lib`
/// EXISTS too — that test alone mis-detects roothide as rootless, which then
/// points the daemon's data root at the wrong physical directory and breaks the
/// app↔daemon shared data dir (config / logs / tool packages). A detection rule
/// must not be falsifiable by the thing it detects.
pub fn detect_jailbreak() -> JailbreakType {
    if self_jbroot_prefix().is_some() {
        return JailbreakType::RootHide;
    }
    if is_symlink("/var/jb") {
        return JailbreakType::RootHide;
    }
    if let Ok(exe) = std::env::current_exe() {
        if exe.starts_with("/var/jb/") {
            return JailbreakType::Rootless;
        }
    }
    if Path::new("/var/jb/usr/lib").exists() {
        return JailbreakType::Rootless;
    }
    if operit_data_writable() {
        return JailbreakType::RootHide;
    }
    JailbreakType::NonJailbreak
}

/// Create the data root and make sure a non-root process (the Flutter app runs
/// as `mobile`, uid 501) can write inside it.
///
/// The daemon runs as root under launchd; anything it creates first would
/// otherwise be `root`-owned `755`, and the app could not create its log/client
/// subdirectories. That exact situation white-screened the app on roothide.
/// Widening the mode is enough (the app only needs to create its own children)
/// and needs no libc dependency.
pub fn ensure_data_root() -> PathBuf {
    let root = data_root();
    let _ = std::fs::create_dir_all(&root);
    relax_dir_permissions(&root);
    root
}

/// chmod 0o777 a directory, best effort. No-op on non-unix.
pub fn relax_dir_permissions(dir: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(meta) = std::fs::metadata(dir) {
            let mut perm = meta.permissions();
            if perm.mode() & 0o777 != 0o777 {
                perm.set_mode(0o777);
                let _ = std::fs::set_permissions(dir, perm);
            }
        }
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// Resolve the two roots for an explicit jailbreak type.
pub fn resolve_roots_for(jb: JailbreakType) -> Roots {
    match jb {
        JailbreakType::Rootless => Roots {
            // binary_root is /var/jb: on rootless Dopamine this is a *symlink to
            // the procursus root* (e.g. /private/preboot/.../dopamine-.../procursus),
            // so mach-o we stage lands under /var/jb/usr/bin etc.
            binary: Some(PathBuf::from("/var/jb")),
            // data_root is /var/jb/var/mobile/.operit. KEY difference from roothide:
            // rootless does NOT remap /var per-process — the app AND the daemon
            // BOTH run in the REAL-ROOT view (no jbroot injection). So for everyone
            // `/var/jb` resolves to the same procursus tree, and inside procursus
            // /var/mobile is remapped to the real /var/mobile, so this path
            // physically lands at the real /var/mobile/.operit — writable by mobile.
            // Because app and daemon share ONE filesystem view, the on-disk
            // config.plist / logs / tool packages are visible to BOTH with no
            // loopback TCP needed (unlike roothide, where the per-process /var
            // remap splits them and we must push config over 127.0.0.1:8890).
            // Do NOT "simplify" this to /var/mobile/.operit: it is equivalent on
            // rootless, but keeping the /var/jb prefix makes the binary/data roots
            // consistent and matches where the deb actually stages files.
            data: PathBuf::from("/var/jb/var/mobile/.operit"),
        },
        JailbreakType::RootHide => Roots {
            // Prefer our own install path: launchd does NOT pass JBROOT to the
            // daemon, so the env var is frequently absent where it matters.
            // For daemons current_exe() is remapped to /usr/bin by roothide, so
            // fall back to scanning the jbroot container directory.
            binary: self_jbroot_prefix()
                .or_else(scan_jbroot_prefix)
                .or_else(|| {
                    std::env::var("JBROOT")
                        .ok()
                        .filter(|s| !s.is_empty())
                        .map(PathBuf::from)
                }),
            // The Flutter app (jbroot-injected) resolves "/var/mobile/.operit" to
            // the jbroot view, which physically lands at
            // .jbroot-XXX/var/mobile/.operit. A daemon runs in the REAL-ROOT view
            // where "/var/mobile/.operit" is a DIFFERENT directory, so it must
            // address the same physical location explicitly via the jbroot
            // prefix. Otherwise the app and daemon write to two separate
            // directories and shared data (config / logs / tool packages) splits.
            data: scan_jbroot_prefix()
                .map(|p| p.join("var/mobile/.operit"))
                .unwrap_or_else(|| PathBuf::from("/var/mobile/.operit")),
        },
        JailbreakType::NonJailbreak => Roots {
            binary: None,
            data: portable_data_dir(),
        },
        JailbreakType::Unknown => Roots {
            binary: Some(PathBuf::from("/var/jb")),
            data: PathBuf::from("/var/jb/var/mobile/.operit"),
        },
    }
}

/// Resolve the two roots for the current environment. Cheap; callers may cache.
pub fn resolve_roots() -> Roots {
    resolve_roots_for(detect_jailbreak())
}

/// Convenience: the data root path.
pub fn data_root() -> PathBuf {
    resolve_roots().data
}

/// Convenience: the binary root, or `None` when mach-o cannot be placed.
///
/// On rootless Dopamine `/var/jb` is a *symlink to the procursus root*
/// (e.g. `/private/preboot/.../procursus`), so `detect_jailbreak()`'s
/// "any `/var/jb` symlink ⇒ RootHide" rule mis-classifies it and yields
/// `binary_root() == None`. That strips `/var/jb/usr/bin` from the terminal
/// PATH (every command → "command not found"). Detect the rootless binary
/// root directly via the symlink *target*: roothide targets `/`, rootless
/// targets the procursus directory.
pub fn binary_root() -> Option<PathBuf> {
    // Prefer the classified root (handles roothide jbroot prefix correctly and
    // is byte-for-byte identical to the old behaviour there).
    if let Some(bin) = resolve_roots().binary {
        return Some(bin);
    }
    // Fallback: rootless Dopamine where `/var/jb` is a procursus symlink.
    if is_symlink("/var/jb") {
        if let Ok(target) = std::fs::read_link("/var/jb") {
            if target.to_string_lossy() != "/" {
                return Some(PathBuf::from("/var/jb"));
            }
        }
    } else if Path::new("/var/jb/usr/lib").exists() {
        return Some(PathBuf::from("/var/jb"));
    }
    None
}

#[cfg(not(target_os = "ios"))]
fn portable_data_dir() -> PathBuf {
    // Off-device the legacy code wrote to /var/jb (which fails silently as a
    // non-root user). Use a real, writable directory so diagnostics survive.
    std::env::temp_dir().join("operit")
}

#[cfg(target_os = "ios")]
fn portable_data_dir() -> PathBuf {
    // Non-jailbroken iOS: prefer the app's writable Documents directory.
    if let Ok(home) = std::env::var("HOME") {
        return PathBuf::from(home).join("Documents").join(".operit");
    }
    PathBuf::from("/var/mobile/.operit")
}

// ---------------------------------------------------------------------------
// CapabilitiesProvider — iOS-internal environment abstraction.
//
// Orthogonal to the upstream I1–I8 contract: upstream only sees stable host
// capabilities and never learns whether the device is rootless / roothide /
// non-jailbroken. Each environment provides its own Provider.
// ---------------------------------------------------------------------------

pub trait CapabilitiesProvider {
    fn jailbreak_type(&self) -> JailbreakType;
    fn is_jailbroken(&self) -> bool;
    fn binary_root(&self) -> Option<PathBuf>;
    fn data_root(&self) -> PathBuf;
    fn can_inject_tweaks(&self) -> bool;
    fn can_hide_jailbreak(&self) -> bool;
}

/// Dopamine / ElleKit (the current default).
pub struct RootlessProvider;
impl CapabilitiesProvider for RootlessProvider {
    fn jailbreak_type(&self) -> JailbreakType {
        JailbreakType::Rootless
    }
    fn is_jailbroken(&self) -> bool {
        true
    }
    fn binary_root(&self) -> Option<PathBuf> {
        Some(PathBuf::from("/var/jb"))
    }
    fn data_root(&self) -> PathBuf {
        PathBuf::from("/var/jb/var/mobile/.operit")
    }
    fn can_inject_tweaks(&self) -> bool {
        true
    }
    fn can_hide_jailbreak(&self) -> bool {
        false
    }
}

/// Dopamine2-roothide / relaxin.
pub struct RootHideProvider;
impl CapabilitiesProvider for RootHideProvider {
    fn jailbreak_type(&self) -> JailbreakType {
        JailbreakType::RootHide
    }
    fn is_jailbroken(&self) -> bool {
        true
    }
    fn binary_root(&self) -> Option<PathBuf> {
        self_jbroot_prefix().or_else(|| {
            std::env::var("JBROOT")
                .ok()
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
        })
    }
    fn data_root(&self) -> PathBuf {
        // Must match the Flutter app's jbroot-view /var/mobile/.operit, which
        // physically resolves to .jbroot-XXX/var/mobile/.operit. Address that
        // same physical directory explicitly so daemon-written data (config /
        // logs / tool packages) is visible to the app.
        scan_jbroot_prefix()
            .map(|p| p.join("var/mobile/.operit"))
            .unwrap_or_else(|| PathBuf::from("/var/mobile/.operit"))
    }
    fn can_inject_tweaks(&self) -> bool {
        true
    }
    fn can_hide_jailbreak(&self) -> bool {
        true
    }
}

/// No jailbreak: daemon / tweak are absent; only the local sandbox works.
pub struct NonJailbreakProvider;
impl CapabilitiesProvider for NonJailbreakProvider {
    fn jailbreak_type(&self) -> JailbreakType {
        JailbreakType::NonJailbreak
    }
    fn is_jailbroken(&self) -> bool {
        false
    }
    fn binary_root(&self) -> Option<PathBuf> {
        None
    }
    fn data_root(&self) -> PathBuf {
        portable_data_dir()
    }
    fn can_inject_tweaks(&self) -> bool {
        false
    }
    fn can_hide_jailbreak(&self) -> bool {
        false
    }
}

/// Select the provider for the active environment.
pub fn provider() -> Box<dyn CapabilitiesProvider> {
    match detect_jailbreak() {
        JailbreakType::Rootless => Box::new(RootlessProvider),
        JailbreakType::RootHide => Box::new(RootHideProvider),
        JailbreakType::NonJailbreak => Box::new(NonJailbreakProvider),
        JailbreakType::Unknown => Box::new(RootlessProvider),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rootless_roots() {
        let r = resolve_roots_for(JailbreakType::Rootless);
        assert_eq!(r.binary, Some(PathBuf::from("/var/jb")));
        assert_eq!(r.data, PathBuf::from("/var/jb/var/mobile/.operit"));
    }

    #[test]
    fn non_jailbreak_has_no_binary_root() {
        let r = resolve_roots_for(JailbreakType::NonJailbreak);
        assert!(r.binary.is_none());
    }
}
