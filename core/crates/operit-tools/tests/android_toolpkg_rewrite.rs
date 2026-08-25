//! Integration tests for static Android-path rewriting of ToolPkg ZIP archives.
//! Lives outside `src` so it doesn't compile the (independently broken) lib test
//! modules.

use std::io::{Cursor, Read, Write};

use operit_tools::tools::packTool::AndroidToolPkgPathRewriter::rewrite_toolpkg_android_paths_in_zip;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

const COMPAT: &str = "/var/mobile/.operit/runtime/android-compat";

fn make_toolpkg(js: &str) -> Vec<u8> {
    let mut out = Vec::new();
    {
        let mut w = ZipWriter::new(Cursor::new(&mut out));
        w.add_directory(
            "plugin/",
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .unwrap();
        w.start_file(
            "plugin/main.js",
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .unwrap();
        w.write_all(js.as_bytes()).unwrap();
        w.start_file(
            "manifest.json",
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .unwrap();
        w.write_all(b"{\"name\":\"t\"}").unwrap();
        w.finish().unwrap();
    }
    out
}

#[test]
fn rewrites_js_entries_inside_zip() {
    let src = r#"var P="/sdcard/Download/Operit/x";var S="/storage/emulated/0/y";"#;
    let zip = make_toolpkg(src);
    let out = rewrite_toolpkg_android_paths_in_zip(&zip, COMPAT).unwrap();
    assert_ne!(out, zip, "expected a rewrite to happen");

    let mut a = ZipArchive::new(Cursor::new(out.as_slice())).unwrap();
    let mut main_content = String::new();
    {
        let mut main = a.by_name("plugin/main.js").unwrap();
        main.read_to_string(&mut main_content).unwrap();
    }
    assert!(
        main_content.contains("/mnt/android/sdcard/Download/Operit/x"),
        "rewritten main.js missing sdcard mount form: {main_content}"
    );
    assert!(
        main_content.contains("/mnt/android/sdcard/y"),
        "rewritten main.js missing storage mount form: {main_content}"
    );

    let mut manifest_content = String::new();
    {
        let mut manifest = a.by_name("manifest.json").unwrap();
        manifest.read_to_string(&mut manifest_content).unwrap();
    }
    assert_eq!(manifest_content, "{\"name\":\"t\"}");
}

#[test]
fn returns_original_bytes_when_nothing_to_rewrite() {
    let zip = make_toolpkg("var P = 1;");
    let out = rewrite_toolpkg_android_paths_in_zip(&zip, COMPAT).unwrap();
    assert_eq!(out, zip);
}

#[test]
fn round_trips_real_plugin_zip() {
    // Simulate a real plugin: nested subpackage JS with a hardcoded shell path.
    let mut out = Vec::new();
    {
        let mut w = ZipWriter::new(Cursor::new(&mut out));
        w.add_directory(
            "packages/",
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .unwrap();
        w.start_file(
            "packages/movie_room.js",
            SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
        )
        .unwrap();
        w.write_all(
            br#"function scan(){return Tools.System.shell('find "/sdcard/movie_room_upload" -name "*.mp4"')}"#,
        )
        .unwrap();
        w.finish().unwrap();
    }
    let rewritten = rewrite_toolpkg_android_paths_in_zip(&out, COMPAT).unwrap();
    let mut a = ZipArchive::new(Cursor::new(rewritten.as_slice())).unwrap();
    let mut content = String::new();
    {
        let mut f = a.by_name("packages/movie_room.js").unwrap();
        f.read_to_string(&mut content).unwrap();
    }
    assert!(content.contains(r#"find "/mnt/android/sdcard/movie_room_upload""#));
}
