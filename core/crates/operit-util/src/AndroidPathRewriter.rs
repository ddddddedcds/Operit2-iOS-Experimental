//! Android path literal rewriting for plugin scripts.
//!
//! Android-only ToolPkgs hardcode Android paths as string literals:
//! `/sdcard/...`, `/storage/emulated/0/...`, `/data/...`, `/mnt/android/...`.
//! On iOS these do not exist, so a plugin that uses them fails. This module
//! rewrites those literals to a sandboxed compatibility directory under the
//! operit2 runtime store — the same target PathMapper uses at runtime — so the
//! plugin's file writes land in a safe, accessible place and its reads resolve
//! consistently.
//!
//! Rewriting is a conservative, order-aware literal prefix replacement (the
//! same idea as RootHidePatcher's sed-based path remap, but applied to plugin
//! JS source before it is compiled by the QuickJS engine). It only touches
//! well-formed Android path prefixes, never other code.

/// Rewrites Android path literals in `source` to the shared VFS mount form.
///
/// `compatRoot` is kept for API compatibility with callers (the physical
/// sandbox root is resolved by PathMapper at runtime). Android-only literals
/// are rewritten to the canonical mount path `/mnt/android/sdcard` — the same
/// VFS form upstream operit uses on Android — so the rewritten plugin is
/// portable across platforms and the physical target is resolved once by
/// PathMapper (`<runtimeRoot>/android-compat/sdcard/...` on iOS).
///
/// `/data` is left as-is: it is a top-level VFS root (`ROOT_DATA`) that
/// PathMapper already maps at runtime.
pub fn rewrite_android_paths(source: &str, compat_root: &str) -> String {
    let _ = compat_root;

    // (android_prefix, vfs_mount_form). `/storage/emulated/0` IS the sdcard, so
    // both collapse onto the canonical `/mnt/android/sdcard` mount.
    let rules: &[(&str, &str)] = &[
        ("/storage/emulated/0", "/mnt/android/sdcard"),
        ("/sdcard", "/mnt/android/sdcard"),
    ];
    replace_path_prefixes(source, rules)
}

/// True when the text right after an Android prefix starts with a path/syntax
/// boundary (or is empty), so `/sdcardfoo` (identifier continuation) is never
/// treated as `/sdcard`.
fn is_path_boundary(after: &str) -> bool {
    after
        .chars()
        .next()
        .map(|c| {
            matches!(
                c,
                '/' | '\'' | '"' | '`' | ' ' | '\t' | '\n' | '\r' | ')' | ']' | '}' | ';' | ','
            )
        })
        .unwrap_or(true) // end of input is a boundary
}

/// Rewrites VFS mount paths inside a shell command to physical host paths.
///
/// Plugin scripts rewritten to the mount form (`/mnt/android/sdcard/...`,
/// top-level `/data/...`) work through the VFS, but commands executed by the
/// native shell bypass the VFS and touch the real filesystem. This maps those
/// mount paths back to the physical compat directory so `find "/mnt/android/
/// sdcard"` etc. actually resolve on iOS.
pub fn rewrite_vfs_mount_paths(command: &str, compat_root: &str) -> String {
    let compat = compat_root.trim_end_matches('/');
    let rules: &[(&str, &str)] = &[
        ("/mnt/android/sdcard", &format!("{compat}/sdcard")),
        ("/data", &format!("{compat}/data")),
    ];
    replace_path_prefixes(command, rules)
}

