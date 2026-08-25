//! iOS (jailbreak) environment root resolution and capability detection.
//!
//! Rootless-only: this fork targets Dopamine / ElleKit rootless (everything
//! under a fixed `/var/jb` symlink to the procursus root).
//!
//! * `binary_root()` — where mach-o binaries live (daemon / tweak dylib / app):
//!   `/var/jb` (symlink to the procursus root).
//! * `data_root()` — logs / sockets / config / screenshots: the REAL
//!   `/var/mobile/.operit`. The app (containerized UIKitApplication) can write
//!   here but NOT into the procursus tree (/private/preboot), so using the
//!   `/var/jb` prefix for data was an EACCES crash on every fresh install.
//!
//! On non-iOS targets `binary_root()` is `None` and `data_root()` falls back to
//! a portable writable directory so diagnostics survive.

use std::path::{Path, PathBuf};

/// Active jailbreak environment on the device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JailbreakType {
    /// Unknown / undetermined — treated like rootless for safety.
    Unknown,
    /// Dopamine / ElleKit style: everything under a fixed `/var/jb`.
    Rootless,
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
/// On a stock, non-jailbroken, sandboxed app this path is NOT writable; on a
/// rootless device (app unsandboxed via no-sandbox entitlements) it is. This is
/// how we distinguish jailbroken (rootless) from NonJailbreak.
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

/// Detect the active jailbreak environment at runtime.
///
/// Rootless-only: returns `Rootless` when a rootless marker is present
/// (`/var/jb` symlink to a procursus root, current_exe under `/var/jb`, or
/// `/var/jb/usr/lib`), `NonJailbreak` otherwise.
pub fn detect_jailbreak() -> JailbreakType {
    if let Ok(exe) = std::env::current_exe() {
        if exe.starts_with("/var/jb/") {
            return JailbreakType::Rootless;
        }
    }
    if Path::new("/var/jb/usr/lib").exists() {
        return JailbreakType::Rootless;
    }
    if std::fs::symlink_metadata("/var/jb").is_ok() {
        return JailbreakType::Rootless;
    }
    if operit_data_writable() {
        return JailbreakType::Rootless;
    }
    JailbreakType::NonJailbreak
}

/// Create the data root and make sure a non-root process (the Flutter app runs
/// as `mobile`, uid 501) can write inside it.
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
///
/// Rootless-only.
pub fn resolve_roots_for(jb: JailbreakType) -> Roots {
    match jb {
        JailbreakType::Rootless | JailbreakType::Unknown => Roots {
            // binary_root is /var/jb: on rootless Dopamine this is a *symlink to
            // the procursus root* (e.g. /private/preboot/.../dopamine-.../procursus),
            // so mach-o we stage lands under /var/jb/usr/bin etc.
            binary: Some(PathBuf::from("/var/jb")),
            // data_root is the REAL /var/mobile/.operit. On Dopamine rootless
            // /var/jb/var is procursus's OWN var (a different physical
            // directory — verified by inode on-device), NOT a remap of the
            // real /var/mobile. A containerized app process cannot write into
            // the procursus tree (/private/preboot) and hits EACCES; the
            // launchd daemon (no container) can, which masked the bug. The
            // real /var/mobile/.operit is writable by mobile and is where the
            // app's launch.log already lands. App + daemon + tweak all resolve
            // data_root() to this same physical path.
            data: PathBuf::from("/var/mobile/.operit"),
        },
        JailbreakType::NonJailbreak => Roots {
            binary: None,
            data: portable_data_dir(),
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
/// On rootless Dopamine `/var/jb` is a symlink to the procursus root, so
/// `/var/jb/usr/bin` is where the terminal PATH finds binaries.
pub fn binary_root() -> Option<PathBuf> {
    resolve_roots().binary
}

#[cfg(not(target_os = "ios"))]
fn portable_data_dir() -> PathBuf {
    // Off-device diagnostics: use a real, writable directory.
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
// ---------------------------------------------------------------------------

pub trait CapabilitiesProvider {
    fn jailbreak_type(&self) -> JailbreakType;
    fn is_jailbroken(&self) -> bool;
    fn binary_root(&self) -> Option<PathBuf>;
    fn data_root(&self) -> PathBuf;
    fn can_inject_tweaks(&self) -> bool;
    fn can_hide_jailbreak(&self) -> bool;
}

/// Dopamine / ElleKit (the only environment this fork ships).
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
        PathBuf::from("/var/mobile/.operit")
    }
    fn can_inject_tweaks(&self) -> bool {
        true
    }
    fn can_hide_jailbreak(&self) -> bool {
        false
    }
}

/// Non-jailbroken device fallback.
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
        JailbreakType::NonJailbreak => Box::new(NonJailbreakProvider),
        _ => Box::new(RootlessProvider),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rootless_roots() {
        let r = resolve_roots_for(JailbreakType::Rootless);
        assert_eq!(r.binary, Some(PathBuf::from("/var/jb")));
        assert_eq!(r.data, PathBuf::from("/var/mobile/.operit"));
    }

    #[test]
    fn non_jailbreak_has_no_binary_root() {
        let r = resolve_roots_for(JailbreakType::NonJailbreak);
        assert!(r.binary.is_none());
    }
}
