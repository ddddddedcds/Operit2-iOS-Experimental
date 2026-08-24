// Minimal workflow canvas: infinite pan/zoom canvas with a dot grid, draggable
// node cards (5 kinds), Bezier connection edges, and a node-add toolbar.
// This is a functional Step-4 subset of the upstream Kotlin canvas — enough to
// build, drag, connect, and export a workflow; deep node-editing forms are
// intentionally left for later.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../core/bridge/ProxyCoreRuntimeBridge.dart';
import '../../../../core/proxy/WorkflowBridge.dart';
import 'WorkflowModels.dart';
import 'WorkflowNodeEditor.dart';

const double _kNodeWidth = 150;
const double _kNodeHeight = 64;
const double _kCellSize = 40;

class WorkflowCanvasScreen extends StatefulWidget {
  const WorkflowCanvasScreen({
    super.key,
    this.initialJson,
    this.onSave,
  });

  /// Pushes the workflow canvas onto the navigator.
  static Future<void> push(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const WorkflowCanvasScreen(),
      ),
    );
  }

  /// Optional workflow JSON to load.
  final String? initialJson;

  /// Called with the serialized workflow when the user taps save.
  final void Function(String json)? onSave;

  @override
  State<WorkflowCanvasScreen> createState() => _WorkflowCanvasScreenState();
}

class _WorkflowCanvasScreenState extends State<WorkflowCanvasScreen> {
  final List<WorkflowNodeModel> _nodes = <WorkflowNodeModel>[];
  final List<WorkflowNodeConnectionModel> _connections =
      <WorkflowNodeConnectionModel>[];
  int _idCounter = 0;
  String? _selectedNodeId;
  String? _pendingConnectionSource;
  Map<String, String> _nodeExecution = <String, String>{};
  bool _running = false;

  @override
  void initState() {
    super.initState();
    final json = widget.initialJson;
    if (json != null && json.isNotEmpty) {
      _loadFromJson(json);
    } else {
      _seedDemo();
    }
  }

  void _loadFromJson(String json) {
    try {
      final data = _decodeJson(json);
      final nodes = (data['nodes'] as List<Object?>? ?? <Object?>[])
          .whereType<Map>()
          .map((m) => WorkflowNodeModel.fromJson(Map<String, Object?>.from(m)))
          .toList();
      final connections = (data['connections'] as List<Object?>? ?? <Object?>[])
          .whereType<Map>()
          .map((m) => WorkflowNodeConnectionModel.fromJson(Map<String, Object?>.from(m)))
          .toList();
      _nodes
        ..clear()
        ..addAll(nodes);
      _connections
        ..clear()
        ..addAll(connections);
      for (final node in _nodes) {
        final idNum = int.tryParse(node.id.replaceAll(RegExp(r'[^0-9]'), ''));
        if (idNum != null && idNum >= _idCounter) {
          _idCounter = idNum + 1;
        }
      }
    } catch (_) {
      _seedDemo();
    }
  }

