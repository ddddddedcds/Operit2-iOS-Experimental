// ignore_for_file: file_names

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OperitClientPaths {
  const OperitClientPaths._();

  static Directory? _cachedFilesRoot;

  static Future<Directory> filesRootDir() async {
    final cached = _cachedFilesRoot;
    if (cached != null) {
      return cached;
    }
    final resolved = await _resolveFilesRootDir();
    _cachedFilesRoot = resolved;
    return resolved;
  }

  static Future<Directory> _resolveFilesRootDir() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      return directory;
    } catch (_) {
      // No-container jailbreak builds (roothide/rootless) have no creatable
      // sandbox path from path_provider. Pick a root that is actually WRITABLE
      // by the app user (mobile, uid 501). On roothide the shared
      // /var/mobile/.operit may be owned by root (the agent daemon runs as
      // root and creates it), so we PROBE writability and fall back to a
      // mobile-owned directory instead of throwing — otherwise
      // ClientLogger.initialize() fails and the app white-screens.
      // NOTE: `/var/jb` EXISTS on roothide too (verified on device), so it can
      // never be used to tell rootless from roothide — see _isRootHide.
      // A `/var/jb/...` candidate is only offered when this really IS a
      // rootless install; otherwise `create(recursive: true)` below would
      // CREATE `/var/jb` on a roothide device and poison every later probe.
      final candidates = <String>[
        _operitDataRoot(),
        // roothide/real-root data root (matches Swift iosDataRoot()/Rust data_root)
        '/var/mobile/.operit',
        if (_isRootless) '/var/jb/var/mobile/.operit',
        // app-private fallbacks when the shared root is root-owned
        '/var/mobile/operit2_client',
        if (_isRootless) '/var/jb/var/mobile/operit2_client',
        '/var/mobile',
      ];
      for (final candidate in candidates) {
        try {
          final root = Directory(candidate);
          await root.create(recursive: true);
          // Confirm we can actually create a subdir (root may be root:755).
          final probe = Directory('${candidate}/.write_probe');
          await probe.create(recursive: true);
          await probe.delete();
          return root;
        } catch (_) {
          // Not writable; try the next candidate.
        }
      }
      // Last resort: system temp is always writable.
      return Directory.systemTemp;
    }
  }

  /// True when roothide installed us, decided by our OWN executable path.
  ///
  /// roothide puts the whole jailbreak tree inside
  /// `/var/containers/Bundle/Application/.jbroot-XXXXXXXX/`, so the app binary
  /// carries that segment. Verified on device:
  ///   /var/containers/Bundle/Application/.jbroot-58EAA282AAFACD0F/Applications/Runner.app/Runner
  ///
  /// This replaces the old `/var/jb` existence test, which was provably wrong:
  /// our own tweak created a real `/var/jb` on roothide, after which every
  /// component mis-detected the device as rootless, aimed its data root at a
  /// root-owned directory it could not write, and the app white-screened.
  /// A detection rule must not be falsifiable by the thing it detects.
  static bool get _isRootHide {
    if (!Platform.isIOS) return false;
    try {
      if (Platform.resolvedExecutable.contains('/.jbroot-')) return true;
    } catch (_) {}
    // roothide: /var/jb is a symlink to / (compat layer). A real rootless
    // /var/jb is a directory, never a symlink. This test is reliable even when
    // the executable path is remapped and hides the .jbroot- segment.
    try {
      Link('/var/jb').targetSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// True for a real rootless (Dopamine/ElleKit) install. Requires an actual
  /// subtree, not the bare `/var/jb` directory that anything can create.
  static bool get _isRootless {
    if (!Platform.isIOS || _isRootHide) return false;
    try {
      return Directory('/var/jb/usr/lib').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// Mirrors Swift iosDataRoot() / Rust data_root() for iOS jailbreak builds.
  static String _operitDataRoot() {
    if (Platform.isIOS) {
      if (_isRootless) {
        return '/var/jb/var/mobile/.operit';
      }
      // roothide and everything else: the real-root data dir, shared with the
      // agent daemon and the tweaks.
      return '/var/mobile/.operit';
    }
    // Non-iOS fallback (should not normally be reached).
    return Directory.systemTemp.path;
  }

  static Future<Directory> clientRootDir() {
    return _directory(<String>['client']);
  }

  static Future<Directory> logsDir() {
    return _directory(<String>['client', 'logs']);
  }

  static Future<File> clientLogFile() async {
    final directory = await logsDir();
    return File(_join(<String>[directory.path, 'client.log']));
  }

  static Future<Directory> linkDir() {
    return _directory(<String>['client', 'link']);
  }

  static Future<File> outboundLinkSessionsFile() async {
    final directory = await linkDir();
    return File(_join(<String>[directory.path, 'outbound_sessions.json']));
  }

  static Future<File> runtimeConnectionConfigFile() async {
    final directory = await linkDir();
    return File(_join(<String>[directory.path, 'runtime_connection.json']));
  }

  /// Returns the persisted local runtime storage configuration file.
  static Future<File> localRuntimeStorageConfigFile() async {
    final directory = await linkDir();
    return File(_join(<String>[directory.path, 'local_runtime_storage.json']));
  }

  static Future<Directory> linkHostDir() {
    return linkDir();
  }

  static Future<Directory> linkHostWebAccessBundleDir() {
    return _directory(<String>['client', 'link', 'web_access_bundle']);
  }

  static Future<File> linkHostConfigFile() async {
    final directory = await linkHostDir();
    return File(_join(<String>[directory.path, 'host_config.json']));
  }

  static Future<File> linkHostStateFile() async {
    final directory = await linkHostDir();
    return File(_join(<String>[directory.path, 'host_state.json']));
  }

  static Future<File> linkHostDeviceIdFile() async {
    final directory = await linkHostDir();
    return File(_join(<String>[directory.path, 'host_device_id']));
  }

  static Future<File> inboundLinkSessionsFile() async {
    final directory = await linkHostDir();
    return File(_join(<String>[directory.path, 'inbound_sessions.json']));
  }

  static Future<File> pendingLinkPairingCodeFile() async {
    final directory = await linkHostDir();
    return File(_join(<String>[directory.path, 'pending_pairing_code.json']));
  }

  static Future<Directory> tempDir() {
    return _directory(<String>['client', 'temp']);
  }

  static Future<Directory> composeDslWebviewFilesDir() {
    return _directory(<String>['client', 'temp', 'compose_dsl_webview_files']);
  }

  static Future<Directory> workspaceVideoDir() {
    return _directory(<String>['client', 'temp', 'workspace_video']);
  }

  static Future<Directory> shareImageTempDir() {
    return _directory(<String>['client', 'temp', 'share_image']);
  }

  static Future<Directory> exportsDir() {
    return _directory(<String>['client', 'exports']);
  }

  static Future<Directory> shareImageExportsDir() {
    return _directory(<String>['client', 'exports', 'share_image']);
  }

  static Future<Directory> _directory(List<String> segments) async {
    final root = await filesRootDir();
    final directory = Directory(_join(<String>[root.path, ...segments]));
    await directory.create(recursive: true);
    return directory;
  }

  static String _join(List<String> segments) {
    return segments.join(Platform.pathSeparator);
  }
}
