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

/// Rewrites Android path literals in `source` to the sandboxed compat root.
///
/// `compatRoot` is the physical compat directory, e.g.
/// `/var/mobile/.operit/runtime/android-compat`. Rules are applied longest-first
/// so `/storage/emulated/0` is matched before the broader `/sdcard` rule, and
/// each replacement is guarded so `/sdcard` does not match `/sdcardfoo`.
pub fn rewrite_android_paths(source: &str, compat_root: &str) -> String {
    let compat = compat_root.trim_end_matches('/');

    // (android_prefix, ios_compat_subpath). Longest/most-specific first.
    let rules: &[(&str, &str)] = &[
        ("/storage/emulated/0", &format!("{compat}/storage/emulated/0")),
        ("/mnt/android/sdcard", &format!("{compat}/sdcard")),
        ("/data/data", &format!("{compat}/data/data")),
        ("/data/local", &format!("{compat}/data/local")),
        ("/data", &format!("{compat}/data")),
        ("/sdcard", &format!("{compat}/sdcard")),
    ];

    let mut out = String::with_capacity(source.len() + 64);
    let mut rest = source;
    while !rest.is_empty() {
        // Try to match the longest Android prefix at the current position.
        let mut matched: Option<(usize, &str)> = None; // (byte_len_of_prefix, replacement)
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
            // Copy one full UTF-8 char.
            let ch = rest.chars().next().unwrap();
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        }
    }
    out
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

#[cfg(test)]
mod tests {
    use super::rewrite_android_paths;

    #[test]
    fn rewrites_sdcard_literal() {
        let src = r#"var P="/sdcard/Download/Operit/x";"#;
        let out = rewrite_android_paths(src, "/var/mobile/.operit/runtime/android-compat");
        eprintln!("SRC: {src}");
        eprintln!("OUT: {out}");
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/sdcard/Download/Operit/x"));
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
        eprintln!("OUT: {out}");
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/sdcard/Download/Operit/movie_room_reply.json"));
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/storage/emulated/0/movie_room_upload"));
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/sdcard/Download/Operit/movie_room_frames"));
        // Bare /sdcard argument (end of string) also rewritten.
        assert!(out.contains("/var/mobile/.operit/runtime/android-compat/sdcard\");"));
    }

    #[test]
    fn rewrites_storage_emulated() {
        let src = r#"scan("/storage/emulated/0/movie")"#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains("/R/android-compat/storage/emulated/0/movie"));
    }

    #[test]
    fn rewrites_data_roots() {
        let src = r#"a("/data/data/com.x/files")b("/data/local/tmp")"#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains("/R/android-compat/data/data/com.x/files"));
        assert!(out.contains("/R/android-compat/data/local/tmp"));
    }

    #[test]
    fn does_not_break_identifier_suffix() {
        // /sdcardfoo must NOT be rewritten (boundary guard).
        let src = r#"var x="/sdcardfoo/bar";"#;
        let out = rewrite_android_paths(src, "/R");
        assert!(out.contains("/sdcardfoo/bar"));
    }

    #[test]
    fn rewrites_mnt_android() {
        let src = r#"p="/mnt/android/sdcard/y""#;
        let out = rewrite_android_paths(src, "/R/android-compat");
        assert!(out.contains("/R/android-compat/sdcard/y"));
    }
}
