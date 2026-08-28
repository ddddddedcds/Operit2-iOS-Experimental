// ignore_for_file: file_names

import 'package:flutter/material.dart';

import '../../../../core/proxy/generated/CoreProxyModels.g.dart' as core_proxy;
import '../market/ArtifactMarketSupport.dart';

class ArtifactVersionAssetDetail {
  const ArtifactVersionAssetDetail({
    required this.versionId,
    required this.version,
    required this.formatVer,
    required this.minAppVer,
    required this.maxAppVer,
    required this.publishedAt,
    required this.assetUrl,
    required this.assetKind,
  });

  final String versionId;
  final String version;
  final String formatVer;
  final String minAppVer;
  final String? maxAppVer;
  final String? publishedAt;
  final String assetUrl;
  final String assetKind;
}

class ArtifactVersionSelection {
  const ArtifactVersionSelection(this.detail, this.ignoreVersionCheck);

  final ArtifactVersionAssetDetail detail;
  final bool ignoreVersionCheck;
}

class ArtifactVersionListDialog extends StatelessWidget {
  const ArtifactVersionListDialog({
    super.key,
    required this.entry,
  });

  final core_proxy.MarketEntrySummary entry;

  MarketAppVersionCompatibility? _compatibilityOf(
      ArtifactVersionAssetDetail version) {
    return resolveMarketAppVersionCompatibility(
      appVersion: currentAppVersion,
      minAppVersion: version.minAppVer,
      maxAppVersion: version.maxAppVer,
    );
  }

  void _confirmIgnoreVersion(
      BuildContext context, ArtifactVersionAssetDetail version) {
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('仍然安装此版本？'),
        content: Text(
          '该版本要求客户端版本 ${_formatVersionRange(version.minAppVer, version.maxAppVer)}，'
          '但当前客户端为 $currentAppVersion，可能无法正常工作。确定仍要安装吗？',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('仍然安装'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && context.mounted) {
        Navigator.of(context).pop(ArtifactVersionSelection(version, true));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final versions = _versionAssets(entry);
    final latestVersionId = entry.latestVersion?.id ?? '';
    ArtifactVersionAssetDetail? latestVersion;
    for (final version in versions) {
      if (version.versionId == latestVersionId) {
        latestVersion = version;
        break;
      }
    }
    latestVersion ??= versions.isNotEmpty ? versions.first : null;
    final anyIncompatible =
        versions.where((version) => _compatibilityOf(version) != null).isNotEmpty;

    return AlertDialog(
      title: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
      contentPadding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: 520,
        child: Column(
          children: <Widget>[
            if (anyIncompatible)
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                color: colorScheme.errorContainer.withOpacity(0.35),
                child: Text(
                  '当前客户端版本 $currentAppVersion 高于该资源支持的最高版本，'
                  '所选版本可能无法正常工作。如仍要安装，点按带警告的版本或下方按钮。',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                  ),
                ),
              ),
            Expanded(
              child: versions.isEmpty
                  ? Center(
                      child: Text(
                        '暂无可用版本',
                        style: textTheme.bodyMedium,
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(top: 8),
                      itemCount: versions.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final version = versions[index];
                        final isLatest = version.versionId == latestVersionId ||
                            (latestVersionId.isEmpty && index == 0);
                        final compatibility = _compatibilityOf(version);

                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Icon(
                            isLatest ? Icons.check_circle : Icons.circle_outlined,
                            color: isLatest ? colorScheme.primary : colorScheme.outline,
                          ),
                          title: Row(
                            children: <Widget>[
                              Text(
                                version.version.isNotEmpty ? version.version : 'v?',
                                style: textTheme.titleSmall,
                              ),
                              if (isLatest) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    '最新',
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (version.publishedAt != null)
                                Text(
                                  formatMarketDate(version.publishedAt!),
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.outline,
                                  ),
                                ),
                              if (version.minAppVer.isNotEmpty ||
                                  (version.maxAppVer?.isNotEmpty ?? false))
                                Text(
                                  _formatVersionRange(
                                      version.minAppVer, version.maxAppVer),
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (version.assetKind.trim().isNotEmpty)
                                Text(
                                  version.assetKind,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.outline,
                                  ),
                                ),
                              if (compatibility != null)
                                Text(
                                  compatibility.message,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.error,
                                  ),
                                ),
                            ],
                          ),
                          enabled: true,
                          onTap: () {
                            if (compatibility == null) {
                              Navigator.of(context)
                                  .pop(ArtifactVersionSelection(version, false));
                            } else {
                              _confirmIgnoreVersion(context, version);
                            }
                          },
                        );
                      },
                    ),
            ),
            if (anyIncompatible && latestVersion != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: FilledButton.tonal(
                  onPressed: () {
                    Navigator.of(context)
                        .pop(ArtifactVersionSelection(latestVersion!, true));
                  },
                  child: const Text('忽略版本限制并安装最新版'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<ArtifactVersionAssetDetail> _versionAssets(core_proxy.MarketEntrySummary entry) {
    final assetsByVersionId = <String, core_proxy.MarketEntryAsset>{
      for (final asset in entry.assets) asset.versionId: asset,
    };
    final versions = entry.versions
        .map((version) {
          final asset = assetsByVersionId[version.id];
          return ArtifactVersionAssetDetail(
            versionId: version.id,
            version: version.version,
            formatVer: version.formatVer,
            minAppVer: version.minAppVer,
            maxAppVer: version.maxAppVer,
            publishedAt: version.publishedAt,
            assetUrl: asset?.url ?? '',
            assetKind: asset?.kind ?? '',
          );
        })
        .toList(growable: false);
    return versions.reversed.toList(growable: false);
  }

  String _formatVersionRange(String min, String? max) {
    final minStr = min.trim();
    final maxStr = (max ?? '').trim();
    if (minStr.isNotEmpty && maxStr.isNotEmpty) {
      return '$minStr - $maxStr';
    }
    if (maxStr.isNotEmpty) {
      return '≤ $maxStr';
    }
    return '$minStr+';
  }
}

/// Show a linear version list dialog and return the selected version detail.
/// [ArtifactVersionSelection.ignoreVersionCheck] is true when the user chose to
/// install a version that the current client build does not officially support.
Future<ArtifactVersionSelection?> showArtifactVersionListDialog(
  BuildContext context, {
  required core_proxy.MarketEntrySummary entry,
}) {
  return showDialog<ArtifactVersionSelection>(
    context: context,
    builder: (context) => ArtifactVersionListDialog(entry: entry),
  );
}
