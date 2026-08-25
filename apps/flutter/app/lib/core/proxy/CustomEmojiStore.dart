// Custom emoji storage for waifu mode.
//
// Lets the user add their own emoji images, keyed by an emotion category.
// Each entry stores the absolute file path of a copied image under the app's
// documents/custom_emoji/<category>/ directory. Persisted as JSON via
// SharedPreferences. Built-in emojis are bundled assets (assets/emoji/) and are
// resolved separately (see resolveEmojiAsset in MarkdownImageRenderer).

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CustomEmojiStore {
  CustomEmojiStore._();

  static const String _prefsKey = 'custom_emoji_map';
  static const String _dirName = 'custom_emoji';

  // emotionCategory -> list of absolute file paths (most recently added first).
  static Map<String, List<String>> _map = <String, List<String>>{};
  static bool _loaded = false;

  /// Loads the persisted custom emoji map. Call once at startup; best-effort.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _map = decoded.map(
            (key, value) => MapEntry(
              key.toString(),
              (value as List).map((e) => e.toString()).toList(),
            ),
          );
        }
      }
    } catch (_) {
      _map = <String, List<String>>{};
    }
    _loaded = true;
  }

  static bool get isLoaded => _loaded;

  /// Custom emoji file paths for one emotion category (empty if none).
  static List<String> customPathsFor(String category) =>
      List<String>.from(_map[category.toLowerCase()] ?? const <String>[]);

  /// True if there is at least one custom emoji for the category.
  static bool hasCustomFor(String category) =>
      (_map[category.toLowerCase()]?.isNotEmpty ?? false);

  /// Persists a newly imported emoji file (already copied to documents) for a
  /// category. Returns the final absolute path.
  static Future<void> addEmoji(String category, String filePath) async {
    final key = category.toLowerCase().trim();
    if (key.isEmpty) return;
    final list = _map.putIfAbsent(key, () => <String>[]);
    if (!list.contains(filePath)) {
      list.insert(0, filePath);
    }
    await _persist();
  }

  /// Removes a custom emoji file from the category and deletes the file.
  static Future<void> removeEmoji(String category, String filePath) async {
    final key = category.toLowerCase().trim();
    final list = _map[key];
    if (list != null) {
      list.remove(filePath);
      if (list.isEmpty) {
        _map.remove(key);
      }
    }
    try {
      final f = File(filePath);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // Deleting the file is best-effort; the map entry is already gone.
    }
    await _persist();
  }

  /// Copies a picked image into documents/custom_emoji/<category>/ and returns
  /// the destination absolute path, or null on failure.
  static Future<String?> importImage(String category, String sourcePath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final key = category.toLowerCase().trim();
      if (key.isEmpty) return null;
      final dir = Directory('${docs.path}/$_dirName/$key');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final ext = _extensionOf(sourcePath);
      final dest = '${dir.path}/custom_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(sourcePath).copy(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// All emotion categories that have at least one custom emoji.
  static List<String> get categories =>
      _map.keys.toList()..sort();

  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_map));
    } catch (_) {
      // Persistence failure is non-fatal.
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '.jpg';
    final ext = path.substring(dot).toLowerCase();
    return (ext.length > 1 && ext.length <= 5) ? ext : '.jpg';
  }
}
