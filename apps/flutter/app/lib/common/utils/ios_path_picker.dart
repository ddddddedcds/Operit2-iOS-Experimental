// ignore_for_file: file_names

import 'package:flutter/material.dart';

/// iOS 没有系统文件/目录选择器，统一改用文本框让用户输入完整路径。
///
/// 调用方应先判断 [Platform.isIOS] 再使用本函数；非 iOS 平台仍走
/// `file_selector` 的 `getDirectoryPath` / `getSaveLocation`。
Future<String?> promptPathInput(
  BuildContext context, {
  required String title,
  required String hint,
  String? initialText,
}) async {
  final controller = TextEditingController(text: initialText);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(
            controller.text.trim(),
          ),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
