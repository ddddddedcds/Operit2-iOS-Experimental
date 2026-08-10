//
//  ExternalAiBridge.dart
//
//  外部 AI 任务桥：iOS 快捷指令（URL scheme operit://ask?text=...）→ Swift
//  AppDelegate → MethodChannel('operit/ai') → 本桥 → core proxy sendUserMessage
//  → 主聊天 AI 执行，结果进入当前会话。
//

import 'package:flutter/services.dart';

import '../bridge/PlatformCoreProxy.dart';
import '../bridge/ProxyCoreRuntimeBridge.dart';
import '../proxy/generated/CoreProxyClients.g.dart';
import '../proxy/generated/CoreProxyModels.g.dart' as core_proxy;

/// 接收来自 iOS 原生（Swift）的 AI 任务注入。
class ExternalAiBridge {
  static const MethodChannel _channel = MethodChannel('operit/ai');
  static bool _installed = false;

  static void install() {
    if (_installed) {
      return;
    }
    _installed = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'ask') {
      final args = (call.arguments is Map) ? call.arguments as Map : const {};
      final text = (args['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        return 'empty';
      }
      const clients = GeneratedCoreProxyClients(
        ProxyCoreRuntimeBridge(coreProxy: platformCoreProxy),
      );
      await clients.chatRuntimeHolderMain.sendUserMessage(
        promptFunctionType: core_proxy.PromptFunctionType.chat,
        roleCardIdOverride: null,
        chatIdOverride: null,
        messageText: text,
        proxySenderNameOverride: null,
        chatProviderIdOverride: null,
        chatModelIdOverride: null,
        attachments: const [],
        replyToMessage: null,
        turnOptions: const core_proxy.ChatTurnOptions(
          persistTurn: true,
          notifyReply: null,
          hideUserMessage: false,
          disableWarning: false,
        ),
      );
      return 'ok';
    }
    return null;
  }
}
