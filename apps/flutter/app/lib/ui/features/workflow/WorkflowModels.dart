// Dart-side workflow models, field-aligned with the Rust
// operit-model::Workflow (serde). Kept lightweight so the canvas UI can
// serialize to the same JSON shape the Rust engine expects.

import 'dart:convert';

class NodePosition {
  const NodePosition(this.x, this.y);

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{'x': x, 'y': y};

  factory NodePosition.fromJson(Map<String, Object?> json) =>
      NodePosition((json['x'] as num?)?.toDouble() ?? 0, (json['y'] as num?)?.toDouble() ?? 0);
}

enum WorkflowNodeKind {
  trigger,
  execute,
  condition,
  logic,
  extract,
}

/// Mirrors Rust `ParameterValue` (externally-tagged serde enum).
/// Serializes to `{"StaticValue": {"value": "..."}}` or
/// `{"NodeReference": {"nodeId": "..."}}` so the Rust engine can
/// deserialize `actionConfig: HashMap<String, ParameterValue>` without
/// hitting "unknown variant" on a bare string payload.
class WorkflowParameterValue {
  const WorkflowParameterValue.staticValue(this.value)
      : nodeId = null,
        isReference = false;
  const WorkflowParameterValue.nodeReference(this.nodeId)
      : value = null,
        isReference = true;

  final bool isReference;
  final String? value;
  final String? nodeId;

  Map<String, Object?> toJson() {
    if (isReference) {
      return <String, Object?>{
        'NodeReference': <String, Object?>{'nodeId': nodeId ?? ''},
      };
    }
    return <String, Object?>{
      'StaticValue': <String, Object?>{'value': value ?? ''},
    };
  }

  factory WorkflowParameterValue.fromJson(Object? json) {
    if (json is String) {
      // Tolerate legacy plain-string payloads stored before this fix.
      return WorkflowParameterValue.staticValue(json);
    }
    if (json is Map<String, Object?>) {
      if (json.containsKey('NodeReference')) {
        final n = json['NodeReference'];
        final id = n is Map
            ? (n['nodeId'] as String?) ?? ''
            : (n?.toString() ?? '');
        return WorkflowParameterValue.nodeReference(id);
      }
      if (json.containsKey('StaticValue')) {
        final v = json['StaticValue'];
        final val = v is Map
            ? (v['value'] as String?) ?? ''
            : (v?.toString() ?? '');
        return WorkflowParameterValue.staticValue(val);
      }
    }
    return const WorkflowParameterValue.staticValue('');
  }

  String get displayValue => isReference ? (nodeId ?? '') : (value ?? '');
}

class WorkflowNodeModel {
  const WorkflowNodeModel({
    required this.id,
    required this.kind,
    required this.name,
    required this.position,
    this.description = '',
    this.triggerType = '',
    this.triggerConfig = const <String, String>{},
    this.actionType = '',
    this.actionConfig = const <String, WorkflowParameterValue>{},
    this.operator = 'EQ',
    this.left = '',
    this.right = '',
    this.logicOperator = 'AND',
    this.mode = 'REGEX',
    this.expression = '',
  });

  final String id;
  final WorkflowNodeKind kind;
  final String name;
  final String description;
  final NodePosition position;

  // trigger
  final String triggerType;
  final Map<String, String> triggerConfig;

  // execute
  final String actionType;
  final Map<String, WorkflowParameterValue> actionConfig;

  // condition
  final String operator;
  final String left;
  final String right;

  // logic
  final String logicOperator;

  // extract
  final String mode;
  final String expression;

  WorkflowNodeModel copyWith({
    NodePosition? position,
    String? name,
    String? operator,
    String? left,
    String? right,
    String? logicOperator,
    String? actionType,
    String? mode,
    String? expression,
    String? triggerType,
    Map<String, WorkflowParameterValue>? actionConfig,
  }) {
    return WorkflowNodeModel(
      id: id,
      kind: kind,
      name: name ?? this.name,
      description: description,
      position: position ?? this.position,
      triggerType: triggerType ?? this.triggerType,
      triggerConfig: triggerConfig,
      actionType: actionType ?? this.actionType,
      actionConfig: actionConfig ?? this.actionConfig,
      operator: operator ?? this.operator,
      left: left ?? this.left,
      right: right ?? this.right,
      logicOperator: logicOperator ?? this.logicOperator,
      mode: mode ?? this.mode,
      expression: expression ?? this.expression,
    );
  }

