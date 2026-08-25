//! Static Android-path rewriting for ToolPkg ZIP archives.
//!
//! Mirrors the RootHidePatcher idea of rewriting path prefixes in packaged
//! artifacts, but for operit2 ToolPkg JS instead of Mach-O binaries. When a
//! plugin is installed on a non-Android host (iOS), every `.js` entry inside
//! the `.toolpkg` ZIP gets its `/sdcard`, `/data`, `/storage/emulated/0` …
//! literals rewritten to a sandboxed compat root so the plugin can actually
//! persist/read state. The rewritten archive is what gets sealed + stored, so
//! the iOS-converted plugin is permanent (no runtime interception needed).

use std::io::{Cursor, Read, Write};

use operit_plugin_sdk::toolpkg::ToolPkgProtection;
use operit_util::AndroidPathRewriter::rewrite_android_paths;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

/// Rewrites every `.js` entry of a ToolPkg ZIP in place and returns the new
/// archive bytes. Returns the original bytes unchanged when nothing matched.
///
/// Only touches `.js` entries (the actual executable code); manifests and other
/// assets are passed through byte-for-byte. On Android hosts this is a no-op
/// and callers should skip it entirely (`cfg!(target_os = "android")`).
pub fn rewrite_toolpkg_android_paths_in_zip(
    zip_bytes: &[u8],
    compat_root: &str,
) -> Result<Vec<u8>, String> {
    let mut archive = ZipArchive::new(Cursor::new(zip_bytes)).map_err(|e| e.to_string())?;

    // Read every entry first (resolves the borrow on `archive` before writing).
    let mut entries: Vec<(String, bool, Option<zip::DateTime>, Vec<u8>)> = Vec::new();
    let mut changed = false;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|e| e.to_string())?;
        let name = entry.name().to_string();
        let is_dir = entry.is_dir();
        let last_modified = entry.last_modified();
        let mut content = Vec::new();
        entry.read_to_end(&mut content).map_err(|e| e.to_string())?;

        if !is_dir && name.to_ascii_lowercase().ends_with(".js") {
            // Skip encrypted/protected entries: rewriting them would corrupt the
            // ciphertext. The runtime rewriter (JsEngine) still covers those.
            let is_protected = {
                let probe_len = content.len().min(ToolPkgProtection::MARKET_ONLY_PROTECTION_HEADER_SIZE);
                ToolPkgProtection::isProtectedEntry(&content[..probe_len])
            };
            if !is_protected {
                let source = String::from_utf8_lossy(&content);
                let rewritten = rewrite_android_paths(&source, compat_root);
                if rewritten != source {
                    changed = true;
                    content = rewritten.into_bytes();
                }
            }
        }
        entries.push((name, is_dir, last_modified, content));
    }

    if !changed {
        return Ok(zip_bytes.to_vec());
    }

    let mut output = Vec::new();
    {
        let mut writer = ZipWriter::new(Cursor::new(&mut output));
        for (name, is_dir, last_modified, content) in entries {
            let mut options =
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
            if let Some(time) = last_modified {
                options = options.last_modified_time(time);
            }
            if is_dir {
                writer
                    .add_directory(name, options)
                    .map_err(|e| e.to_string())?;
                continue;
            }
            writer.start_file(name, options).map_err(|e| e.to_string())?;
            writer.write_all(&content).map_err(|e| e.to_string())?;
        }
        writer.finish().map_err(|e| e.to_string())?;
    }
    Ok(output)
}
