// Node edit dialog: configures a workflow node's fields by kind.
// Trigger: triggerType + triggerConfig; Execute: actionType + actionConfig;
// Condition: left/operator/right; Logic: operator; Extract: mode/expression.
// Returns an updated node (or null if cancelled).

import 'package:flutter/material.dart';

import 'WorkflowModels.dart';

Future<WorkflowNodeModel?> showWorkflowNodeEditor(
  BuildContext context,
  WorkflowNodeModel node,
) {
  return showDialog<WorkflowNodeModel>(
    context: context,
    builder: (dialogContext) => _WorkflowNodeEditorDialog(node: node),
  );
}

class _WorkflowNodeEditorDialog extends StatefulWidget {
  const _WorkflowNodeEditorDialog({required this.node});

  final WorkflowNodeModel node;

  @override
  State<_WorkflowNodeEditorDialog> createState() => _WorkflowNodeEditorDialogState();
}

class _WorkflowNodeEditorDialogState extends State<_WorkflowNodeEditorDialog> {
  late final TextEditingController _nameController;
  late String _triggerType;
  late String _actionType;
  late String _operator;
  late String _left;
  late String _right;
  late String _logicOperator;
  late String _mode;
  late String _expression;
  late String _scheduleType;
  late String _intervalMs;

  @override
  void initState() {
    super.initState();
    final node = widget.node;
    _nameController = TextEditingController(text: node.name);
    _triggerType = node.triggerType.isEmpty ? 'manual' : node.triggerType;
    _actionType = node.actionType;
    _operator = node.operator.isEmpty ? 'EQ' : node.operator;
    _left = node.left;
    _right = node.right;
    _logicOperator = node.logicOperator.isEmpty ? 'AND' : node.logicOperator;
    _mode = node.mode.isEmpty ? 'REGEX' : node.mode;
    _expression = node.expression;
    _scheduleType = node.triggerConfig['schedule_type'] ?? 'interval';
    _intervalMs = node.triggerConfig['interval_ms'] ?? '60000';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return AlertDialog(
      title: Text('编辑 ${_kindLabel(node.kind)}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 8),
            if (node.kind == WorkflowNodeKind.trigger) ..._triggerFields(),
            if (node.kind == WorkflowNodeKind.execute) ..._executeFields(),
            if (node.kind == WorkflowNodeKind.condition) ..._conditionFields(),
            if (node.kind == WorkflowNodeKind.logic) ..._logicFields(),
            if (node.kind == WorkflowNodeKind.extract) ..._extractFields(),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_buildNode()),
          child: const Text('保存'),
        ),
      ],
    );
  }

  List<Widget> _triggerFields() {
    return <Widget>[
      DropdownButtonFormField<String>(
        initialValue: _triggerType,
        decoration: const InputDecoration(labelText: '触发类型'),
        items: const <DropdownMenuItem<String>>[
          DropdownMenuItem(value: 'manual', child: Text('手动')),
          DropdownMenuItem(value: 'schedule', child: Text('定时')),
        ],
        onChanged: (value) => setState(() => _triggerType = value ?? 'manual'),
      ),
      if (_triggerType == 'schedule') ...<Widget>[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _scheduleType,
          decoration: const InputDecoration(labelText: '调度方式'),
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem(value: 'interval', child: Text('间隔')),
            DropdownMenuItem(value: 'specific_time', child: Text('指定时间')),
            DropdownMenuItem(value: 'cron', child: Text('Cron')),
          ],
          onChanged: (value) => setState(() => _scheduleType = value ?? 'interval'),
        ),
        const SizedBox(height: 8),
        if (_scheduleType == 'interval')
          TextField(
            controller: TextEditingController(text: _intervalMs),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '间隔(毫秒)'),
            onChanged: (value) => _intervalMs = value,
          ),
        if (_scheduleType == 'cron')
          TextField(
            decoration: const InputDecoration(labelText: 'Cron 表达式 (如 * * * * *)'),
            onChanged: (value) => _scheduleType = value,
          ),
      ],
    ];
  }

  List<Widget> _executeFields() {
    return <Widget>[
      TextField(
        decoration: const InputDecoration(labelText: '动作类型 (工具名)'),
        controller: TextEditingController(text: _actionType),
        onChanged: (value) => _actionType = value,
      ),
    ];
  }

  List<Widget> _conditionFields() {
    return <Widget>[
      TextField(
        decoration: const InputDecoration(labelText: '左值 (或 {节点id} 引用)'),
        controller: TextEditingController(text: _left),
        onChanged: (value) => _left = value,
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _operator,
        decoration: const InputDecoration(labelText: '操作符'),
        items: const <DropdownMenuItem<String>>[
          DropdownMenuItem(value: 'EQ', child: Text('等于')),
          DropdownMenuItem(value: 'NE', child: Text('不等于')),
          DropdownMenuItem(value: 'GT', child: Text('大于')),
          DropdownMenuItem(value: 'GTE', child: Text('大于等于')),
          DropdownMenuItem(value: 'LT', child: Text('小于')),
          DropdownMenuItem(value: 'LTE', child: Text('小于等于')),
          DropdownMenuItem(value: 'CONTAINS', child: Text('包含')),
          DropdownMenuItem(value: 'NOT_CONTAINS', child: Text('不包含')),
          DropdownMenuItem(value: 'IN', child: Text('在列表中')),
          DropdownMenuItem(value: 'NOT_IN', child: Text('不在列表中')),
        ],
        onChanged: (value) => setState(() => _operator = value ?? 'EQ'),
      ),
      const SizedBox(height: 8),
      TextField(
        decoration: const InputDecoration(labelText: '右值'),
        controller: TextEditingController(text: _right),
        onChanged: (value) => _right = value,
      ),
    ];
  }

  List<Widget> _logicFields() {
    return <Widget>[
      DropdownButtonFormField<String>(
        initialValue: _logicOperator,
        decoration: const InputDecoration(labelText: '逻辑操作符'),
        items: const <DropdownMenuItem<String>>[
          DropdownMenuItem(value: 'AND', child: Text('AND')),
          DropdownMenuItem(value: 'OR', child: Text('OR')),
        ],
        onChanged: (value) => setState(() => _logicOperator = value ?? 'AND'),
      ),
    ];
  }

  List<Widget> _extractFields() {
    return <Widget>[
      DropdownButtonFormField<String>(
        initialValue: _mode,
        decoration: const InputDecoration(labelText: '提取模式'),
        items: const <DropdownMenuItem<String>>[
          DropdownMenuItem(value: 'REGEX', child: Text('正则')),
          DropdownMenuItem(value: 'JSON', child: Text('JSON 路径')),
          DropdownMenuItem(value: 'SUB', child: Text('子串')),
          DropdownMenuItem(value: 'CONCAT', child: Text('拼接')),
          DropdownMenuItem(value: 'RANDOM_INT', child: Text('随机整数')),
          DropdownMenuItem(value: 'RANDOM_STRING', child: Text('随机字符串')),
        ],
        onChanged: (value) => setState(() => _mode = value ?? 'REGEX'),
      ),
      const SizedBox(height: 8),
      TextField(
        decoration: const InputDecoration(labelText: '表达式'),
        controller: TextEditingController(text: _expression),
        onChanged: (value) => _expression = value,
      ),
    ];
  }

  WorkflowNodeModel _buildNode() {
    final node = widget.node;
    final triggerConfig = Map<String, String>.from(node.triggerConfig);
    if (_triggerType == 'schedule') {
      triggerConfig['schedule_type'] = _scheduleType;
      if (_scheduleType == 'interval') {
        triggerConfig['interval_ms'] = _intervalMs;
      }
    }
    return node.copyWith(
      name: _nameController.text.trim().isEmpty ? node.name : _nameController.text.trim(),
      triggerType: _triggerType,
      actionType: _actionType,
      operator: _operator,
      left: _left,
      right: _right,
      logicOperator: _logicOperator,
      mode: _mode,
      expression: _expression,
      actionConfig: node.actionConfig,
    );
  }

  String _kindLabel(WorkflowNodeKind kind) {
    switch (kind) {
      case WorkflowNodeKind.trigger:
        return '触发节点';
      case WorkflowNodeKind.execute:
        return '执行节点';
      case WorkflowNodeKind.condition:
        return '条件节点';
      case WorkflowNodeKind.logic:
        return '逻辑节点';
      case WorkflowNodeKind.extract:
        return '提取节点';
    }
  }
}
