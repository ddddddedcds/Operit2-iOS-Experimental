// Waifu-mode sentence splitting: thin Dart wrapper around the Rust
// `WaifuMessageProcessor` exposed through the runtime bridge as
// `waifu.splitMessageBySentences` (dispatched in LocalCoreProxy without
// touching generated codegen).

import '../bridge/OperitRuntimeBridge.dart';
import '../link/CoreLinkProtocol.dart';

class WaifuSplitter {
  const WaifuSplitter(this.bridge);

  final OperitRuntimeBridge bridge;

  /// Splits a full AI reply into sentence chunks (waifu typing rhythm).
  ///
  /// Returns the sentences in order; punctuation is preserved unless
  /// [removePunctuation] is true.
  Future<List<String>> splitMessageBySentences(
    String content, {
    bool removePunctuation = false,
  }) async {
    final value = await bridge.call(
      CoreCallRequest(
        requestId: _waifuRequestId(),
        targetPath: const CoreObjectPath(<String>['waifu']),
        methodName: 'splitMessageBySentences',
        args: <String, Object?>{
          'content': content,
          'removePunctuation': removePunctuation,
        },
      ),
    );
    if (value is List) {
      return value
          .map((item) => item.toString())
          .toList(growable: false);
    }
    return const <String>[];
  }

  static String _waifuRequestId() {
    return 'waifu-split-${DateTime.now().microsecondsSinceEpoch}';
  }
}
