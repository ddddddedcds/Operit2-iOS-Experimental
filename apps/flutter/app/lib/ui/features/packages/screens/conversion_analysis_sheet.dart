// 插件「转换分析」面板：安装前展示安卓依赖 / 路径转化 / 版本限制，
// 让用户清楚一个安卓插件在 iOS 上能否直接用、怎么转化。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../../core/proxy/generated/CoreProxyClients.g.dart';
import '../../../../core/proxy/generated/CoreProxyModels.g.dart' as core_proxy;
import '../market/ArtifactMarketSupport.dart';
import 'ArtifactProjectNodeTreeDialog.dart';

/// 结构化转换报告（由 Rust `analyzeToolPkgConversion` 返回的 JSON 反序列化）。
class ToolPkgConversionReport {
  final List<String> androidApiTokens;
  final int pathLiteralCount;
  final bool needsPathRewrite;
  final bool hasFrameworkApis;
  final String verdict; // direct | path_rewrite | android_framework

  const ToolPkgConversionReport({
    required this.androidApiTokens,
    required this.pathLiteralCount,
    required this.needsPathRewrite,
    required this.hasFrameworkApis,
    required this.verdict,
  });

  factory ToolPkgConversionReport.fromJson(Map<String, Object?> json) {
    return ToolPkgConversionReport(
      androidApiTokens: (json['androidApiTokens'] as List<Object?>? ?? [])
          .map((e) => e.toString())
          .toList(),
      pathLiteralCount: (json['pathLiteralCount'] as num? ?? 0).toInt(),
      needsPathRewrite: json['needsPathRewrite'] as bool? ?? false,
      hasFrameworkApis: json['hasFrameworkApis'] as bool? ?? false,
      verdict: json['verdict'] as String? ?? 'direct',
    );
  }
}

