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
/// Resolution order:
/// 1. `/var/jb` exists ⇒ rootless (Dopamine / ElleKit).
/// 2. `/var/mobile/.operit` is writable by this process ⇒ roothide. The app is
///    unsandboxed inside the jbroot container, so the path is writable; a plain
///    sandboxed app cannot write there. We deliberately avoid the `.jbroot-*`
///    markers (invisible to the jbroot-injected app).
/// 3. Otherwise ⇒ non-jailbreak (local sandbox only).
pub fn detect_jailbreak() -> JailbreakType {
    if Path::new("/var/jb").exists() {
        return JailbreakType::Rootless;
    }
    if operit_data_writable() {
        return JailbreakType::RootHide;
    }
    JailbreakType::NonJailbreak
}

/// Resolve the two roots for an explicit jailbreak type.
pub fn resolve_roots_for(jb: JailbreakType) -> Roots {
    match jb {
        JailbreakType::Rootless => Roots {
            binary: Some(PathBuf::from("/var/jb")),
            data: PathBuf::from("/var/jb/var/mobile/.operit"),
        },
        JailbreakType::RootHide => Roots {
            binary: std::env::var("JBROOT")
                .ok()
                .filter(|s| !s.is_empty())
                .map(PathBuf::from),
            // roothide: the app (jbroot-injected) and the daemon (system launchd)
            // each resolve "/var/mobile/.operit" to their OWN physical dir. That
            // is fine, because the agent control channel + config now travel over
            // loopback TCP (127.0.0.1:8890), which is shared across the
            // per-process /var remap. No /rootfs anchor is needed.
            data: PathBuf::from("/var/mobile/.operit"),
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
pub fn binary_root() -> Option<PathBuf> {
    resolve_roots().binary
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
        std::env::var("JBROOT")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
    }
    fn data_root(&self) -> PathBuf {
        // See `resolve_roots_for` RootHide branch: the app and daemon exchange
        // the agent channel + config over loopback TCP, so a shared physical dir
        // is not required.
        PathBuf::from("/var/mobile/.operit")
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