  Map<String, Object?> _decodeJson(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
    } catch (_) {}
    return <String, Object?>{};
  }

  void _seedDemo() {
    _nodes
      ..clear()
      ..add(WorkflowNodeModel(
        id: 'n1',
        kind: WorkflowNodeKind.trigger,
        name: '开始',
        position: const NodePosition(60, 120),
        triggerType: 'manual',
      ))
      ..add(WorkflowNodeModel(
        id: 'n2',
        kind: WorkflowNodeKind.execute,
        name: '执行动作',
        position: const NodePosition(320, 120),
        actionType: 'shell',
      ))
      ..add(WorkflowNodeModel(
        id: 'n3',
        kind: WorkflowNodeKind.condition,
        name: '条件判断',
        position: const NodePosition(320, 260),
        left: '{n2}',
        operator: 'CONTAINS',
        right: 'ok',
      ));
    _connections
      ..clear()
      ..add(WorkflowNodeConnectionModel(
        id: 'c1',
        sourceNodeId: 'n1',
        targetNodeId: 'n2',
      ))
      ..add(WorkflowNodeConnectionModel(
        id: 'c2',
        sourceNodeId: 'n2',
        targetNodeId: 'n3',
      ));
    _idCounter = 4;
  }

  void _addNode(WorkflowNodeKind kind) {
    final id = 'n${_idCounter++}';
    final node = WorkflowNodeModel(
      id: id,
      kind: kind,
      name: _defaultName(kind),
      position: NodePosition(200 + (_nodes.length * 24) % 200, 120 + (_nodes.length * 40) % 300),
    );
    setState(() => _nodes.add(node));
  }

  String _defaultName(WorkflowNodeKind kind) {
    switch (kind) {
      case WorkflowNodeKind.trigger:
        return '触发';
      case WorkflowNodeKind.execute:
        return '执行动作';
      case WorkflowNodeKind.condition:
        return '条件判断';
      case WorkflowNodeKind.logic:
        return '逻辑合并';
      case WorkflowNodeKind.extract:
        return '提取数据';
    }
  }

  void _onNodeMoved(String id, Offset delta) {
    final index = _nodes.indexWhere((n) => n.id == id);
    if (index < 0) {
      return;
    }
    final node = _nodes[index];
    _nodes[index] = node.copyWith(
      position: NodePosition(node.position.x + delta.dx, node.position.y + delta.dy),
    );
  }

  void _startConnection(String sourceId) {
    setState(() => _pendingConnectionSource = sourceId);
  }

  void _finishConnection(String targetId) {
    final source = _pendingConnectionSource;
    if (source == null || source == targetId) {
      setState(() => _pendingConnectionSource = null);
      return;
    }
    final exists = _connections.any(
      (c) => c.sourceNodeId == source && c.targetNodeId == targetId,
    );
    if (!exists) {
      _connections.add(WorkflowNodeConnectionModel(
        id: 'c${_idCounter++}',
        sourceNodeId: source,
        targetNodeId: targetId,
      ));
    }
    setState(() => _pendingConnectionSource = null);
  }

  Future<void> _editNode(String id) async {
    final index = _nodes.indexWhere((n) => n.id == id);
    if (index < 0) {
      return;
    }
    final updated = await showWorkflowNodeEditor(context, _nodes[index]);
    if (updated != null && mounted) {
      setState(() => _nodes[index] = updated);
    }
  }

  void _deleteNode(String id) {
    setState(() {
      _nodes.removeWhere((n) => n.id == id);
      _connections.removeWhere(
        (c) => c.sourceNodeId == id || c.targetNodeId == id,
      );
      if (_selectedNodeId == id) {
        _selectedNodeId = null;
      }
    });
  }

  Future<void> _scheduleToDaemon() async {
    final json = WorkflowModel(
      id: 'wf-${DateTime.now().millisecondsSinceEpoch}',
      name: 'My Workflow',
      description: '',
      nodes: _nodes,
      connections: _connections,
    ).toJsonString();
    try {
      final reply = await const WorkflowBridge(ProxyCoreRuntimeBridge())
          .scheduleDaemon(json);
      if (!mounted) {
        return;
      }
      final ok = reply.startsWith('OK|');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '已注册到 daemon 调度' : '注册失败: $reply'),
          backgroundColor: ok ? Colors.green : Colors.red,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('注册异常: $error')),
      );
    }
  }

  void _save() {
    final json = WorkflowModel(
      id: 'wf-${DateTime.now().millisecondsSinceEpoch}',
      name: 'My Workflow',
      description: '',
      nodes: _nodes,
      connections: _connections,
    ).toJsonString();
    widget.onSave?.call(json);
  }

  Future<void> _run() async {
    if (_running) {
      return;
    }
    final json = WorkflowModel(
      id: 'wf-run',
      name: 'My Workflow',
      description: '',
      nodes: _nodes,
      connections: _connections,
    ).toJsonString();
    setState(() {
      _running = true;
      _nodeExecution = <String, String>{};
    });
    try {
      final result = await const WorkflowBridge(ProxyCoreRuntimeBridge())
          .execute(json);
      if (!mounted) {
        return;
      }
      setState(() {
        _nodeExecution = <String, String>{
          for (final entry in result.nodes.entries)
            entry.key: entry.value['kind'] ?? 'pending',
        };
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.success ? '执行成功' : '执行失败: ${result.message}'),
            backgroundColor: result.success ? Colors.green : Colors.red,
          ),
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _nodeExecution = <String, String>{};
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('执行异常: $error')),
        );
      });
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作流'),
        actions: <Widget>[
          IconButton(
            tooltip: '添加触发',
            onPressed: () => _addNode(WorkflowNodeKind.trigger),
            icon: const Icon(Icons.flag),
          ),
          IconButton(
            tooltip: '添加执行',
            onPressed: () => _addNode(WorkflowNodeKind.execute),
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: '添加条件',
            onPressed: () => _addNode(WorkflowNodeKind.condition),
            icon: const Icon(Icons.call_split),
          ),
          IconButton(
            tooltip: '添加逻辑',
            onPressed: () => _addNode(WorkflowNodeKind.logic),
            icon: const Icon(Icons.merge),
          ),
          IconButton(
            tooltip: '添加提取',
            onPressed: () => _addNode(WorkflowNodeKind.extract),
            icon: const Icon(Icons.data_object),
          ),
          IconButton(
            tooltip: '保存',
            onPressed: _save,
            icon: const Icon(Icons.save),
          ),
          IconButton(
            tooltip: '注册到 daemon 调度',
            onPressed: _scheduleToDaemon,
            icon: const Icon(Icons.schedule),
          ),
          IconButton(
            tooltip: '运行',
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          InteractiveViewer(
            minScale: 0.3,
            maxScale: 2.5,
            boundaryMargin: const EdgeInsets.all(2000),
            constrained: false,
            child: SizedBox(
              width: 4000,
              height: 3000,
              child: CustomPaint(
                painter: _GridPainter(
                  cellSize: _kCellSize,
                  theme: Theme.of(context),
                ),
                child: Stack(
                  children: <Widget>[
                    for (final connection in _connections)
                      _ConnectionEdge(
                        source: _nodeCenter(connection.sourceNodeId),
                        target: _nodeCenter(connection.targetNodeId),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    for (final node in _nodes)
                      _DraggableNodeCard(
                        node: node,
                        executionState: _nodeExecution[node.id],
                        isSelected: _selectedNodeId == node.id,
                        isPendingSource: _pendingConnectionSource == node.id,
                        onMoved: (delta) => _onNodeMoved(node.id, delta),
                        onTap: () => _editNode(node.id),
                        onLongPress: () {
                          setState(() {
                            _selectedNodeId = node.id;
                            _startConnection(node.id);
                          });
                        },
                        onDelete: () => _deleteNode(node.id),
                        onConnectFinish: () => _finishConnection(node.id),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_pendingConnectionSource != null)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.inverseSurface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '点击另一个节点完成连线（$_pendingConnectionSource → ?）',
                    style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Offset? _nodeCenter(String id) {
    final index = _nodes.indexWhere((n) => n.id == id);
    if (index < 0) {
      return null;
    }
    final node = _nodes[index];
    return Offset(node.position.x + _kNodeWidth / 2, node.position.y + _kNodeHeight / 2);
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.cellSize, required this.theme});

  final double cellSize;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..color = theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
    for (double x = 0; x < size.width; x += cellSize) {
      for (double y = 0; y < size.height; y += cellSize) {
        canvas.drawCircle(Offset(x, y), 1.5, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.cellSize != cellSize || oldDelegate.theme != theme;
}

class _ConnectionEdge extends StatelessWidget {
  const _ConnectionEdge({required this.source, required this.target, required this.color});

  final Offset? source;
  final Offset? target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _EdgePainter(source: source, target: target, color: color),
        size: const Size(4000, 3000),
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.source, required this.target, required this.color});

  final Offset? source;
  final Offset? target;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final src = source;
    final dst = target;
    if (src == null || dst == null) {
      return;
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(src.dx, src.dy);
    final dx = (dst.dx - src.dx).abs() / 2;
    path.cubicTo(
      src.dx + dx,
      src.dy,
      dst.dx - dx,
      dst.dy,
      dst.dx,
      dst.dy,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) =>
      oldDelegate.source != source ||
      oldDelegate.target != target ||
      oldDelegate.color != color;
}

class _DraggableNodeCard extends StatefulWidget {
  const _DraggableNodeCard({
    required this.node,
    required this.isSelected,
    required this.isPendingSource,
    required this.onMoved,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
    required this.onConnectFinish,
    this.executionState,
  });

  final WorkflowNodeModel node;
  final bool isSelected;
  final bool isPendingSource;
  final String? executionState;
  final void Function(Offset delta) onMoved;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onConnectFinish;

  @override
  State<_DraggableNodeCard> createState() => _DraggableNodeCardState();
}

class _DraggableNodeCardState extends State<_DraggableNodeCard> {
  Offset _dragStart = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = _nodeStyle(widget.node.kind, scheme);
    final executionColor = switch (widget.executionState) {
      'success' => Colors.green,
      'failed' => Colors.red,
      'skipped' => Colors.orange,
      _ => null,
    };
    final borderColor = widget.isPendingSource
        ? scheme.tertiary
        : executionColor ??
            (widget.isSelected ? style.color : style.border);
    return Positioned(
      left: widget.node.position.x,
      top: widget.node.position.y,
      width: _kNodeWidth,
      height: _kNodeHeight,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onPanStart: (details) => _dragStart = details.globalPosition,
        onPanUpdate: (details) {
          final delta = details.globalPosition - _dragStart;
          _dragStart = details.globalPosition;
          widget.onMoved(delta);
        },
        onPanEnd: (_) => widget.onConnectFinish(),
        child: Container(
          decoration: BoxDecoration(
            color: style.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: widget.isSelected || widget.isPendingSource || executionColor != null
                  ? 2.5
                  : 1.5,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: <Widget>[
              Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(style.icon, size: 18, color: style.color),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.node.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: style.text),
                      ),
                    ),
                  ],
                ),
              ),
              if (executionColor != null)
                Positioned(
                  top: 4,
                  left: 4,
                  child: Icon(
                    widget.executionState == 'failed' ? Icons.error : Icons.check_circle,
                    size: 14,
                    color: executionColor,
                  ),
                ),
              if (widget.isSelected)
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: widget.onDelete,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.close, size: 12, color: scheme.onErrorContainer),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeStyle {
  const _NodeStyle(this.color, this.border, this.background, this.icon, this.text);

  final Color color;
  final Color border;
  final Color background;
  final IconData icon;
  final Color text;
}

_NodeStyle _nodeStyle(WorkflowNodeKind kind, ColorScheme scheme) {
  switch (kind) {
    case WorkflowNodeKind.trigger:
      return _NodeStyle(
        scheme.primary,
        scheme.primary.withValues(alpha: 0.6),
        scheme.primaryContainer.withValues(alpha: 0.25),
        Icons.flag,
        scheme.onSurface,
      );
    case WorkflowNodeKind.execute:
      return _NodeStyle(
        scheme.tertiary,
        scheme.tertiary.withValues(alpha: 0.6),
        scheme.tertiaryContainer.withValues(alpha: 0.25),
        Icons.play_arrow,
        scheme.onSurface,
      );
    case WorkflowNodeKind.condition:
      return _NodeStyle(
        scheme.error,
        scheme.error.withValues(alpha: 0.6),
        scheme.errorContainer.withValues(alpha: 0.25),
        Icons.call_split,
        scheme.onSurface,
      );
    case WorkflowNodeKind.logic:
      return _NodeStyle(
        scheme.secondary,
        scheme.secondary.withValues(alpha: 0.6),
        scheme.secondaryContainer.withValues(alpha: 0.25),
        Icons.merge,
        scheme.onSurface,
      );
    case WorkflowNodeKind.extract:
      return _NodeStyle(
        const Color(0xFF00897B),
        const Color(0xFF00897B).withValues(alpha: 0.6),
        const Color(0xFF00897B).withValues(alpha: 0.18),
        Icons.data_object,
        scheme.onSurface,
      );
  }
}
