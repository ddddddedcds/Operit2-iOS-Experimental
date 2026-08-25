// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/proxy/CustomEmojiStore.dart';
import '../../../core/proxy/WaifuRuntime.dart';
import 'MarkdownAudioRenderer.dart';
import 'MarkdownVideoRenderer.dart';

/// Maps a waifu emotion name to a bundled jpg asset path. Using jpg avoids
/// webp/gif loading compatibility issues on iOS. Unknown emotions return null.
String? resolveEmojiAsset(String emotion) {
  const assetRoot = 'assets/emoji';
  const map = <String, String>{
    'angry': 'angry/angry_1.jpg',
    'confused': 'confused/confused_1.jpg',
    'crying': 'crying/crying_1.jpg',
    'happy': 'happy/happy_1.jpg',
    'like_you': 'like_you/like_you_1.jpg',
    'miss_you': 'miss_you/miss_you_3.jpg',
    'sad': 'sad/sad_1.jpg',
    'speechless': 'speechless/speechless_1.jpg',
    'surprised': 'surprised/surprised_4.jpg',
  };
  final key = emotion.toLowerCase().trim();
  final rel = map[key];
  return rel == null ? null : '$assetRoot/$rel';
}

class MarkdownImageRenderer extends StatelessWidget {
  const MarkdownImageRenderer({
    super.key,
    required this.imageMarkdown,
    required this.textColor,
    this.maxImageHeight = 140,
  });

  final String imageMarkdown;
  final Color textColor;
  final double maxImageHeight;

  @override
  Widget build(BuildContext context) {
    if (!isCompleteImageMarkdown(imageMarkdown)) {
      return SelectableText(
        imageMarkdown,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: textColor, height: 1.3),
      );
    }
    final imageAlt = extractMarkdownImageAlt(imageMarkdown);
    final imageUrl = extractMarkdownImageUrl(imageMarkdown);
    if (isLikelyVideoUrl(imageUrl)) {
      return MarkdownVideoRenderer(
        videoMarkdown: imageMarkdown,
        textColor: textColor,
        maxVideoHeight: maxImageHeight,
      );
    }
    if (isLikelyAudioUrl(imageUrl)) {
      return MarkdownAudioRenderer(
        audioMarkdown: imageMarkdown,
        textColor: textColor,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxImageHeight),
          child: _MarkdownImageBody(imageUrl: imageUrl, imageAlt: imageAlt),
        ),
      ),
    );
  }
}

class _MarkdownImageBody extends StatelessWidget {
  const _MarkdownImageBody({required this.imageUrl, required this.imageAlt});

  final String imageUrl;
  final String imageAlt;

  @override
  Widget build(BuildContext context) {
    // emoji://<emotion> → local waifu emoji asset. Only rendered when waifu
    // mode is enabled; otherwise hidden (the tag is an internal protocol hint).
    final emojiName = _emojiSchemeName(imageUrl);
    if (emojiName != null) {
      if (!WaifuRuntime.enabled) {
        return const SizedBox.shrink();
      }
      return _EmojiAssetImage(emojiName: emojiName);
    }
    final dataBytes = _dataUriBytes(imageUrl);
    if (dataBytes != null) {
      return Image.memory(dataBytes, fit: BoxFit.contain);
    }
    return Image.network(
      imageUrl,
      fit: BoxFit.contain,
      semanticLabel: imageAlt.isEmpty ? null : imageAlt,
    );
  }

  /// Returns the emotion name for an `emoji://happy` URL, or null if not one.
  String? _emojiSchemeName(String url) {
    const prefix = 'emoji://';
    if (!url.startsWith(prefix)) return null;
    final name = url.substring(prefix.length).trim();
    return name.isEmpty ? null : name;
  }
}

/// Loads one waifu emoji for an emotion category. A user-imported custom emoji
/// (documents/custom_emoji/<category>/) wins over the bundled asset. Uses
/// FutureBuilder because custom emoji paths are read from SharedPreferences.
class _EmojiAssetImage extends StatelessWidget {
  const _EmojiAssetImage({required this.emojiName});

  final String emojiName;

  @override
  Widget build(BuildContext context) {
    final assetPath = resolveEmojiAsset(emojiName);
    final customPaths = CustomEmojiStore.customPathsFor(emojiName);
    Widget image;
    if (customPaths.isNotEmpty) {
      final f = File(customPaths.first);
      image = f.existsSync()
          ? Image.file(f, fit: BoxFit.contain, errorBuilder: _errorBuilder)
          : _builtInOrBlank(assetPath);
    } else {
      image = _builtInOrBlank(assetPath);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: image,
        ),
      ),
    );
  }

  Widget _builtInOrBlank(String? assetPath) {
    if (assetPath == null) {
      return const SizedBox.shrink();
    }
    return Image.asset(
      assetPath,
      fit: BoxFit.contain,
      errorBuilder: _errorBuilder,
    );
  }

  static Widget _errorBuilder(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) =>
      const SizedBox.shrink();
}

bool isCompleteImageMarkdown(String content) {
  return RegExp(r'^!\[[^\]]*\]\([^)]+\)$').hasMatch(content.trim());
}

String extractMarkdownImageAlt(String imageContent) {
  return RegExp(r'^!\[([^\]]*)\]').firstMatch(imageContent.trim())?.group(1) ??
      '';
}

String extractMarkdownImageUrl(String imageContent) {
  return RegExp(r'\]\(([^)]+)\)$').firstMatch(imageContent.trim())?.group(1) ??
      '';
}

Uint8List? _dataUriBytes(String imageUrl) {
  final match = RegExp(
    r'^data:image/[^;]+;base64,(.+)$',
    caseSensitive: false,
  ).firstMatch(imageUrl);
  if (match == null) {
    return null;
  }
  return base64Decode(match.group(1)!);
}
