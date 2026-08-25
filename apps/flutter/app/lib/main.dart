import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'core/ai/ExternalAiBridge.dart';
import 'core/application/CoreApplicationService.dart';
import 'core/errors/UnhandledErrorReporter.dart';
import 'core/logging/ClientLogger.dart';
import 'core/notifications/NotificationActivationService.dart';
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
    final paths = <String>[
      '/var/mobile/.operit/launch.log',
      '/var/mobile/trace.log',
      '/var/mobile/.operit/trace.log',
      '/tmp/trace.log',
    ];
    for (final p in paths) {
      try {
        final parent = File(p).parent;
        if (!parent.existsSync()) {
          // Never create a whole new tree for a candidate that may not belong
          // here — that is exactly how a bogus /var/jb got created. Only create
          // the leaf directory, and only when its own parent already exists.
          if (!parent.parent.existsSync()) {
            continue;
          }
          parent.createSync();
        }
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
void main(List<String> arguments) async {
  late Zone startupZone;
  await runZonedGuarded(
    () async {
        _writeLaunchLog('DART_MAIN_START');
        startupZone = Zone.current;
      final startupStopwatch = Stopwatch()..start();
      final bindingStopwatch = Stopwatch()..start();
      WidgetsFlutterBinding.ensureInitialized();
      _writeLaunchLog('WIDGETS_BINDING_OK');
      final bindingElapsedMs = bindingStopwatch.elapsedMilliseconds;
      final loggerStopwatch = Stopwatch()..start();
      try {
        await ClientLogger.initialize();
        _writeLaunchLog('CLIENT_LOGGER_INIT_OK');
      } catch (e, st) {
        // Logging must never block app startup. If the data directory is not
        // writable (e.g. a root-owned .operit), degrade gracefully
        // so runApp still executes instead of white-screening.
        _writeLaunchLog('CLIENT_LOGGER_INIT_FAILED: $e\n$st');
      }
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
        // Every await below used to be able to abort startup before runApp(),
        // which shows up as a pure white screen with no visible error. Each step
        // is now individually guarded: a failure is recorded in the launch/trace
        // log and startup continues, so the UI always comes up.
        NotificationActivationService.instance.initialize(arguments);
        final runtimeStopwatch = Stopwatch()..start();
        try {
          await RuntimeConnectionManager.instance.initialize();
          ClientLogger.attachPersistentStorage();
          ClientLogger.i(
            'runtime connection initialized elapsedMs=${runtimeStopwatch.elapsedMilliseconds}',
            tag: _appStartupLogTag,
          );
          _writeLaunchLog('RUNTIME_INIT_OK');
        } catch (e, st) {
          _writeLaunchLog('RUNTIME_INIT_FAILED: $e\n$st');
        }
      final glassStopwatch = Stopwatch()..start();
      try {
        await LiquidGlassWidgets.initialize();
        ClientLogger.i(
          'liquid glass initialized elapsedMs=${glassStopwatch.elapsedMilliseconds}',
          tag: _appStartupLogTag,
        );
        _writeLaunchLog('LIQUID_GLASS_OK');
      } catch (e, st) {
        _writeLaunchLog('LIQUID_GLASS_INIT_FAILED: $e\n$st');
      }
      final windowStopwatch = Stopwatch()..start();
      Object? windowArguments;
      try {
        windowArguments = await readOperitWindowArguments();
        ClientLogger.i(
          'window arguments read type=${windowArguments.runtimeType} elapsedMs=${windowStopwatch.elapsedMilliseconds}',
          tag: _appStartupLogTag,
        );
        _writeLaunchLog('WINDOW_ARGS_OK type=${windowArguments.runtimeType}');
      } catch (e, st) {
        _writeLaunchLog('WINDOW_ARGS_FAILED: $e\n$st');
      }
      final resolvedWindowArguments = windowArguments;
      if (resolvedWindowArguments is DetachedChatWindowArguments) {
        _runDetachedChatWindow(resolvedWindowArguments);
      } else {
        // MainWindowArguments, or window arguments could not be read at all:
        // fall back to the main window instead of leaving a blank screen.
        final coreStopwatch = Stopwatch()..start();
        try {
          CoreApplicationService.instance.initialize();
          ClientLogger.i(
            'core application initialize dispatched elapsedMs=${coreStopwatch.elapsedMilliseconds}',
            tag: _appStartupLogTag,
          );
          _writeLaunchLog('CORE_APP_INIT_OK');
        } catch (e, st) {
          _writeLaunchLog('CORE_APP_INIT_FAILED: $e\n$st');
        }
        _runMainWindow();
      }
      ClientLogger.i(
        'startup done elapsedMs=${startupStopwatch.elapsedMilliseconds}',
        tag: _appStartupLogTag,
      );
      _writeLaunchLog('STARTUP_DONE');
    },
    (error, stackTrace) {
      _writeLaunchLog('ZONE_ERROR: $error\n$stackTrace');
      startupZone.runGuarded(() {
        if (ClientLogger.isInitialized) {
          ClientLogger.e(
            'Uncaught zone error',
            tag: _appStartupLogTag,
            error: error,
            stackTrace: stackTrace,
          );
        }
        final errorText = error.toString();
        // 可恢复错误不致命化：host interaction 通道的超时/丢失（COMMAND_ERROR、
        // host interaction、request not found）在 macOS 上会因某个模块未实现而
        // 反复触发；单个功能超时不应杀死整个 app。只记录日志，UI 继续运行。
        final isRecoverableCommandError = errorText.contains('COMMAND_ERROR') ||
            errorText.contains('host interaction') ||
            errorText.contains('request not found');
        if (isRecoverableCommandError) {
          _writeLaunchLog('RECOVERABLE_ZONE_ERROR_SKIPPED: $errorText');
          return;
        }
        UnhandledErrorReporter.report(
          source: 'Zone',
          error: error,
          stackTrace: stackTrace,
        );
        runApp(const FatalErrorApplication());
      });
    },
  );
}

/// Starts the main application window without touching runtime services.
void _runMainWindow() {
  ClientLogger.i('run main window', tag: _appStartupLogTag);
  _writeLaunchLog('BEFORE_RUN_APP main');
  // External AI task bridge (iOS Shortcuts -> operit://ask?text=...).
  ExternalAiBridge.install();
  try {
    runApp(
      LiquidGlassWidgets.wrap(
        respectSystemAccessibility: false,
        theme: GlassThemeData.simple(
          blur: 2.5,
          thickness: 36,
          quality: GlassQuality.standard,
        ),
        child: const FatalErrorHost(child: OperitApp()),
      ),
    );
    _writeLaunchLog('AFTER_RUN_APP main');
  } catch (e, st) {
    // Never let the glass wrapper keep the UI from mounting.
    _writeLaunchLog('RUN_APP_WRAP_FAILED: $e\n$st');
    runApp(const OperitApp());
    _writeLaunchLog('AFTER_RUN_APP main(plain)');
  }
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
      child: FatalErrorHost(child: DetachedChatWindowApp(arguments: arguments)),
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
    // 可恢复错误不 presentError：release 模式 presentError 会弹 fatal 对话框
    // 并终止 app（与 zone handler 的可恢复错误策略保持一致）。
    final errorText = details.exceptionAsString();
    final isRecoverableCommandError = errorText.contains('COMMAND_ERROR') ||
        errorText.contains('host interaction') ||
        errorText.contains('request not found');
    if (isRecoverableCommandError) {
      _writeLaunchLog('RECOVERABLE_FLUTTER_ERROR_SKIPPED: $errorText');
      return;
    }
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
