// Waifu-mode typing indicator: when waifu mode is on, an AI reply gets a
// lightweight sentence-by-sentence "typing" pulse while streaming, and a
// final fade-in once complete. It does NOT slice the rendered markdown
// (sentences do not map 1:1 to markdown nodes); it only drives reveal
// rhythm so the existing streaming renderer stays untouched.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../../../core/bridge/ProxyCoreRuntimeBridge.dart';
import '../../../../../../core/proxy/WaifuSplitter.dart';

class WaifuTypewriterReveal extends StatefulWidget {
  const WaifuTypewriterReveal({
    super.key,
    required this.enabled,
    required this.isStreaming,
    required this.content,
    required this.child,
    this.splitter,
    this.charDelayMs = 18,
    this.sentenceGapMs = 260,
  });

  /// Whether waifu mode is active for this message.
  final bool enabled;

  /// True while the reply is still streaming.
  final bool isStreaming;

  /// The completed text content (used for sentence splitting).
  final String content;

  /// The already-rendered markdown widget.
  final Widget child;

  /// Bridge wrapper used to split sentences in the Rust core.
  final WaifuSplitter? splitter;

  /// Per-character delay when revealing a sentence.
  final int charDelayMs;

  /// Extra pause between sentences.
  final int sentenceGapMs;

  @override
  State<WaifuTypewriterReveal> createState() => _WaifuTypewriterRevealState();
}

class _WaifuTypewriterRevealState extends State<WaifuTypewriterReveal>
    with SingleTickerProviderStateMixin {
  List<String> _sentences = const <String>[];
  int _revealed = 0;
  bool _splitDone = false;
  Timer? _revealTimer;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _kickOff();
  }

  @override
  void didUpdateWidget(covariant WaifuTypewriterReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content != oldWidget.content ||
        (oldWidget.isStreaming && !widget.isStreaming)) {
      _kickOff();
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _kickOff() async {
    _revealTimer?.cancel();
    final splitter = widget.splitter ??
        const WaifuSplitter(ProxyCoreRuntimeBridge());
    if (!widget.enabled || widget.content.isEmpty) {
      setState(() {
        _sentences = const <String>[];
        _revealed = 0;
        _splitDone = false;
      });
      return;
    }
    setState(() => _splitDone = false);
    List<String> sentences;
    try {
      sentences = await splitter.splitMessageBySentences(widget.content);
    } catch (_) {
      sentences = const <String>[];
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sentences = sentences;
      _revealed = sentences.isEmpty ? 0 : 1;
      _splitDone = true;
    });
    if (sentences.isEmpty || widget.isStreaming) {
      return;
    }
    _revealTimer = Timer.periodic(
      Duration(milliseconds: widget.sentenceGapMs),
      (_) {
        if (!mounted || _revealed >= _sentences.length) {
          _revealTimer?.cancel();
          return;
        }
        setState(() => _revealed++);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || widget.isStreaming) {
      return widget.child;
    }
    final visible = _sentences.isEmpty
        ? 1.0
        : (_revealed / _sentences.length).clamp(0.0, 1.0);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The rendered markdown (fully present), wrapped with a sentence
        // reveal pulse: opacity ramps in proportion to revealed sentences.
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.2, end: visible),
          duration: Duration(milliseconds: widget.charDelayMs * 6 + 80),
          curve: Curves.easeOut,
          builder: (context, opacity, child) =>
              Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
          child: widget.child,
        ),
        if (_splitDone && visible < 1.0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FadeTransition(
              opacity: _pulseController,
              child: Text(
                '$_revealed/${_sentences.length} · typing…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
