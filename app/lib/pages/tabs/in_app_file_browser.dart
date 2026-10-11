import 'dart:async';
import 'dart:typed_data';

import 'package:device_apps/device_apps.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/browser/browser_surface.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/apk_provider.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/param/cached_apk_provider_param.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

enum _BrowserCategory {
  downloads,
  apps,
  images,
  videos,
  audio,
  documents,
  text,
  files,
}

final _logger = Logger('InAppFileBrowser');

extension on _BrowserCategory {
  String get label => switch (this) {
    _BrowserCategory.downloads => BrowserStrings.downloads,
    _BrowserCategory.apps => BrowserStrings.apps,
    _BrowserCategory.images => BrowserStrings.images,
    _BrowserCategory.videos => BrowserStrings.videos,
    _BrowserCategory.audio => BrowserStrings.audio,
    _BrowserCategory.documents => BrowserStrings.documents,
    _BrowserCategory.text => BrowserStrings.text,
    _BrowserCategory.files => BrowserStrings.files,
  };

  IconData get icon => switch (this) {
    _BrowserCategory.downloads => Icons.download_outlined,
    _BrowserCategory.apps => Icons.apps_outlined,
    _BrowserCategory.images => Icons.image_outlined,
    _BrowserCategory.videos => Icons.movie_outlined,
    _BrowserCategory.audio => Icons.audio_file_outlined,
    _BrowserCategory.documents => Icons.description_outlined,
    _BrowserCategory.text => Icons.notes_outlined,
    _BrowserCategory.files => Icons.folder_outlined,
  };
}

class InAppFileBrowser extends StatefulWidget {
  final ValueChanged<bool>? onHeaderVisibilityChanged;
  final VoidCallback? onUserActivity;

  const InAppFileBrowser({
    this.onHeaderVisibilityChanged,
    this.onUserActivity,
    super.key,
  });

  @override
  State<InAppFileBrowser> createState() => _InAppFileBrowserState();
}