  Map<String, Object?> toJson() {
    final base = <String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'position': position.toJson(),
    };
    switch (kind) {
      case WorkflowNodeKind.trigger:
        base['type'] = 'trigger';
        base['triggerType'] = triggerType;
        base['triggerConfig'] = triggerConfig;
      case WorkflowNodeKind.execute:
        base['type'] = 'execute';
        base['actionType'] = actionType;
        base['actionConfig'] =
            actionConfig.map((k, v) => MapEntry(k, v.toJson()));
      case WorkflowNodeKind.condition:
        base['type'] = 'condition';
        base['operator'] = operator;
        base['left'] = left;
        base['right'] = right;
      case WorkflowNodeKind.logic:
        base['type'] = 'logic';
        base['operator'] = logicOperator;
      case WorkflowNodeKind.extract:
        base['type'] = 'extract';
        base['mode'] = mode;
        base['expression'] = expression;
    }
    return base;
  }

  factory WorkflowNodeModel.fromJson(Map<String, Object?> json) {
    final type = (json['type'] as String?) ?? 'execute';
    final kind = WorkflowNodeKind.values.firstWhere(
      (k) => k.name == type,
      orElse: () => WorkflowNodeKind.execute,
    );
    return WorkflowNodeModel(
      id: (json['id'] as String?) ?? '',
      kind: kind,
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      position: json['position'] is Map<String, Object?>
          ? NodePosition.fromJson(Map<String, Object?>.from(json['position']! as Map))
          : const NodePosition(0, 0),
      triggerType: (json['triggerType'] as String?) ?? '',
      triggerConfig: _stringMap(json['triggerConfig']),
      actionType: (json['actionType'] as String?) ?? '',
      actionConfig: _parameterMap(json['actionConfig']),
      operator: (json['operator'] as String?) ?? 'EQ',
      left: (json['left'] as String?) ?? '',
      right: (json['right'] as String?) ?? '',
      logicOperator: (json['logicOperator'] as String?) ?? (json['operator'] as String?) ?? 'AND',
      mode: (json['mode'] as String?) ?? 'REGEX',
      expression: (json['expression'] as String?) ?? '',
    );
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item.toString()));
    }
    return <String, String>{};
  }

  static Map<String, WorkflowParameterValue> _parameterMap(Object? value) {
    if (value is Map) {
      return value.map(
        (key, item) =>
            MapEntry(key.toString(), WorkflowParameterValue.fromJson(item)),
      );
    }
    return <String, WorkflowParameterValue>{};
  }
}

class WorkflowNodeConnectionModel {
  const WorkflowNodeConnectionModel({
    required this.id,
    required this.sourceNodeId,
    required this.targetNodeId,
    this.condition,
  });

  final String id;
  final String sourceNodeId;
  final String targetNodeId;
  final String? condition;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'sourceNodeId': sourceNodeId,
        'targetNodeId': targetNodeId,
        if (condition != null) 'condition': condition,
      };

  factory WorkflowNodeConnectionModel.fromJson(Map<String, Object?> json) =>
      WorkflowNodeConnectionModel(
        id: (json['id'] as String?) ?? '',
        sourceNodeId: (json['sourceNodeId'] as String?) ?? '',
        targetNodeId: (json['targetNodeId'] as String?) ?? '',
        condition: json['condition'] as String?,
      );
}

class WorkflowModel {
  const WorkflowModel({
    required this.id,
    required this.name,
    required this.description,
    required this.nodes,
    required this.connections,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final List<WorkflowNodeModel> nodes;
  final List<WorkflowNodeConnectionModel> connections;
  final bool enabled;

  String toJsonString() {
    return jsonEncode(<String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'nodes': nodes.map((n) => n.toJson()).toList(),
      'connections': connections.map((c) => c.toJson()).toList(),
      'enabled': enabled,
      'createdAt': 0,
      'updatedAt': 0,
    });
  }
}
