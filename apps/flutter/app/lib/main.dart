import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core/application/CoreApplicationService.dart';
import 'core/errors/UnhandledErrorReporter.dart';
import 'core/logging/ClientLogger.dart';
import 'core/runtime/RuntimeConnectionManager.dart';
import 'ui/main/OperitApp.dart';
import 'ui/window/DetachedChatWindowApp.dart';
import 'ui/window/OperitWindowArguments.dart';
import 'ui/window/OperitWindowPlatform.dart';

const String _appStartupLogTag = 'AppStartup';

/// Raw, ClientLogger-independent diagnostic sink.
/// Writes directly to launch.log AND mirrors into trace.log (the same file the
/// native tracer writes) so all startup diagnostics live in one place and are
/// visible over SSH even when ClientLogger.initialize() throws. Best-effort;
/// never throws.
void _writeLaunchLog(String message) {
  try {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message\n';
    const paths = [
      '/var/mobile/.operit/launch.log',
      '/var/mobile/trace.log',
      '/var/mobile/.operit/trace.log',
      '/var/jb/var/mobile/.operit/trace.log',
      '/tmp/trace.log',
    ];
    for (final p in paths) {
      try {
        File(p).parent.createSync(recursive: true);
        File(p).writeAsStringSync(line, mode: FileMode.append);
      } catch (_) {
        // Try next candidate path.
      }
    }
  } catch (_) {
    // Last-resort sink; ignore all failures.
  }
}

/// Runs the application startup sequence with structured diagnostics.
void main(List<String> _) async {
  await runZonedGuarded(
    () async {
      _writeLaunchLog('DART_MAIN_START');
      final startupStopwatch = Stopwatch()..start();
      final bindingStopwatch = Stopwatch()..start();
      WidgetsFlutterBinding.ensureInitialized();
      _writeLaunchLog('WIDGETS_BINDING_OK');
      final bindingElapsedMs = bindingStopwatch.elapsedMilliseconds;
      final loggerStopwatch = Stopwatch()..start();
      await ClientLogger.initialize();
      _writeLaunchLog('CLIENT_LOGGER_INIT_OK');
      ClientLogger.i(
        'widgets binding initialized elapsedMs=$bindingElapsedMs',
        tag: _appStartupLogTag,
      );
      ClientLogger.i(
        'client logger initialized elapsedMs=${loggerStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      final hooksStopwatch = Stopwatch()..start();
      _installClientLogHooks();
      ClientLogger.i(
        'client log hooks installed elapsedMs=${hooksStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      final runtimeStopwatch = Stopwatch()..start();
      await RuntimeConnectionManager.instance.initialize();
      ClientLogger.i(
        'runtime connection initialized elapsedMs=${runtimeStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      _writeLaunchLog('RUNTIME_INIT_OK');
      final glassStopwatch = Stopwatch()..start();
      await LiquidGlassWidgets.initialize();
      ClientLogger.i(
        'liquid glass initialized elapsedMs=${glassStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      _writeLaunchLog('LIQUID_GLASS_OK');
      final windowStopwatch = Stopwatch()..start();
      final windowArguments = await readOperitWindowArguments();
      ClientLogger.i(
        'window arguments read type=${windowArguments.runtimeType} elapsedMs=${windowStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      _writeLaunchLog('WINDOW_ARGS_OK type=${windowArguments.runtimeType}');
      switch (windowArguments) {
        case MainWindowArguments():
          final coreStopwatch = Stopwatch()..start();
          CoreApplicationService.instance.initialize();
          ClientLogger.i(
            'core application initialize dispatched elapsedMs=${coreStopwatch.elapsedMilliseconds}',
            tag: _appStartupLogTag,
          );
          _runMainWindow();
        case final DetachedChatWindowArguments detachedArguments:
          _runDetachedChatWindow(detachedArguments);
      }
      ClientLogger.i(
        'startup done elapsedMs=${startupStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      _writeLaunchLog('STARTUP_DONE');
    },
    (error, stackTrace) {
      _writeLaunchLog('ZONE_ERROR: $error\n$stackTrace');
      if (ClientLogger.isInitialized) {
        ClientLogger.e(
          'Uncaught zone error',
          tag: _appStartupLogTag,
          error: error,
          stackTrace: stackTrace,
        );
      }
      UnhandledErrorReporter.report(
        source: 'Zone',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

/// Starts the main application window without touching runtime services.
void _runMainWindow() {
  ClientLogger.i('run main window', tag: _appStartupLogTag);
  _writeLaunchLog('BEFORE_RUN_APP main');
  runApp(
    LiquidGlassWidgets.wrap(
      respectSystemAccessibility: false,
      theme: GlassThemeData.simple(
        blur: 2.5,
        thickness: 36,
        quality: GlassQuality.standard,
      ),
      child: const OperitApp(),
    ),
  );
}

/// Starts a detached chat window after runtime configuration is loaded.
void _runDetachedChatWindow(DetachedChatWindowArguments arguments) {
  ClientLogger.i('run detached chat window', tag: _appStartupLogTag);
  _writeLaunchLog('BEFORE_RUN_APP detached');
  runApp(
    LiquidGlassWidgets.wrap(
      respectSystemAccessibility: false,
      theme: GlassThemeData.simple(
        blur: 2.5,
        thickness: 36,
        quality: GlassQuality.standard,
      ),
      child: DetachedChatWindowApp(arguments: arguments),
    ),
  );
}

void _installClientLogHooks() {
  final originalDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null && message.isNotEmpty) {
      ClientLogger.d(message, tag: 'FlutterDebugPrint');
    }
    originalDebugPrint(message, wrapWidth: wrapWidth);
  };

  FlutterError.onError = (FlutterErrorDetails details) {
    _writeLaunchLog('FLUTTER_ERROR: ${details.exceptionAsString()}\n${details.stack}');
    ClientLogger.e(
      details.exceptionAsString(),
      tag: 'FlutterFramework',
      error: details.exception,
      stackTrace: details.stack,
    );
    UnhandledErrorReporter.report(
      source: 'Flutter framework',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    _writeLaunchLog('PLATFORM_ERROR: $error\n$stackTrace');
    ClientLogger.e(
      'Uncaught platform error',
      tag: 'PlatformDispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    UnhandledErrorReporter.report(
      source: 'Platform dispatcher',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
}
