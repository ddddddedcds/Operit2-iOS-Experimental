// Global waifu-mode switch (default off).
//
// Kept intentionally simple: a process-wide flag that the UI toggles.
// Persisting it in UserPreferences can be added later without changing
// the rendering path.

class WaifuRuntime {
  WaifuRuntime._();

  static bool waifuEnabled = false;

  static void setEnabled(bool enabled) {
    waifuEnabled = enabled;
  }

  static bool get enabled => waifuEnabled;
}