class _InAppFileBrowserState extends State<InAppFileBrowser> with Refena {
  static const _systemFilesPageSize = 100;
  _BrowserCategory _category = _BrowserCategory.downloads;
  final _textController = TextEditingController();
  final _categoryScrollController = ScrollController();
  final _categoryKeys = List<GlobalKey>.generate(
    _BrowserCategory.values.length,
    (_) => GlobalKey(),
  );
  final Map<String, Future<String>> _assetTitles = {};
  final Map<String, Future<int>> _assetCountFutures = {};
  Timer? _searchDebounce;
  String _searchQuery = '';
  bool _searchExpanded = false;
  bool _showAlbums = false;
  Future<List<AssetPathEntity>>? _assetPathsFuture;
  AssetPathEntity? _activeAssetPath;
  Future<List<AssetEntity>>? _assetsFuture;
  Future<List<android_channel.FileInfo>>? _systemFilesFuture;
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};
  final List<android_channel.FileInfo> _additionalSystemFiles = [];
  final List<AssetEntity> _additionalAssets = [];
  final List<(String, String)> _treeBreadcrumbs = [];
  String? _treeRootUri;
  String? _currentFolderUri;
  Future<List<android_channel.AndroidBrowseEntry>>? _treeEntriesFuture;
  int _systemFilesOffset = 0;
  int _assetPage = 0;
  bool _hasMoreSystemFiles = false;
  bool _hasMoreAssets = false;
  bool _loadingMoreAssets = false;
  bool _loadingMoreSystemFiles = false;
  bool _systemFilesPageError = false;
  bool _permissionRequired = false;
  String _saveLocation = 'internal';

  @override
  void initState() {
    super.initState();
    _systemFilesFuture = Future.value([]);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _initializeStorageTree(),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _textController.dispose();
    _categoryScrollController.dispose();
    super.dispose();
  }

  Future<void> _openCategory(_BrowserCategory category) async {
    widget.onUserActivity?.call();
    setState(() {
      _category = category;
      _additionalSystemFiles.clear();
      _systemFilesOffset = 0;
      _hasMoreSystemFiles = false;
      _loadingMoreSystemFiles = false;
      _systemFilesPageError = false;
      _permissionRequired = false;
    });
    if (category == _BrowserCategory.images) {
      _showAlbums = false;
      _activeAssetPath = null;
      _assetPathsFuture = _loadAssetPaths(category);
    } else if (category == _BrowserCategory.videos || category == _BrowserCategory.audio) {
      if (defaultTargetPlatform == TargetPlatform.android) {
        _systemFilesFuture = _loadSystemFiles(category);
      } else {
        _assetPathsFuture = _loadAssetPaths(category);
        _assetsFuture = _loadAssets(category);
      }
    } else if (category == _BrowserCategory.downloads || category == _BrowserCategory.documents) {
      _systemFilesFuture = _loadSystemFiles(category);
    }
    _scrollCategoryIntoView(category);
  }

  void _onSearchChanged(String value) {
    widget.onUserActivity?.call();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _searchQuery = value.trim().toLowerCase());
    });
  }

  void _scrollCategoryIntoView(_BrowserCategory category) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _categoryKeys[category.index];
      final categoryContext = key.currentContext;
      if (categoryContext != null) {
        Scrollable.ensureVisible(
          categoryContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
        );
      }
    });
  }

  void _onHorizontalSwipe(DragEndDetails details) {
    widget.onUserActivity?.call();
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 350) return;
    final nextIndex = (_category.index + (velocity < 0 ? 1 : -1)).clamp(
      0,
      _BrowserCategory.values.length - 1,
    );
    if (nextIndex != _category.index) _openCategory(_BrowserCategory.values[nextIndex]);
  }

  bool _matchesSearch(String value) => _searchQuery.isEmpty || value.toLowerCase().contains(_searchQuery);

  Future<List<android_channel.FileInfo>> _loadSystemFiles(
    _BrowserCategory category,
  ) async {
    try {
      if (defaultTargetPlatform != TargetPlatform.android) return [];
      if ((ref.read(deviceInfoProvider).androidSdkInt ?? 0) <= 32) {
        if (!await Permission.storage.request().then(
          (permission) => permission.isGranted,
        )) {
          if (mounted && _category == category) setState(() => _permissionRequired = true);
          return [];
        }
      } else if (category == _BrowserCategory.images || category == _BrowserCategory.videos || category == _BrowserCategory.audio) {
        final type = switch (category) {
          _BrowserCategory.images => RequestType.image,
          _BrowserCategory.videos => RequestType.video,
          _BrowserCategory.audio => RequestType.audio,
          _ => RequestType.common,
        };
        final permission = await PhotoManager.requestPermissionExtend(
          requestOption: PermissionRequestOption(
            androidPermission: AndroidPermission(
              type: type,
              mediaLocation: false,
            ),
          ),
        );
        if (!permission.isAuth) {
          if (mounted && _category == category) setState(() => _permissionRequired = true);
          return [];
        }
      }
      if (mounted && _category == category) _permissionRequired = false;
      final files = await android_channel.queryMediaFilesAndroid(
        category: category.name,
        offset: 0,
        limit: _systemFilesPageSize,
      );
      if (mounted && _category == category) {
        _systemFilesOffset = files.length;
        _hasMoreSystemFiles = files.length == _systemFilesPageSize;
      }
      return files;
    } catch (error, stackTrace) {
      _logger.warning(
        'Could not load ${category.name} files',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _loadMoreSystemFiles(_BrowserCategory category) async {
    if (_loadingMoreSystemFiles || !_hasMoreSystemFiles || category != _category) return;
    setState(() {
      _loadingMoreSystemFiles = true;
      _systemFilesPageError = false;
    });
    try {
      final files = await android_channel.queryMediaFilesAndroid(
        category: category.name,
        offset: _systemFilesOffset,
        limit: _systemFilesPageSize,
      );
      if (!mounted || category != _category) return;
      setState(() {
        _additionalSystemFiles.addAll(files);
        _systemFilesOffset += files.length;
        _hasMoreSystemFiles = files.length == _systemFilesPageSize;
        _loadingMoreSystemFiles = false;
      });
    } catch (error, stackTrace) {
      _logger.warning(
        'Could not load more ${category.name} files',
        error,
        stackTrace,
      );
      if (!mounted || category != _category) return;
      setState(() {
        _loadingMoreSystemFiles = false;
        _systemFilesPageError = true;
      });
    }
  }

  int get _systemFilesFooterCount => _hasMoreSystemFiles || _loadingMoreSystemFiles || _systemFilesPageError ? 1 : 0;

  Widget _systemFilesFooter(_BrowserCategory category) {
    if (_systemFilesPageError) {
      return Center(
        child: TextButton(
          onPressed: () => _loadMoreSystemFiles(category),
          child: const Text(BrowserStrings.loadingMoreError),
        ),
      );
    }
    if (!_loadingMoreSystemFiles) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _loadMoreSystemFiles(category),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }

  Future<void> _initializeStorageTree() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    String? uri;
    try {
      _saveLocation = await android_channel.getSaveLocationAndroid();
      uri =
          await android_channel.getStorageTreeAndroid(storage: _saveLocation) ?? await android_channel.pickStorageTreeAndroid(storage: _saveLocation);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      if (uri != null) {
        _treeRootUri = uri;
        _currentFolderUri = uri;
        _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: uri);
      }
      _systemFilesFuture = _loadSystemFiles(_category);
    });
  }

  Future<List<AssetPathEntity>> _loadAssetPaths(
    _BrowserCategory category,
  ) async {
    final type = switch (category) {
      _BrowserCategory.images => RequestType.image,
      _BrowserCategory.videos => RequestType.video,
      _BrowserCategory.audio => RequestType.audio,
      _ => RequestType.common,
    };
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: PermissionRequestOption(
        androidPermission: AndroidPermission(type: type, mediaLocation: false),
      ),
    );
    if (!permission.isAuth) {
      if (mounted && _category == category) setState(() => _permissionRequired = true);
      return [];
    }
    if (mounted && _category == category) _permissionRequired = false;
    return PhotoManager.getAssetPathList(type: type, hasAll: true);
  }

  Future<List<AssetEntity>> _loadAssets(
    _BrowserCategory category, {
    AssetPathEntity? path,
  }) async {
    final paths = path == null ? await (_assetPathsFuture ??= _loadAssetPaths(category)) : [path];
    if (paths.isEmpty) return [];
    final selectedPath = path ?? paths.first;
    final assets = await selectedPath.getAssetListPaged(page: 0, size: 100);
    if (mounted && _category == category) {
      _activeAssetPath = selectedPath;
      _assetPage = 1;
      _hasMoreAssets = assets.length == 100;
      _additionalAssets.clear();
    }
    return assets;
  }

  Future<void> _loadMoreAssets(
    _BrowserCategory category,
    AssetPathEntity path,
  ) async {
    if (_loadingMoreAssets || !_hasMoreAssets || category != _category) return;
    setState(() => _loadingMoreAssets = true);
    try {
      final assets = await path.getAssetListPaged(page: _assetPage, size: 100);
      if (!mounted || category != _category || path != _activeAssetPath) return;
      setState(() {
        _additionalAssets.addAll(assets);
        _assetPage++;
        _hasMoreAssets = assets.length == 100;
        _loadingMoreAssets = false;
      });
    } catch (error, stackTrace) {
      _logger.warning(
        'Could not load more ${category.name}',
        error,
        stackTrace,
      );
      if (mounted && category == _category) setState(() => _loadingMoreAssets = false);
    }
  }

  Future<List<AssetEntity>> _filterAssets(List<AssetEntity> assets) async {
    if (_searchQuery.isEmpty) return assets;
    final matches = await Future.wait(
      assets.map((asset) async {
        final titleFuture = _assetTitles.putIfAbsent(
          asset.id,
          () => asset.titleAsync,
        );
        return (asset, await titleFuture);
      }),
    );
    return matches.where((entry) => entry.$2.toLowerCase().contains(_searchQuery)).map((entry) => entry.$1).toList();
  }

  final Map<String, Future<List<AssetEntity>>> _filteredAssetFutures = {};
  final Map<String, Future<List<AssetEntity>>> _albumCoverFutures = {};

  Future<List<AssetEntity>> _filteredAssetsFuture(List<AssetEntity> assets) {
    final key = '${_category.name}:${_activeAssetPath?.id}:$_searchQuery:${assets.length}';
    final cached = _filteredAssetFutures[key];
    if (cached != null) return cached;
    final future = _filterAssets(assets);
    _filteredAssetFutures[key] = future;
    if (_filteredAssetFutures.length > 16) _filteredAssetFutures.remove(_filteredAssetFutures.keys.first);
    return future;
  }

  Future<List<AssetEntity>> _albumCoverFuture(AssetPathEntity path) => _albumCoverFutures.putIfAbsent(
    path.id,
    () => path.getAssetListPaged(page: 0, size: 1),
  );

  Future<void> _toggleApp(Application app) async {
    await _toggleFile(await CrossFileConverters.convertApplication(app));
  }

  Future<void> _toggleAsset(AssetEntity asset) async {
    await _toggleFile(await CrossFileConverters.convertAssetEntity(asset));
  }

  Future<void> _toggleSystemFile(android_channel.FileInfo file) async {
    await _toggleFile(await CrossFileConverters.convertFileInfo(file));
  }

  Future<void> _toggleFile(CrossFile file) async {
    widget.onUserActivity?.call();
    final selection = ref.read(selectedSendingFilesProvider);
    final selectedIndex = selection.indexWhere(
      (selected) => selected.isSameFile(otherFile: file),
    );
    if (selectedIndex >= 0) {
      ref.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(selectedIndex));
    } else {
      await ref
          .redux(selectedSendingFilesProvider)
          .dispatchAsync(
            AddFilesAction<CrossFile>(
              files: [file],
              converter: (file) async => file,
            ),
          );
    }
  }

  bool _isAssetSelected(AssetEntity asset) => ref.read(selectedSendingFilesProvider).any((file) => file.asset?.id == asset.id);

  bool _isPathSelected(String path) => ref.read(selectedSendingFilesProvider).any((file) => file.path == path);

  Future<int> _assetCountFuture(AssetPathEntity path) => _assetCountFutures.putIfAbsent(path.id, () => path.assetCountAsync);

  Widget _assetCountIndicator(AssetPathEntity path) {
    return FutureBuilder<int>(
      future: _assetCountFuture(path),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Tooltip(
            message: '${BrowserStrings.couldNotLoadImages} ${snapshot.error}',
            child: const Icon(Icons.error_outline, size: 14),
          );
        }
        return Text(snapshot.data?.toString() ?? '…');
      },
    );
  }

  bool _isSystemFileSelected(android_channel.FileInfo file) => _isPathSelected(file.uri);

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification.metrics.pixels <= notification.metrics.minScrollExtent) {
      widget.onHeaderVisibilityChanged?.call(true);
    } else if (notification is UserScrollNotification) {
      widget.onUserActivity?.call();
      if (notification.direction == ScrollDirection.reverse) {
        widget.onHeaderVisibilityChanged?.call(false);
      } else if (notification.direction == ScrollDirection.forward) {
        widget.onHeaderVisibilityChanged?.call(true);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    context.watch(selectedSendingFilesProvider);
    final tokens = BrowserThemeTokens.of(context);
    final categories = _BrowserCategory.values;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              if (_searchExpanded)
                Expanded(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    child: BrowserSurface(
                      padding: EdgeInsets.zero,
                      borderRadius: BorderRadius.circular(glassRadiusInput),
                      child: TextField(
                        controller: _textController,
                        autofocus: true,
                        onChanged: _onSearchChanged,
                        decoration: InputDecoration(
                          filled: false,
                          border: InputBorder.none,
                          hintText: BrowserStrings.searchFiles,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: IconButton(
                            tooltip: BrowserStrings.clearSearch,
                            onPressed: () {
                              _textController.clear();
                              _searchDebounce?.cancel();
                              setState(() => _searchQuery = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: BrowserStrings.search,
                  onPressed: () => setState(() => _searchExpanded = true),
                  icon: const Icon(Icons.search),
                ),
              if (_searchExpanded)
                IconButton(
                  tooltip: BrowserStrings.closeSearch,
                  onPressed: () {
                    _searchDebounce?.cancel();
                    _textController.clear();
                    setState(() {
                      _searchExpanded = false;
                      _searchQuery = '';
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 50,
          child: ListView(
            controller: _categoryScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final category in categories)
                Padding(
                  key: _categoryKeys[category.index],
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(glassRadiusPill),
                    onTap: () => _openCategory(category),
                    child: BrowserSurface(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      borderRadius: BorderRadius.circular(glassRadiusPill),
                      color: _category == category ? tokens.selection : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            category.icon,
                            size: 17,
                            color: _category == category ? tokens.primary : tokens.icon,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            category.label,
                            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: _category == category ? tokens.primary : tokens.textSecondary,
                              fontWeight: _category == category ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: GestureDetector(
              onHorizontalDragEnd: _onHorizontalSwipe,
              child: BrowserSurface(
                margin: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(glassRadiusCard),
                child: _buildCategoryBody(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryBody() => switch (_category) {
    _BrowserCategory.images => _buildImagesBrowser(),
    _BrowserCategory.videos ||
    _BrowserCategory.audio => defaultTargetPlatform == TargetPlatform.android ? _buildAndroidMediaBrowser() : _buildMediaBrowser(),
    _BrowserCategory.apps => _buildAppsBrowser(),
    _BrowserCategory.text => _buildFilesBrowser(textOnly: true),
    _BrowserCategory.downloads || _BrowserCategory.documents => _buildSystemFileBrowser(),
    _BrowserCategory.files => Column(
      children: [
        Expanded(child: _buildFilesBrowser()),
        const _StorageStatisticsPlaceholder(),
      ],
    ),
  };

  Widget _buildImagesBrowser() {
    final future = _assetPathsFuture ??= _loadAssetPaths(_category);
    return FutureBuilder<List<AssetPathEntity>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: '${BrowserStrings.couldNotLoadImages} ${snapshot.error}',
          );
        }
        final albums = snapshot.data ?? [];
        if (albums.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _permissionRequired ? BrowserStrings.mediaPermissionRequired : BrowserStrings.noImagesFound,
          );
        }
        final photoAlbums = albums.length > 1 ? albums.skip(1).toList() : albums;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _imageSegment(
                      label: BrowserStrings.photos,
                      count: _assetCountIndicator(albums.first),
                      active: !_showAlbums,
                      onTap: () => setState(() => _showAlbums = false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _imageSegment(
                      label: BrowserStrings.albums,
                      count: Text('${photoAlbums.length}'),
                      active: _showAlbums,
                      onTap: () => setState(() => _showAlbums = true),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _showAlbums ? _buildAlbumsList(photoAlbums) : _buildPhotosGrid(albums.first),
            ),
          ],
        );
      },
    );
  }

  Widget _imageSegment({
    required String label,
    required Widget count,
    required bool active,
    required VoidCallback onTap,
  }) {
    final tokens = BrowserThemeTokens.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(glassRadiusPill),
      onTap: onTap,
      child: BrowserSurface(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        borderRadius: BorderRadius.circular(glassRadiusPill),
        color: active ? tokens.selection : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: active ? tokens.primary : tokens.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: active ? tokens.primary : tokens.textSecondary,
              ),
              child: count,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumsList(List<AssetPathEntity> albums) {
    final filtered = albums.where((album) => _matchesSearch(album.name)).toList();
    if (filtered.isEmpty)
      return _emptyState(
        icon: Icons.photo_album_outlined,
        message: BrowserStrings.noAlbums,
      );
    return ListView.separated(
      key: const PageStorageKey<String>('browser-albums'),
      padding: const EdgeInsets.all(8),
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final album = filtered[index];
        return InkWell(
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          onTap: () => setState(() {
            _activeAssetPath = album;
            _assetsFuture = _loadAssets(_BrowserCategory.images, path: album);
            _additionalAssets.clear();
            _assetPage = 0;
            _showAlbums = false;
          }),
          child: BrowserSurface(
            padding: const EdgeInsets.all(10),
            borderRadius: BorderRadius.circular(glassRadiusSmall),
            child: Row(
              children: [
                SizedBox(
                  width: 62,
                  height: 62,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(glassRadiusSmall),
                    child: FutureBuilder<List<AssetEntity>>(
                      future: _albumCoverFuture(album),
                      builder: (context, cover) => cover.data != null && cover.data!.isNotEmpty
                          ? AssetEntityImage(
                              cover.data!.first,
                              isOriginal: false,
                              thumbnailSize: const ThumbnailSize.square(180),
                              fit: BoxFit.cover,
                            )
                          : ColoredBox(
                              color: BrowserThemeTokens.of(
                                context,
                              ).surfaceElevated,
                              child: Icon(
                                Icons.photo_album_outlined,
                                color: BrowserThemeTokens.of(context).icon,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _assetCountIndicator(album),
                          const SizedBox(width: 4),
                          Text(
                            BrowserStrings.albumCount,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: BrowserThemeTokens.of(context).icon,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotosGrid(AssetPathEntity album) {
    if (_activeAssetPath != album || _assetsFuture == null) {
      _activeAssetPath = album;
      _assetsFuture = _loadAssets(_BrowserCategory.images, path: album);
    }
    return FutureBuilder<List<AssetEntity>>(
      future: _assetsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError)
          return _emptyState(
            icon: _category.icon,
            message: '${BrowserStrings.couldNotLoadPhotos} ${snapshot.error}',
          );
        final assets = [...?snapshot.data, ..._additionalAssets];
        if (assets.isEmpty)
          return _emptyState(
            icon: _category.icon,
            message: BrowserStrings.noPhotosFound,
          );
        return FutureBuilder<List<AssetEntity>>(
          future: _filteredAssetsFuture(assets),
          builder: (context, filteredSnapshot) {
            if (filteredSnapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            final filteredAssets = filteredSnapshot.data ?? [];
            if (filteredAssets.isEmpty)
              return _emptyState(
                icon: _category.icon,
                message: BrowserStrings.noFilesFound,
              );
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.extentAfter < 360 && !_loadingMoreAssets) {
                  _loadMoreAssets(_BrowserCategory.images, album);
                }
                return false;
              },
              child: _buildChronologicalPhotoGrid(filteredAssets),
            );
          },
        );
      },
    );
  }

  Widget _buildChronologicalPhotoGrid(List<AssetEntity> assets) {
    final byDate = <DateTime, List<AssetEntity>>{};
    for (final asset in assets) {
      final date = asset.createDateTime;
      final day = DateTime(date.year, date.month, date.day);
      byDate.putIfAbsent(day, () => []).add(asset);
    }
    final groups = byDate.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    return CustomScrollView(
      key: const PageStorageKey<String>('browser-photos'),
      slivers: [
        for (final group in groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Text(
                MaterialLocalizations.of(context).formatMediumDate(group.key),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            sliver: SliverGrid.builder(
              itemCount: group.value.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemBuilder: (context, index) => _photoCell(group.value[index]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _photoCell(AssetEntity asset) {
    final selected = _isAssetSelected(asset);
    return GestureDetector(
      onTap: () => _toggleAsset(asset),
      child: BrowserSurface(
        padding: EdgeInsets.zero,
        borderRadius: BorderRadius.circular(glassRadiusSmall),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AssetEntityImage(
                asset,
                isOriginal: false,
                thumbnailSize: const ThumbnailSize.square(240),
                fit: BoxFit.cover,
              ),
              if (selected)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: BrowserThemeTokens.of(context).selection,
                      border: Border.all(
                        color: BrowserThemeTokens.of(context).primary,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(glassRadiusSmall),
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Icon(
                          Icons.check_circle,
                          color: BrowserThemeTokens.of(context).primary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaBrowser() {
    final future = _assetsFuture;
    if (future == null) return const Center(child: CircularProgressIndicator());
    return FutureBuilder<List<AssetEntity>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final assets = [...?snapshot.data, ..._additionalAssets];
        if (assets.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _permissionRequired ? BrowserStrings.mediaPermissionRequired : 'No ${_category.label.toLowerCase()} found.',
            action: TextButton.icon(
              onPressed: () => setState(
                () => _assetPathsFuture = _loadAssetPaths(_category),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Check access'),
            ),
          );
        }
        return FutureBuilder<List<AssetEntity>>(
          future: _filteredAssetsFuture(assets),
          builder: (context, filteredSnapshot) {
            if (filteredSnapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            final filtered = filteredSnapshot.data ?? [];
            if (filtered.isEmpty)
              return _emptyState(
                icon: _category.icon,
                message: BrowserStrings.noFilesFound,
              );
            return NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                final path = _activeAssetPath;
                if (notification.metrics.extentAfter < 360 && path != null && !_loadingMoreAssets) {
                  _loadMoreAssets(_category, path);
                }
                return false;
              },
              child: ListView.builder(
                key: PageStorageKey<String>('browser-${_category.name}'),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final asset = filtered[index];
                  final selected = _isAssetSelected(asset);
                  final title = _assetTitles.putIfAbsent(
                    asset.id,
                    () => asset.titleAsync,
                  );
                  return FutureBuilder<String>(
                    future: title,
                    builder: (context, titleSnapshot) => _fileRow(
                      selected: selected,
                      icon: _category == _BrowserCategory.videos ? Icons.movie_outlined : Icons.audio_file_outlined,
                      title: titleSnapshot.data ?? (_category == _BrowserCategory.videos ? 'Video file' : 'Audio file'),
                      subtitle: _category.label,
                      leading: _category == _BrowserCategory.videos
                          ? SizedBox(
                              width: 56,
                              height: 56,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  glassRadiusSmall,
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    AssetEntityImage(
                                      asset,
                                      isOriginal: false,
                                      thumbnailSize: const ThumbnailSize.square(
                                        180,
                                      ),
                                      fit: BoxFit.cover,
                                    ),
                                    Center(
                                      child: Icon(
                                        Icons.play_circle_fill,
                                        color: BrowserThemeTokens.of(
                                          context,
                                        ).textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : null,
                      onTap: () => _toggleAsset(asset),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAppsBrowser() {
    final appsAsync = ref.watch(
      installedApplicationsProvider(
        CachedApkProviderParam(
          includeSystemApps: false,
          onlyAppsWithLaunchIntent: false,
          selectMultipleApps: false,
        ),
      ),
    );
    return appsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text('${BrowserStrings.couldNotLoadInstalledApps} $error'),
      ),
      data: (apps) {
        final matchingApps = apps.where((app) => _matchesSearch('${app.appName} ${app.packageName}')).toList();
        if (matchingApps.isEmpty) {
          return _emptyState(
            icon: Icons.apps_outlined,
            message: _searchQuery.isEmpty ? BrowserStrings.noUserAppsAvailable : BrowserStrings.noFilesFound,
          );
        }
        return GridView.builder(
          key: const PageStorageKey<String>('browser-apps'),
          padding: const EdgeInsets.all(4),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            mainAxisExtent: 138,
          ),
          itemCount: matchingApps.length,
          itemBuilder: (context, index) {
            final app = matchingApps[index];
            final selected = _isPathSelected(app.apkFilePath);
            final tokens = BrowserThemeTokens.of(context);
            return InkWell(
              borderRadius: BorderRadius.circular(glassRadiusSmall),
              onTap: () => _toggleApp(app),
              child: BrowserSurface(
                padding: const EdgeInsets.all(6),
                borderRadius: BorderRadius.circular(glassRadiusSmall),
                color: selected ? tokens.selection : null,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        SizedBox(
                          height: 58,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 48,
                              child: app is ApplicationWithIcon
                                  ? Image.memory(
                                      app.icon,
                                      fit: BoxFit.contain,
                                      cacheWidth: 144,
                                      cacheHeight: 144,
                                    )
                                  : Icon(
                                      Icons.android,
                                      size: 42,
                                      color: tokens.icon,
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 20,
                          width: double.infinity,
                          child: Text(
                            app.appName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Expanded(
                          child: Consumer(
                            builder: (context, ref) {
                              final size = ref.watch(
                                apkSizeProvider(app.apkFilePath),
                              );
                              return Center(
                                child: Text(
                                  size.maybeWhen(
                                    data: (bytes) => bytes.asReadableFileSize,
                                    orElse: () => '',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tokens.textSecondary),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    if (selected)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: tokens.primary,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFilesBrowser({bool textOnly = false}) {
    final folderUri = _currentFolderUri;
    if (folderUri == null) {
      return _emptyState(
        icon: Icons.folder_open_outlined,
        message: BrowserStrings.filesNoFolder,
        action: FilledButton.icon(
          onPressed: () async {
            final uri = await android_channel.pickStorageTreeAndroid(
              storage: _saveLocation,
            );
            if (!mounted || uri == null) return;
            setState(() {
              _treeRootUri = uri;
              _currentFolderUri = uri;
              _treeBreadcrumbs.clear();
              _treeEntriesFuture = android_channel.listFolderTreeAndroid(
                uri: uri,
              );
            });
          },
          icon: const Icon(Icons.folder_open),
          label: const Text(BrowserStrings.grantAccess),
        ),
      );
    }

    final future = _treeEntriesFuture ??= android_channel.listFolderTreeAndroid(
      uri: folderUri,
    );
    return FutureBuilder<List<android_channel.AndroidBrowseEntry>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final entries =
            [...?snapshot.data]
                .where(
                  (entry) => (!textOnly || entry.isDirectory || _isTextFile(entry.name)) && _matchesSearch(entry.name),
                )
                .toList()
              ..sort((a, b) {
                if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });
        if (snapshot.hasError) {
          return _emptyState(
            icon: Icons.folder_off_outlined,
            message: "Couldn't read this folder.\n${snapshot.error}",
            action: TextButton.icon(
              onPressed: () => setState(
                () => _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: folderUri),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          );
        }
        return Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back to parent folder',
                  onPressed: _treeBreadcrumbs.isEmpty
                      ? null
                      : () {
                          setState(() {
                            _treeBreadcrumbs.removeLast();
                            _currentFolderUri = _treeBreadcrumbs.isEmpty ? _treeRootUri : _treeBreadcrumbs.last.$2;
                            _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: _currentFolderUri!);
                          });
                        },
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _treeBreadcrumbs.clear();
                              _currentFolderUri = _treeRootUri;
                              _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: _treeRootUri!);
                            });
                          },
                          child: const Text(BrowserStrings.openFolder),
                        ),
                        for (var index = 0; index < _treeBreadcrumbs.length; index++)
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _currentFolderUri = _treeBreadcrumbs[index].$2;
                                _treeBreadcrumbs.removeRange(
                                  index + 1,
                                  _treeBreadcrumbs.length,
                                );
                                _treeEntriesFuture = android_channel.listFolderTreeAndroid(
                                  uri: _currentFolderUri!,
                                );
                              });
                            },
                            child: Text(_treeBreadcrumbs[index].$1),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: BrowserStrings.addAllFilesInFolder,
                  onPressed: () async {
                    final files = await android_channel.listFolderTreeFilesAndroid(uri: folderUri);
                    if (textOnly) files.removeWhere((file) => !_isTextFile(file.name));
                    await _stageSystemFiles(files);
                  },
                  icon: const Icon(Icons.select_all),
                ),
              ],
            ),
            Expanded(
              child: entries.isEmpty
                  ? _emptyState(
                      icon: Icons.folder_open_outlined,
                      message: _searchQuery.isNotEmpty || textOnly ? BrowserStrings.noFilesFound : BrowserStrings.folderEmpty,
                    )
                  : ListView.builder(
                      key: PageStorageKey<String>('browser-files:$folderUri'),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final file = android_channel.FileInfo(
                          name: entry.name,
                          size: entry.size,
                          uri: entry.uri,
                          lastModified: entry.lastModified,
                        );
                        return _fileRow(
                          selected: !entry.isDirectory && _isSystemFileSelected(file),
                          icon: entry.isDirectory ? Icons.folder_outlined : _fileTypeIcon(entry.name),
                          title: entry.name,
                          subtitle: entry.isDirectory ? BrowserStrings.folder : '${entry.size.asReadableFileSize}${_shortDate(entry.lastModified)}',
                          onTap: entry.isDirectory
                              ? () => setState(() {
                                  _treeBreadcrumbs.add((entry.name, entry.uri));
                                  _currentFolderUri = entry.uri;
                                  _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: entry.uri);
                                })
                              : () => _toggleSystemFile(file),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _stageSystemFiles(List<android_channel.FileInfo> files) async {
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction<android_channel.FileInfo>(
            files: files,
            converter: CrossFileConverters.convertFileInfo,
          ),
        );
  }

  Widget _buildSystemFileBrowser() {
    final future = _systemFilesFuture;
    if (future == null)
      return const Center(
        child: Text('Open this category to browse device files.'),
      );
    return FutureBuilder<List<android_channel.FileInfo>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: 'Could not load ${_category.label.toLowerCase()} files: ${snapshot.error}',
            action: TextButton.icon(
              onPressed: () => setState(
                () => _systemFilesFuture = _loadSystemFiles(_category),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          );
        }
        final allFiles = [...?snapshot.data, ..._additionalSystemFiles];
        final files = allFiles
            .where(
              (file) => _category != _BrowserCategory.text || _isTextFile(file.name),
            )
            .where((file) => _matchesSearch(file.name))
            .toList();
        if (files.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _searchQuery.isNotEmpty ? BrowserStrings.noFilesFound : 'No ${_category.label.toLowerCase()} files are available.',
            action: TextButton.icon(
              onPressed: () => setState(() {
                _additionalSystemFiles.clear();
                _systemFilesOffset = 0;
                _hasMoreSystemFiles = false;
                _loadingMoreSystemFiles = false;
                _systemFilesPageError = false;
                _systemFilesFuture = _loadSystemFiles(_category);
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          );
        }
        return ListView.builder(
          key: PageStorageKey<String>('browser-${_category.name}'),
          itemCount: files.length + _systemFilesFooterCount,
          itemBuilder: (context, index) {
            if (index >= files.length) return _systemFilesFooter(_category);
            final file = files[index];
            return _fileRow(
              selected: _isSystemFileSelected(file),
              icon: _fileTypeIcon(file.name),
              title: file.name,
              subtitle: '${file.size.asReadableFileSize}${_shortDate(file.lastModified)}',
              onTap: () => _toggleSystemFile(file),
            );
          },
        );
      },
    );
  }

  Widget _buildAndroidMediaBrowser() {
    final future = _systemFilesFuture;
    if (future == null) return const Center(child: Text('Open this category to browse media.'));
    return FutureBuilder<List<android_channel.FileInfo>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: 'Could not load ${_category.label.toLowerCase()} files: ${snapshot.error}',
            action: TextButton.icon(
              onPressed: () => setState(
                () => _systemFilesFuture = _loadSystemFiles(_category),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          );
        }
        final files = [
          ...?snapshot.data,
          ..._additionalSystemFiles,
        ].where((file) => _matchesSearch(file.name)).toList();
        if (files.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _searchQuery.isNotEmpty
                ? BrowserStrings.noFilesFound
                : _permissionRequired
                ? BrowserStrings.mediaPermissionRequired
                : 'No ${_category.label.toLowerCase()} found.',
            action: TextButton.icon(
              onPressed: () => setState(() {
                _additionalSystemFiles.clear();
                _systemFilesOffset = 0;
                _hasMoreSystemFiles = false;
                _loadingMoreSystemFiles = false;
                _systemFilesPageError = false;
                _systemFilesFuture = _loadSystemFiles(_category);
              }),
              icon: const Icon(Icons.refresh),
              label: const Text('Check access'),
            ),
          );
        }
        return ListView.builder(
          key: PageStorageKey<String>('browser-${_category.name}'),
          itemCount: files.length + _systemFilesFooterCount,
          itemBuilder: (context, index) {
            if (index >= files.length) return _systemFilesFooter(_category);
            final file = files[index];
            final isVideo = _category == _BrowserCategory.videos;
            return _fileRow(
              selected: _isSystemFileSelected(file),
              icon: isVideo ? Icons.movie_outlined : Icons.audio_file_outlined,
              title: file.name,
              subtitle: '${file.size.asReadableFileSize}${_shortDate(file.lastModified)}',
              leading: SizedBox(
                width: 56,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(glassRadiusSmall),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildMediaThumbnail(
                        file,
                        _category.name,
                        BoxFit.cover,
                        fallback: isVideo ? Icons.movie_outlined : Icons.music_note,
                      ),
                      if (isVideo)
                        Center(
                          child: Icon(
                            Icons.play_circle_fill,
                            color: BrowserThemeTokens.of(context).textPrimary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              onTap: () => _toggleSystemFile(file),
            );
          },
        );
      },
    );
  }

  Widget _buildMediaThumbnail(
    android_channel.FileInfo file,
    String category,
    BoxFit fit, {
    required IconData fallback,
  }) {
    final key = '$category:${file.uri}';
    final future = _thumbnailFutures.putIfAbsent(
      key,
      () => android_channel.loadMediaThumbnailAndroid(
        uri: file.uri,
        category: category,
      ),
    );
    _thumbnailFutures[key] = future;
    if (_thumbnailFutures.length > 128) _thumbnailFutures.remove(_thumbnailFutures.keys.first);
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) return Image.memory(bytes, fit: fit, gaplessPlayback: true);
        return ColoredBox(
          color: BrowserThemeTokens.of(context).surfaceElevated,
          child: Center(
            child: Icon(fallback, color: BrowserThemeTokens.of(context).icon),
          ),
        );
      },
    );
  }

  Widget _fileRow({
    required bool selected,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Widget? leading,
  }) {
    final tokens = BrowserThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(glassRadiusSmall),
        onTap: onTap,
        child: BrowserSurface(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          borderRadius: BorderRadius.circular(glassRadiusSmall),
          color: selected ? tokens.selection : null,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child:
                      leading ??
                      Icon(
                        icon,
                        color: selected ? tokens.primary : tokens.icon,
                      ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check_circle : Icons.add_circle_outline,
                  color: selected ? tokens.primary : tokens.icon,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isTextFile(String name) {
    final extension = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return const {
      'txt',
      'text',
      'md',
      'markdown',
      'json',
      'xml',
      'csv',
      'tsv',
      'log',
      'yaml',
      'yml',
      'toml',
      'ini',
      'dart',
      'kt',
      'java',
      'js',
      'ts',
      'html',
      'css',
      'c',
      'h',
      'cpp',
      'rs',
      'py',
      'sh',
      'sql',
    }.contains(extension);
  }

  String _shortDate(String? date) {
    if (date == null) return '';
    final parsed = DateTime.tryParse(date);
    return parsed == null ? ' · $date' : ' · ${MaterialLocalizations.of(context).formatShortDate(parsed.toLocal())}';
  }

  IconData _fileTypeIcon(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'odt' => Icons.article_outlined,
      'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.archive_outlined,
      'apk' => Icons.android,
      'txt' ||
      'md' ||
      'json' ||
      'xml' ||
      'csv' ||
      'log' ||
      'yaml' ||
      'yml' ||
      'dart' ||
      'kt' ||
      'java' ||
      'js' ||
      'ts' ||
      'py' => Icons.text_snippet_outlined,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'webp' => Icons.image_outlined,
      'mp4' || 'mov' || 'mkv' => Icons.movie_outlined,
      'mp3' || 'm4a' || 'wav' || 'flac' => Icons.audio_file_outlined,
      _ => Icons.description_outlined,
    };
  }

  Widget _emptyState({
    required IconData icon,
    required String message,
    Widget? action,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.secondary),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action],
        ],
      ),
    ),
  );
}

class _StorageStatisticsPlaceholder extends StatelessWidget {
  const _StorageStatisticsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tokens = BrowserThemeTokens.of(context);
    return BrowserSurface(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.storage_outlined, color: tokens.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  BrowserStrings.storage,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  BrowserStrings.storageStatsNextPhase,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
