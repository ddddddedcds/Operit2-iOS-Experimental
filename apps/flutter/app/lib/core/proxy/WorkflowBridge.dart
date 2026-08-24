// Dart-side workflow bridge: executes workflows and polls schedule triggers
// through the runtime bridge (`workflow.execute` / `workflow.schedulerPoll`,
// dispatched in LocalCoreProxy::dispatchCall without touching codegen).

import '../bridge/OperitRuntimeBridge.dart';
import '../link/CoreLinkProtocol.dart';

class WorkflowExecutionResult {
  const WorkflowExecutionResult({
    required this.success,
    required this.message,
    required this.nodes,
  });

  final bool success;
  final String message;
  final Map<String, Map<String, String>> nodes;

  factory WorkflowExecutionResult.fromValue(Object? value) {
    if (value is Map) {
      final map = Map<String, Object?>.from(value);
      final nodes = <String, Map<String, String>>{};
      final rawNodes = map['nodes'];
      if (rawNodes is List) {
        for (final item in rawNodes) {
          if (item is Map) {
            final nodeMap = Map<String, Object?>.from(item);
            final id = nodeMap['id']?.toString() ?? '';
            final state = nodeMap['state'];
            if (state is Map) {
              final stateMap = Map<String, Object?>.from(state);
              nodes[id] = <String, String>{
                'kind': stateMap['kind']?.toString() ?? 'pending',
                'value': stateMap['value']?.toString() ?? '',
              };
            }
          }
        }
      }
      return WorkflowExecutionResult(
        success: map['success'] == true,
        message: map['message']?.toString() ?? '',
        nodes: nodes,
      );
    }
    return const WorkflowExecutionResult(success: false, message: 'empty response', nodes: {});
  }
}

class WorkflowBridge {
  const WorkflowBridge(this.bridge);

  final OperitRuntimeBridge bridge;

  /// Executes a workflow (JSON string) and returns per-node results.
  Future<WorkflowExecutionResult> execute(
    String workflowJson, {
    Map<String, String> triggerExtras = const <String, String>{},
  }) async {
    final value = await bridge.call(
      CoreCallRequest(
        requestId: _workflowRequestId(),
        targetPath: const CoreObjectPath(<String>['workflow']),
        methodName: 'execute',
        args: <String, Object?>{
          'workflowJson': workflowJson,
          'triggerExtras': _encodeExtras(triggerExtras),
        },
      ),
    );
    return WorkflowExecutionResult.fromValue(value);
  }

  /// Returns the ids of workflows whose schedule trigger is due at [nowMs].
  Future<List<String>> schedulerPoll(
    List<String> workflowsJson, {
    required int nowMs,
  }) async {
    final value = await bridge.call(
      CoreCallRequest(
        requestId: _workflowRequestId(),
        targetPath: const CoreObjectPath(<String>['workflow']),
        methodName: 'schedulerPoll',
        args: <String, Object?>{
          'workflowsJson': '[${workflowsJson.join(',')}]',
          'nowMs': nowMs,
        },
      ),
    );
    if (value is List) {
      return value.map((item) => item.toString()).toList(growable: false);
    }
    return const <String>[];
  }

  /// Registers a workflow with the standalone daemon so it schedules and runs
  /// even when the app is not foregrounded. Returns the daemon reply text.
  Future<String> scheduleDaemon(String workflowJson) async {
    final value = await bridge.call(
      CoreCallRequest(
        requestId: _workflowRequestId(),
        targetPath: const CoreObjectPath(<String>['workflow']),
        methodName: 'scheduleDaemon',
        args: <String, Object?>{'workflowJson': workflowJson},
      ),
    );
    return value?.toString() ?? 'ERR|empty response';
  }

  /// Lists workflows registered on the daemon.
  Future<String> daemonList() async {
    final value = await bridge.call(
      CoreCallRequest(
        requestId: _workflowRequestId(),
        targetPath: const CoreObjectPath(<String>['workflow']),
        methodName: 'daemonList',
        args: const <String, Object?>{},
      ),
    );
    return value?.toString() ?? 'ERR|empty response';
  }

  static String _encodeExtras(Map<String, String> extras) {
    final buffer = StringBuffer('{');
    var first = true;
    extras.forEach((key, value) {
      if (!first) {
        buffer.write(',');
      }
      first = false;
      buffer
        ..write('"')
        ..write(_escapeJson(key))
        ..write('":"')
        ..write(_escapeJson(value))
        ..write('"');
    });
    buffer.write('}');
    return buffer.toString();
  }

  static String _escapeJson(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  static String _workflowRequestId() {
    return 'workflow-${DateTime.now().microsecondsSinceEpoch}';
  }
}
