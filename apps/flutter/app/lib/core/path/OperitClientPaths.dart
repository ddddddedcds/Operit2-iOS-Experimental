// ignore_for_file: file_names

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class OperitClientPaths {
  const OperitClientPaths._();

  static Future<Directory> filesRootDir() async {
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
      final candidates = <String>[
        _operitDataRoot(),
        '/var/mobile/operit2_client',
        '/var/jb/var/mobile/operit2_client',
        '/var/mobile',
        '/var/jb/var/mobile',
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

  /// Mirrors Swift iosDataRoot() / Rust data_root() for iOS jailbreak builds.
  static String _operitDataRoot() {
    if (Platform.isIOS) {
      if (Directory('/var/jb').existsSync()) {
        return '/var/jb/var/mobile/.operit';
      }
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
