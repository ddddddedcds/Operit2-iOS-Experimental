// Global waifu-mode switch (default off).
//
// Affects the AI message bubble rendering (WaifuTypewriterReveal: typewriter
// style reveal). The flag is persisted via SharedPreferences so it survives
// restarts; load() must be awaited once during startup (see main.dart).

import 'package:shared_preferences/shared_preferences.dart';

class WaifuRuntime {
  WaifuRuntime._();

  static const String _prefsKey = 'waifu_enabled';
  static bool _enabled = false;

  static bool get enabled => _enabled;

  /// Loads the persisted waifu-mode flag. Call once at startup; best-effort.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefsKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
  }

  /// Toggles the flag in memory and persists it. Best-effort persistence.
  static Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, enabled);
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory flag still applies.
    }
  }
}
