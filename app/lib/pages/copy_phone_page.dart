import 'package:flutter/material.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/photo_manager_filter.dart';
import 'package:localsend_app/widget/glass/glass_card.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

enum _CopyCategory { images, videos, audio, documents, downloads }

extension on _CopyCategory {
  String get label => switch (this) {
    _CopyCategory.images => 'Images',
    _CopyCategory.videos => 'Videos',
    _CopyCategory.audio => 'Audio',
    _CopyCategory.documents => 'Documents',
    _CopyCategory.downloads => 'Downloads',
  };
}

class CopyPhonePage extends StatefulWidget {
  const CopyPhonePage({super.key});

  @override
  State<CopyPhonePage> createState() => _CopyPhonePageState();
}

class _CopyPhonePageState extends State<CopyPhonePage> with Refena {
  final Map<_CopyCategory, Future<List<Object>>> _loads = {};
  final Set<_CopyCategory> _selected = {};
  final Map<_CopyCategory, List<Object>> _loaded = {};
  final Map<_CopyCategory, int> _sizes = {};
  bool _starting = false;

  Future<List<Object>> _load(_CopyCategory category) async {
    try {
      if (category == _CopyCategory.images || category == _CopyCategory.videos || category == _CopyCategory.audio) {
        final type = switch (category) {
          _CopyCategory.images => RequestType.image,
          _CopyCategory.videos => RequestType.video,
          _CopyCategory.audio => RequestType.audio,
          _ => RequestType.common,
        };
        final permission = await PhotoManager.requestPermissionExtend(
          requestOption: PermissionRequestOption(androidPermission: AndroidPermission(type: type, mediaLocation: false)),
        );
        if (!permission.isAuth) return [];
        final albums = await PhotoManager.getAssetPathList(
          type: type,
          filterOption: newestFirstPhotoFilter(),
        );
        if (albums.isEmpty) return [];
        final assets = <AssetEntity>[];
        for (var page = 0; ; page++) {
          final batch = await albums.first.getAssetListPaged(page: page, size: 500);
          if (batch.isEmpty) break;
          assets.addAll(batch);
          if (batch.length < 500) break;
        }
        return assets;
      }
      return await android_channel.queryMediaFilesAndroid(category: category.name);
    } catch (_) {
      return [];
    }
  }

  Future<void> _toggle(_CopyCategory category, bool selected) async {
    if (selected) {
      _loads.putIfAbsent(category, () => _load(category));
      final values = await _loads[category]!;
      if (!mounted) return;
      var totalSize = 0;
      for (final item in values) {
        if (item is AssetEntity) {
          totalSize += (await CrossFileConverters.convertAssetEntity(item)).size;
        } else if (item is android_channel.FileInfo) {
          totalSize += item.size;
        }
      }
      if (!mounted) return;
      setState(() {
        _loaded[category] = values;
        _sizes[category] = totalSize;
        _selected.add(category);
      });
    } else {
      setState(() => _selected.remove(category));
    }
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    for (final category in _selected) {
      final items = _loaded[category] ?? await (_loads[category] ??= _load(category));
      if (items.isNotEmpty && items.first is AssetEntity) {
        await ref
            .redux(selectedSendingFilesProvider)
            .dispatchAsync(
              AddFilesAction<AssetEntity>(
                files: items.cast<AssetEntity>(),
                converter: CrossFileConverters.convertAssetEntity,
              ),
            );
      } else if (items.isNotEmpty && items.first is android_channel.FileInfo) {
        await ref
            .redux(selectedSendingFilesProvider)
            .dispatchAsync(
              AddFilesAction<android_channel.FileInfo>(
                files: items.cast<android_channel.FileInfo>(),
                converter: CrossFileConverters.convertFileInfo,
              ),
            );
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  int _size(_CopyCategory category) => _sizes[category] ?? 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Copy Phone')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final category in _CopyCategory.values)
                  GlassCard(
                    margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    radius: 20,
                    child: CheckboxListTile(
                      value: _selected.contains(category),
                      onChanged: (value) => _toggle(category, value ?? false),
                      title: Text(category.label),
                      subtitle: _selected.contains(category)
                          ? Text('${(_loaded[category] ?? []).length} items · ${_size(category).asReadableFileSize}')
                          : const Text('Select to include'),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selected.isEmpty || _starting ? null : _start,
                  icon: _starting ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                  label: const Text('Start'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