/// Applies `(prefix, replacement)` rules to `source` in one pass, longest first,
/// with boundary guards so identifiers like `/datafoo` are never matched.
fn replace_path_prefixes(source: &str, rules: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(source.len() + 64);
    let mut rest = source;
    while !rest.is_empty() {
        let mut matched: Option<(usize, &str)> = None;
        for (prefix, replacement) in rules {
            if rest.starts_with(prefix) && is_path_boundary(&rest[prefix.len()..]) {
                matched = Some((prefix.len(), replacement));
                break;
            }
        }
        if let Some((prefix_len, replacement)) = matched {
            out.push_str(replacement);
            rest = &rest[prefix_len..];
        } else {
            let ch = rest.chars().next().unwrap();
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{rewrite_android_paths, rewrite_vfs_mount_paths};

    #[test]
    fn rewrites_sdcard_literal() {
        let src = r#"var P="/sdcard/Download/Operit/x";"#;
        let out = rewrite_android_paths(src, "/var/mobile/.operit/runtime/android-compat");
        assert!(out.contains(r#""/mnt/android/sdcard/Download/Operit/x""#));
    }

    #[test]
    fn rewrites_movie_room_real_snippet() {
        // Real fragments from com-operit-movie-room-v1.0.0 (compressed JS).
        let src = concat!(
            "Tools.Files.write(\"/sdcard/Download/Operit/movie_room_reply.json\",n,!1);",
            "Tools.System.shell(\"mkdir -p /storage/emulated/0/movie_room_upload && cd /storage/emulated/0/movie_room_upload && nohup python3 -m http.server 18888 >/dev/null 2>&1 &\");",
            "var FRAME_DIR=\"/sdcard/Download/Operit/movie_room_frames\";",
            "scan_movies(\"/sdcard\");",
        );
        let compat = "/var/mobile/.operit/runtime/android-compat";
        let out = rewrite_android_paths(src, compat);
        assert!(out.contains(r#""/mnt/android/sdcard/Download/Operit/movie_room_reply.json""#));
        assert!(out.contains("/mnt/android/sdcard/movie_room_upload"));
        assert!(out.contains(r#""/mnt/android/sdcard/Download/Operit/movie_room_frames""#));
        // Bare /sdcard argument (end of string) also rewritten.
        assert!(out.contains(r#""/mnt/android/sdcard");"#));
    }

    #[test]
    fn rewrites_storage_emulated() {
        let src = r#"scan("/storage/emulated/0/movie")"#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains(r#""/mnt/android/sdcard/movie""#));
    }

    #[test]
    fn leaves_data_roots_as_is() {
        // /data is a top-level VFS root (ROOT_DATA) resolved by PathMapper at
        // runtime — the rewriter must NOT touch it.
        let src = r#"a("/data/data/com.x/files")b("/data/local/tmp")"#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains("/data/data/com.x/files"));
        assert!(out.contains("/data/local/tmp"));
        assert_eq!(out, src);
    }

    #[test]
    fn does_not_break_identifier_suffix() {
        // /sdcardfoo must NOT be rewritten (boundary guard).
        let src = r#"var x="/sdcardfoo/bar";"#;
        let out = rewrite_android_paths(src, "/R");
        assert!(out.contains("/sdcardfoo/bar"));
    }

    #[test]
    fn leaves_mnt_android_untouched() {
        // Already in canonical mount form — keep it.
        let src = r#"p="/mnt/android/sdcard/y""#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains("/mnt/android/sdcard/y"));
    }

    #[test]
    fn shell_command_mount_paths_resolve_to_physical() {
        let src = r#"find "/mnt/android/sdcard/movie_room_upload" -name "*.mp4"; cd /data/local/tmp"#;
        let out = rewrite_vfs_mount_paths(src, "/var/mobile/.operit/runtime/android-compat");
        assert!(out.contains(r#""/var/mobile/.operit/runtime/android-compat/sdcard/movie_room_upload""#));
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/data/local/tmp"));
    }

    #[test]
    fn shell_command_data_boundary_guarded() {
        // /databases must not be rewritten, /data/local must.
        let src = r#"ls /databases && ls /data/local/tmp"#;
        let out = rewrite_vfs_mount_paths(src, "/R/android-compat");
        assert!(out.contains("ls /databases"));
        assert!(out.contains("/R/android-compat/data/local/tmp"));
    }
}