/// 下载指定版本的资产到临时文件，调用 core 分析，返回报告。
/// 失败时返回 null。临时文件无论成败都会清理。
Future<ToolPkgConversionReport?> fetchConversionReport({
  required GeneratedCoreProxyClients clients,
  required core_proxy.MarketEntrySummary entry,
  String? versionId,
}) async {
  core_proxy.MarketEntryVersion? version;
  if (entry.type == 'script' || entry.type == 'package') {
    if (versionId != null) {
      version = entry.versions.where((v) => v.id == versionId).firstOrNull;
    }
    version ??= entry.latestVersion;
  }
  final vid = version?.id;
  final asset = vid != null
      ? entry.assets.where((a) => a.versionId == vid).firstOrNull
      : null;
  final target = asset ?? entry.assets.firstOrNull;
  if (target == null) return null;

  final tempDir = await getTemporaryDirectory();
  final file =
      File('${tempDir.path}/operit_cvt_${entry.id}_${vid ?? 'latest'}.tmp');
  try {
    final resp = await http
        .get(Uri.parse(target.url), headers: {'User-Agent': 'Mozilla/5.0'})
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) return null;
    await file.writeAsBytes(resp.bodyBytes);
    final jsonStr =
        await clients.application.packageManager().analyzeToolPkgConversion(toolpkgPath: file.path).timeout(const Duration(seconds: 60));
    final decoded = jsonDecode(jsonStr) as Map<String, Object?>;
    return ToolPkgConversionReport.fromJson(decoded);
  } catch (_) {
    return null;
  } finally {
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// 入口：对 artifact 类条目先让用户选版本，再打开分析面板。
Future<void> showConversionAnalysis(
  BuildContext context, {
  required GeneratedCoreProxyClients clients,
  required core_proxy.MarketEntrySummary entry,
}) async {
  String? versionId;
  if ((entry.type == 'script' || entry.type == 'package') &&
      entry.artifact != null &&
      entry.versions.isNotEmpty) {
    final selection = await showArtifactVersionListDialog(context, entry: entry);
    if (selection == null || !context.mounted) return;
    versionId = selection.detail.versionId;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ConversionAnalysisSheet(
      clients: clients,
      entry: entry,
      versionId: versionId,
    ),
  );
}

class _ConversionAnalysisSheet extends StatefulWidget {
  const _ConversionAnalysisSheet({
    required this.clients,
    required this.entry,
    required this.versionId,
  });

  final GeneratedCoreProxyClients clients;
  final core_proxy.MarketEntrySummary entry;
  final String? versionId;

  @override
  State<_ConversionAnalysisSheet> createState() => _ConversionAnalysisSheetState();
}

class _ConversionAnalysisSheetState extends State<_ConversionAnalysisSheet> {
  ToolPkgConversionReport? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final report = await fetchConversionReport(
        clients: widget.clients,
        entry: widget.entry,
        versionId: widget.versionId,
      );
      if (!mounted) return;
      if (report == null) {
        setState(() {
          _loading = false;
          _error = '无法下载或解析该插件资产';
        });
      } else {
        setState(() {
          _loading = false;
          _report = report;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            '转换分析 · ${widget.entry.title}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      )
                    : report == null
                        ? const Center(child: Text('无分析结果'))
                        : SingleChildScrollView(
                            child: _ReportBody(report: report, entry: widget.entry),
                          ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.entry});

  final ToolPkgConversionReport report;
  final core_proxy.MarketEntrySummary entry;

  (Color, String, String) _verdictInfo() {
    switch (report.verdict) {
      case 'path_rewrite':
        return (
          Colors.blue,
          '路径自动转化',
          '包含安卓外部存储路径字面量，安装时会被静默重写到 iOS 兼容目录，安装后可直接使用。'
        );
      case 'android_framework':
        return (
          Colors.orange,
          '依赖安卓框架',
          '调用了安卓运行时 API，安装可成功，但相关功能在 iOS 上不可用（路径部分仍会被转化）。'
        );
      default:
        return (
          Colors.green,
          '可直接使用',
          '未发现安卓专属依赖，在 iOS 上可直接安装使用。'
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (color, label, desc) = _verdictInfo();
    final version = report.hasFrameworkApis
        ? entry.versions.where((v) => v.id == entry.latestVersion?.id).firstOrNull ??
            entry.latestVersion
        : entry.latestVersion;
    final minApp = version?.minAppVer ?? '';
    final maxApp = version?.maxAppVer ?? '';
    final current = currentAppVersion;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 兼容性结论
        _Badge(color: color, label: label),
        const SizedBox(height: 4),
        Text(desc, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        // 2. 安卓 API 检测
        _SectionTitle('安卓 API 检测'),
        report.androidApiTokens.isEmpty
            ? const Text('无', style: TextStyle(color: Colors.green))
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                children: report.androidApiTokens
                    .map((t) => Chip(
                          label: Text(t, style: const TextStyle(fontSize: 12)),
                          backgroundColor: Colors.orange.withValues(alpha: 0.15),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
        const SizedBox(height: 16),
        // 3. 路径转化
        _SectionTitle('路径转化'),
        Text(
          report.pathLiteralCount > 0
              ? '检测到 ${report.pathLiteralCount} 处 /sdcard/ 或 /storage/emulated/0/ 字面量。'
                  ' 安装时这些路径会被静默重写到 /var/mobile/.operit/runtime/android-compat/，'
                  '插件无需修改即可在 iOS 读写数据。'
              : '未发现硬编码的安卓外部存储路径。',
        ),
        const SizedBox(height: 16),
        // 4. 能否直接使用
        _SectionTitle('能否直接使用'),
        Text(_usableText()),
        const SizedBox(height: 16),
        // 5. 版本限制
        _SectionTitle('版本限制'),
        Text(
          '当前客户端 v$current'
          '${minApp.isEmpty && maxApp.isEmpty ? ' · 该版本未声明客户端版本上下限' : ''}'
          '${minApp.isNotEmpty ? ' · 要求最低 v$minApp' : ''}'
          '${maxApp.isNotEmpty ? ' · 要求最高 v$maxApp' : ''}',
        ),
        const SizedBox(height: 4),
        const Text(
          '注：operit2 安装时会强制跳过客户端版本校验，下方仅为兼容性提示。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  String _usableText() {
    switch (report.verdict) {
      case 'android_framework':
        return '不能完整使用：依赖安卓框架运行时的功能在 iOS 上会失效，'
            '其余部分（及路径）可正常转化使用。';
      case 'path_rewrite':
        return '可以：路径被自动转化，功能不受影响。';
      default:
        return '可以：无安卓专属依赖。';
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(label,
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
      );
}
