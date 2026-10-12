import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/browser/browser_surface.dart';
import 'package:localsend_app/provider/storage_stats_provider.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';

class StorageStatisticsCard extends StatefulWidget {
  final int refreshKey;
  final VoidCallback onRetry;

  const StorageStatisticsCard({required this.refreshKey, required this.onRetry, super.key});

  @override
  State<StorageStatisticsCard> createState() => _StorageStatisticsCardState();
}

class _StorageStatisticsCardState extends State<StorageStatisticsCard> {
  @override
  Widget build(BuildContext context) {
    final stats = context.ref.watch(storageStatsProvider(widget.refreshKey));
    return SizedBox(
      height: 104,
      child: BrowserSurface(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        borderRadius: BorderRadius.circular(glassRadiusCard),
        child: stats.when(
          loading: () => const _LoadingStorageStats(),
          error: (_, _) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(BrowserStrings.storageUnavailable),
              TextButton(
                onPressed: widget.onRetry,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(BrowserStrings.retry),
              ),
            ],
          ),
          data: (value) => _StorageStatsContent(stats: value),
        ),
      ),
    );
  }
}

class _StorageStatsContent extends StatelessWidget {
  final StorageStats stats;

  const _StorageStatsContent({required this.stats});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(Icons.storage_outlined, size: 14, color: BrowserThemeTokens.of(context).icon),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                '${BrowserStrings.storage}: ${stats.total.asReadableFileSize}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.sd_storage_outlined, size: 14, color: BrowserThemeTokens.of(context).icon),
            const SizedBox(width: 3),
            Text(
              '${BrowserStrings.available}: ${stats.free.asReadableFileSize}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        _SegmentedStorageBar(stats: stats),
        Row(
          children: [
            Expanded(
              child: _StorageLegend(label: BrowserStrings.photos, value: stats.photos, color: BrowserStorageColors.photos),
            ),
            Expanded(
              child: _StorageLegend(label: BrowserStrings.music, value: stats.audio, color: BrowserStorageColors.audio),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _StorageLegend(label: BrowserStrings.videos, value: stats.videos, color: BrowserStorageColors.videos),
            ),
            Expanded(
              child: _StorageLegend(label: BrowserStrings.docs, value: stats.docs, color: BrowserStorageColors.docs),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _StorageLegend(label: BrowserStrings.others, value: stats.others, color: BrowserStorageColors.others),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ],
    );
  }
}

class _SegmentedStorageBar extends StatelessWidget {
  final StorageStats stats;

  const _SegmentedStorageBar({required this.stats});

  @override
  Widget build(BuildContext context) {
    final categories = [
      (stats.photos, BrowserStorageColors.photos),
      (stats.videos, BrowserStorageColors.videos),
      (stats.others, BrowserStorageColors.others),
      (stats.audio, BrowserStorageColors.audio),
      (stats.docs, BrowserStorageColors.docs),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (stats.total <= 0) {
            return Container(height: 9, color: BrowserThemeTokens.of(context).surfaceElevated);
          }
          final segments = categories.where((segment) => segment.$1 > 0).map((segment) {
            return Container(
              width: constraints.maxWidth * (segment.$1 / stats.total),
              height: 9,
              color: segment.$2,
            );
          });
          return Row(
            children: [
              ...segments,
              Expanded(
                child: Container(height: 9, color: BrowserThemeTokens.of(context).surfaceElevated),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StorageLegend extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StorageLegend({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '$label ${value.asReadableFileSize}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

class _LoadingStorageStats extends StatelessWidget {
  const _LoadingStorageStats();

  @override
  Widget build(BuildContext context) {
    final skeleton = BrowserThemeTokens.of(context).surfaceElevated;
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(BrowserStrings.calculating),
        ),
        Container(
          height: 9,
          decoration: BoxDecoration(color: skeleton, borderRadius: BorderRadius.circular(999)),
        ),
        for (var row = 0; row < 3; row++)
          Row(
            children: [
              Expanded(child: Container(height: 9, color: skeleton)),
              const SizedBox(width: 16),
              Expanded(child: Container(height: 9, color: skeleton)),
            ],
          ),
      ],
    );
  }
}
