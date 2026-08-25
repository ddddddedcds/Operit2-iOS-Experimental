// Waifu custom emoji management screen.
//
// Lets the user add their own emoji images per emotion category and remove
// them. Imported files are copied into documents/custom_emoji/<category>/ and
// referenced by the renderer (see MarkdownImageRenderer). Built-in emojis are
// bundled assets and shown as placeholders here.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/proxy/CustomEmojiStore.dart';

class CustomEmojiManagementScreen extends StatefulWidget {
  const CustomEmojiManagementScreen({super.key});

  @override
  State<CustomEmojiManagementScreen> createState() =>
      _CustomEmojiManagementScreenState();
}

class _CustomEmojiManagementScreenState
    extends State<CustomEmojiManagementScreen> {
  static const List<String> _categories = <String>[
    'happy',
    'sad',
    'angry',
    'confused',
    'crying',
    'surprised',
    'like_you',
    'miss_you',
    'speechless',
  ];

  @override
  void initState() {
    super.initState();
    if (!CustomEmojiStore.isLoaded) {
      CustomEmojiStore.load();
    }
  }

  Future<void> _pickAndAdd(String category) async {
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;
      final dest = await CustomEmojiStore.importImage(category, xfile.path);
      if (dest == null) {
        _showSnack('导入失败');
        return;
      }
      await CustomEmojiStore.addEmoji(category, dest);
      setState(() {});
      _showSnack('已添加 ${_labelOf(category)} 表情');
    } catch (e) {
      _showSnack('导入失败: $e');
    }
  }

  Future<void> _remove(String category, String path) async {
    await CustomEmojiStore.removeEmoji(category, path);
    setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 1)));
  }

  String _labelOf(String category) {
    const labels = <String, String>{
      'happy': '开心',
      'sad': '难过',
      'angry': '生气',
      'confused': '疑惑',
      'crying': '哭泣',
      'surprised': '惊讶',
      'like_you': '喜欢你',
      'miss_you': '想你',
      'speechless': '无语',
    };
    return labels[category] ?? category;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('自定义表情'), leading: const BackButton()),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            '给不同情绪添加你自己的表情图。AI 在 Waifu 模式下会根据情绪显示。',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          for (final category in _categories) ..._categoryCard(category),
        ],
      ),
    );
  }

  List<Widget> _categoryCard(String category) {
    final colorScheme = Theme.of(context).colorScheme;
    final paths = CustomEmojiStore.customPathsFor(category);
    final hasBuiltIn = resolveBuiltInEmojiName(category) != null;
    return <Widget>[
      Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    _labelOf(category),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _pickAndAdd(category),
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                    label: const Text('添加'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                hasBuiltIn
                    ? '包含内置表情 + ${paths.length} 个自定义'
                    : '${paths.length} 个自定义表情',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              if (paths.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final path in paths)
                      _emojiTile(path, category),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _emojiTile(String path, String category) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 72,
            height: 72,
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: colorScheme.surfaceVariant,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: InkWell(
            onTap: () => _remove(category, path),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: colorScheme.error.withValues(alpha: 0.85),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  /// Best-effort: returns the built-in asset filename for a category if any.
  String? resolveBuiltInEmojiName(String category) {
    switch (category) {
      case 'angry': return 'angry_1.jpg';
      case 'confused': return 'confused_1.jpg';
      case 'crying': return 'crying_1.jpg';
      case 'happy': return 'happy_1.jpg';
      case 'like_you': return 'like_you_1.jpg';
      case 'miss_you': return 'miss_you_3.jpg';
      case 'sad': return 'sad_1.jpg';
      case 'speechless': return 'speechless_1.jpg';
      case 'surprised': return 'surprised_4.jpg';
      default: return null;
    }
  }
}
