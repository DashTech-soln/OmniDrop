import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_apps/device_apps.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/pages/browser/browser_delete_helpers.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/pages/browser/browser_surface.dart';
import 'package:localsend_app/pages/browser/browser_sort.dart';
import 'package:localsend_app/pages/browser/storage_statistics_card.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/pages/browser/apk_file_cell.dart';
import 'package:localsend_app/provider/apk_provider.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/photo_manager_filter.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:localsend_app/widget/dialogs/message_input_dialog.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:localsend_isolates/model/session_status.dart';

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

class _InstalledApp {
  final String packageName;
  final String appName;
  final String apkFilePath;
  final String? versionName;
  final int versionCode;
  final bool systemApp;
  final int updateTimeMillis;
  final int? size;

  const _InstalledApp({
    required this.packageName,
    required this.appName,
    required this.apkFilePath,
    required this.versionName,
    required this.versionCode,
    required this.systemApp,
    required this.updateTimeMillis,
    required this.size,
  });

  factory _InstalledApp.fromApplication(Application app, int? size) => _InstalledApp(
    packageName: app.packageName,
    appName: app.appName,
    apkFilePath: app.apkFilePath,
    versionName: app.versionName,
    versionCode: app.versionCode,
    systemApp: app.systemApp,
    updateTimeMillis: app.updateTimeMillis,
    size: size,
  );

  factory _InstalledApp.fromJson(Map<String, dynamic> json) => _InstalledApp(
    packageName: json['packageName'] as String,
    appName: json['appName'] as String,
    apkFilePath: json['apkFilePath'] as String,
    versionName: json['versionName'] as String?,
    versionCode: (json['versionCode'] as num).toInt(),
    systemApp: json['systemApp'] as bool,
    updateTimeMillis: (json['updateTimeMillis'] as num).toInt(),
    size: (json['size'] as num?)?.toInt(),
  );

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'appName': appName,
    'apkFilePath': apkFilePath,
    'versionName': versionName,
    'versionCode': versionCode,
    'systemApp': systemApp,
    'updateTimeMillis': updateTimeMillis,
    'size': size,
  };

  String get iconFileName => '${Uri.encodeComponent(packageName)}-$versionCode.png';

  bool hasSameMetadata(_InstalledApp other) =>
      packageName == other.packageName &&
      appName == other.appName &&
      apkFilePath == other.apkFilePath &&
      versionName == other.versionName &&
      versionCode == other.versionCode &&
      systemApp == other.systemApp &&
      updateTimeMillis == other.updateTimeMillis &&
      size == other.size;
}

List<int?> _readApkFileLengths(List<String> paths) => [
  for (final path in paths)
    try {
      File(path).lengthSync()
    } on FileSystemException {
      null
    },
];

List<Map<String, Object?>> _sortInstalledApps(Map<String, Object?> input) {
  final apps = (input['apps']! as List<Object?>)
      .map((value) => _InstalledApp.fromJson(Map<String, dynamic>.from(value! as Map)))
      .toList();
  final ascending = input['ascending']! as bool;
  final sortMode = input['sortMode']! as String;
  apps.sort((a, b) {
    final result = switch (sortMode) {
      'name' => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()),
      'size' => (a.size ?? -1).compareTo(b.size ?? -1),
      _ => a.updateTimeMillis.compareTo(b.updateTimeMillis),
    };
    return ascending ? result : -result;
  });
  return apps.map((app) => app.toJson()).toList();
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
  final Future<void> Function()? onSendMessage;
  final TextEditingController? searchController;
  final bool searchExpanded;
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<String>? onCategoryChanged;
  final BrowserSortMode sortMode;
  final bool sortAscending;
  final ValueChanged<BrowserSortMode>? onSortModeChanged;
  final ValueChanged<bool>? onSortDirectionChanged;

  const InAppFileBrowser({
    this.onHeaderVisibilityChanged,
    this.onUserActivity,
    this.onSendMessage,
    this.searchController,
    this.searchExpanded = false,
    this.onSearchChanged,
    this.onCategoryChanged,
    this.sortMode = BrowserSortMode.date,
    this.sortAscending = false,
    this.onSortModeChanged,
    this.onSortDirectionChanged,
    super.key,
  });

  @override
  State<InAppFileBrowser> createState() => InAppFileBrowserState();
}

class InAppFileBrowserState extends State<InAppFileBrowser> with Refena, AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const _systemFilesPageSize = 100;
  static const _selfPackageName = 'com.omnidrop.app';
  _BrowserCategory _category = _BrowserCategory.downloads;
  final _textController = TextEditingController();
  TextEditingController get _searchController => widget.searchController ?? _textController;
  final _categoryScrollController = ScrollController();
  final _categoryKeys = List<GlobalKey>.generate(
    _BrowserCategory.values.length,
    (_) => GlobalKey(),
  );
  final Map<String, Future<String>> _assetTitles = {};
  final Map<String, Future<int>> _assetCountFutures = {};
  final Map<String, Future<List<AssetEntity>>> _assetSortFutures = {};
  final Map<String, Future<List<_InstalledApp>>> _appSortFutures = {};
  final Map<String, Future<android_channel.ApkInfo?>> _apkInfoFutures = {};
  final Queue<Future<void> Function()> _apkInfoQueue = Queue();
  final Queue<Future<void> Function()> _appIconQueue = Queue();
  final Map<String, Future<Uint8List?>> _appIconFutures = {};
  final LinkedHashMap<String, Uint8List> _appIconMemory = LinkedHashMap();
  final Set<String> _appIconsLoadedThisVisit = {};
  final Set<String> _verifiedSafUris = {};
  Timer? _searchDebounce;
  String _searchQuery = '';
  bool _showAlbums = false;
  Future<List<AssetPathEntity>>? _assetPathsFuture;
  AssetPathEntity? _activeAssetPath;
  Future<List<AssetEntity>>? _assetsFuture;
  Future<List<android_channel.FileInfo>>? _systemFilesFuture;
  final Map<String, Future<Uint8List?>> _thumbnailFutures = {};
  final List<android_channel.FileInfo> _additionalSystemFiles = [];
  final List<AssetEntity> _additionalAssets = [];
  final Set<String> _deletedAssetIds = {};
  final Set<String> _scheduledMissingAssetIds = {};
  final Set<String> _selectedFolderUris = {};
  final Map<String, String> _selectedFolderNames = {};
  final List<(String, String)> _treeBreadcrumbs = [];
  String? _treeRootUri;
  String? _currentFolderUri;
  Future<List<android_channel.AndroidBrowseEntry>>? _treeEntriesFuture;
  Future<List<_InstalledApp>>? _installedApplicationsFuture;
  Future<List<android_channel.ApkFile>>? _apkFilesFuture;
  Future<void>? _appRefreshFuture;
  Completer<void>? _resumeCompleter;
  DateTime? _appsOpenedAt;
  bool _leftForeground = false;
  int _activeApkInfoLoads = 0;
  int _activeAppIconLoads = 0;
  int _appIconTargetCount = 0;
  bool _loggedFirstAppCell = false;
  bool _loggedFirstAppIcon = false;
  bool _loggedAllAppIcons = false;
  int _systemFilesOffset = 0;
  int _assetPage = 0;
  bool _hasMoreSystemFiles = false;
  bool _hasMoreAssets = false;
  bool _loadingMoreAssets = false;
  bool _loadingMoreSystemFiles = false;
  bool _systemFilesPageError = false;
  bool _permissionRequired = false;
  bool _permissionPermanentlyDenied = false;
  bool _permissionRequestAttempted = false;
  Future<bool>? _permissionRequest;
  String _saveLocation = 'internal';
  int _reloadCount = 0;
  int _storageRefreshKey = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchController.addListener(_handleSearchControllerChanged);
    _systemFilesFuture = Future.value([]);
    _installedApplicationsFuture = _readCachedInstalledApps();
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
      PhotoManager.addChangeCallback(_onPhotoManagerChange);
      unawaited(_startPhotoChangeNotifications());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _openCategory(_category));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _initializeStorageTree(),
    );
  }

  @override
  void didUpdateWidget(covariant InAppFileBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchController != widget.searchController) {
      (oldWidget.searchController ?? _textController).removeListener(_handleSearchControllerChanged);
      _searchController.addListener(_handleSearchControllerChanged);
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.removeListener(_handleSearchControllerChanged);
    if (widget.searchController == null) _textController.dispose();
    _categoryScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    PhotoManager.removeChangeCallback(_onPhotoManagerChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _leftForeground = true;
    } else if (state == AppLifecycleState.resumed && _leftForeground) {
      _leftForeground = false;
      final completer = _resumeCompleter;
      _resumeCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
      unawaited(_checkPermissionOnResume());
    }
  }

  Future<void> _checkPermissionOnResume() async {
    final granted = await _hasBrowsePermission();
    if (!mounted) return;
    if (granted) {
      if (_permissionRequired) {
        setState(() {
          _permissionRequired = false;
          _permissionPermanentlyDenied = false;
        });
      }
      await _refreshCurrentCategory();
    }
  }

  Future<bool> _hasBrowsePermission() async {
    if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) return true;
    if (defaultTargetPlatform == TargetPlatform.android && (ref.read(deviceInfoProvider).androidSdkInt ?? 0) <= 32) {
      final status = await Permission.storage.status;
      _permissionPermanentlyDenied = status.isPermanentlyDenied;
      return status.isGranted;
    }
    final state = await PhotoManager.getPermissionState(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: false),
      ),
    );
    if (!state.hasAccess) {
      final statuses = defaultTargetPlatform == TargetPlatform.android
          ? await Future.wait([Permission.photos.status, Permission.videos.status, Permission.audio.status])
          : [await Permission.photos.status];
      _permissionPermanentlyDenied = statuses.any((status) => status.isPermanentlyDenied) || state == PermissionState.restricted;
    } else {
      _permissionPermanentlyDenied = false;
    }
    return state.hasAccess;
  }

  Future<bool> _ensureBrowsePermission({bool requestIfNeeded = false, bool explicitRequest = false}) async {
    if (await _hasBrowsePermission()) {
      if (mounted && _permissionRequired) {
        setState(() {
          _permissionRequired = false;
          _permissionPermanentlyDenied = false;
        });
      }
      return true;
    }
    if (!requestIfNeeded || (_permissionRequestAttempted && !explicitRequest)) {
      if (mounted) setState(() => _permissionRequired = true);
      return false;
    }
    final activeRequest = _permissionRequest;
    if (activeRequest != null) return activeRequest;

    _permissionRequestAttempted = true;
    final request = _requestBrowsePermission();
    _permissionRequest = request;
    try {
      final granted = await request;
      if (mounted) {
        setState(() {
          _permissionRequired = !granted;
          _permissionPermanentlyDenied = !granted && _permissionPermanentlyDenied;
        });
      }
      return granted;
    } finally {
      if (identical(_permissionRequest, request)) _permissionRequest = null;
    }
  }

  Future<bool> _requestBrowsePermission() async {
    if (defaultTargetPlatform == TargetPlatform.android && (ref.read(deviceInfoProvider).androidSdkInt ?? 0) <= 32) {
      final status = await Permission.storage.request();
      _permissionPermanentlyDenied = status.isPermanentlyDenied;
      return status.isGranted;
    }
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(type: RequestType.common, mediaLocation: false),
      ),
    );
    if (!state.hasAccess) {
      final statuses = defaultTargetPlatform == TargetPlatform.android
          ? await Future.wait([Permission.photos.status, Permission.videos.status, Permission.audio.status])
          : [await Permission.photos.status];
      _permissionPermanentlyDenied = statuses.any((status) => status.isPermanentlyDenied) || state == PermissionState.restricted;
    } else {
      _permissionPermanentlyDenied = false;
    }
    return state.hasAccess;
  }

  Future<void> _waitForResume() {
    final completer = Completer<void>();
    _resumeCompleter = completer;
    _leftForeground = false;
    return completer.future;
  }

  void _cancelResumeWait() {
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    _leftForeground = false;
  }

  Future<Directory> _installedAppsCacheDirectory() async {
    final directory = Directory(p.join((await getTemporaryDirectory()).path, 'installed_apps'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<_InstalledApp>> _readCachedInstalledApps() async {
    try {
      final directory = await _installedAppsCacheDirectory();
      final cacheFile = File(p.join(directory.path, 'apps.json'));
      if (!await cacheFile.exists()) return [];
      final json = jsonDecode(await cacheFile.readAsString());
      if (json is! List) throw const FormatException('Installed app cache must be a list');
      return json.map((value) => _InstalledApp.fromJson(Map<String, dynamic>.from(value as Map))).toList();
    } catch (error, stackTrace) {
      _logAppsError('apps_cache_read', error, stackTrace);
      return [];
    }
  }

  Future<void> _writeInstalledAppsCache(List<_InstalledApp> apps) async {
    try {
      final directory = await _installedAppsCacheDirectory();
      final cacheFile = File(p.join(directory.path, 'apps.json'));
      final pendingFile = File('${cacheFile.path}.tmp');
      await pendingFile.writeAsString(jsonEncode(apps.map((app) => app.toJson()).toList()), flush: true);
      await pendingFile.rename(cacheFile.path);
    } catch (error, stackTrace) {
      _logAppsError('apps_cache_write', error, stackTrace);
    }
  }

  Future<void> _refreshInstalledAppsInBackground() {
    final current = _appRefreshFuture;
    if (current != null) return current;
    final refresh = _refreshInstalledApps();
    _appRefreshFuture = refresh;
    return refresh.whenComplete(() {
      if (identical(_appRefreshFuture, refresh)) _appRefreshFuture = null;
    });
  }

  Future<void> _refreshInstalledApps() async {
    try {
      final installedApps = await DeviceApps.getInstalledApplications(
        includeSystemApps: true,
        onlyAppsWithLaunchIntent: false,
        includeAppIcons: false,
      );
      final sizes = await compute(_readApkFileLengths, installedApps.map((app) => app.apkFilePath).toList());
      final refreshedApps = List.generate(installedApps.length, (index) {
        if (sizes[index] == null) {
          _logAppsEvent('app_size_unavailable', installedApps[index].packageName);
        }
        return _InstalledApp.fromApplication(installedApps[index], sizes[index]);
      });
      final previousApps = await (_installedApplicationsFuture ??= _readCachedInstalledApps());
      final previousByPackage = {for (final app in previousApps) app.packageName: app};
      final changed =
          previousApps.length != refreshedApps.length ||
          refreshedApps.any((app) => previousByPackage[app.packageName]?.hasSameMetadata(app) != true);
      _appIconTargetCount = refreshedApps.length;
      await _writeInstalledAppsCache(refreshedApps);
      if (changed && mounted) {
        setState(() => _installedApplicationsFuture = Future.value(refreshedApps));
      }
      _logAllAppIconsIfReady();
    } catch (error, stackTrace) {
      _logAppsError('apps_refresh', error, stackTrace);
    }
  }

  void _logAppsEvent(String event, String message) {
    _logger.info('$event $message');
    if (mounted) ref.notifier(pairingControllerProvider).logUiEvent(event, message);
  }

  void _logAppsError(String event, Object error, StackTrace stackTrace) {
    _logger.warning(event, error, stackTrace);
    _logAppsEvent(event, error.toString());
  }

  int? _appElapsedMilliseconds() {
    final started = _appsOpenedAt;
    return started == null ? null : DateTime.now().difference(started).inMilliseconds;
  }

  void _markAppIconLoaded(_InstalledApp app) {
    if (!_appIconsLoadedThisVisit.add(_appIconCacheKey(app))) return;
    final elapsed = _appElapsedMilliseconds();
    if (!_loggedFirstAppIcon && elapsed != null) {
      _loggedFirstAppIcon = true;
      _logAppsEvent('apps_first_icon_ms', '$elapsed package=${app.packageName}');
    }
    _logAllAppIconsIfReady();
  }

  void _logAllAppIconsIfReady() {
    final elapsed = _appElapsedMilliseconds();
    if (!_loggedAllAppIcons && elapsed != null && _appIconTargetCount > 0 && _appIconsLoadedThisVisit.length >= _appIconTargetCount) {
      _loggedAllAppIcons = true;
      _logAppsEvent('apps_all_icons_ms', '$elapsed count=$_appIconTargetCount');
    }
  }

  String _appIconCacheKey(_InstalledApp app) => '${app.packageName}:${app.versionCode}';

  void _cacheAppIcon(String key, Uint8List icon) {
    _appIconMemory.remove(key);
    _appIconMemory[key] = icon;
    while (_appIconMemory.length > 48) {
      _appIconMemory.remove(_appIconMemory.keys.first);
    }
  }

  Future<Uint8List?> _loadAppIcon(_InstalledApp app) async {
    final key = _appIconCacheKey(app);
    final directory = await _installedAppsCacheDirectory();
    final file = File(p.join(directory.path, app.iconFileName));
    try {
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _cacheAppIcon(key, bytes);
        return bytes;
      }
    } on FileSystemException catch (error, stackTrace) {
      _logAppsError('app_icon_cache_read', error, stackTrace);
    }
    final application = await DeviceApps.getApp(app.packageName, true);
    if (application is! ApplicationWithIcon) return null;
    final bytes = application.icon;
    _cacheAppIcon(key, bytes);
    try {
      await file.writeAsBytes(bytes, flush: false);
    } on FileSystemException catch (error, stackTrace) {
      _logAppsError('app_icon_cache_write', error, stackTrace);
    }
    return bytes;
  }

  Future<Uint8List?> _appIconFuture(_InstalledApp app) {
    final key = _appIconCacheKey(app);
    final memoryIcon = _appIconMemory.remove(key);
    if (memoryIcon != null) {
      _appIconMemory[key] = memoryIcon;
      _markAppIconLoaded(app);
      return Future.value(memoryIcon);
    }
    return _appIconFutures.putIfAbsent(key, () {
      final completer = Completer<Uint8List?>();
      final future = completer.future;
      future.then(
        (_) => _appIconFutures.remove(key),
        onError: (Object error, StackTrace stackTrace) => _appIconFutures.remove(key),
      );
      _appIconQueue.add(() async {
        try {
          final icon = await _loadAppIcon(app);
          _markAppIconLoaded(app);
          completer.complete(icon);
        } catch (error, stackTrace) {
          _logAppsError('app_icon_load', error, stackTrace);
          _markAppIconLoaded(app);
          completer.completeError(error, stackTrace);
        }
      });
      _runAppIconQueue();
      return future;
    });
  }

  void _runAppIconQueue() {
    while (_activeAppIconLoads < 2 && _appIconQueue.isNotEmpty) {
      _activeAppIconLoads++;
      unawaited(
        _appIconQueue.removeFirst()().whenComplete(() {
          _activeAppIconLoads--;
          _runAppIconQueue();
        }),
      );
    }
  }

  Future<List<android_channel.ApkFile>> _loadApkFiles() async {
    if (defaultTargetPlatform != TargetPlatform.android) return [];
    try {
      final files = await android_channel.findApkFilesAndroid();
      files.sort((left, right) => right.modified.compareTo(left.modified));
      return files.take(500).toList();
    } catch (error, stackTrace) {
      _logStorageError('find_apk_files', error, stackTrace);
      rethrow;
    }
  }

  void _refreshStorageStats() {
    if (mounted) setState(() => _storageRefreshKey++);
  }

  void _logStorageError(String step, Object error, StackTrace stackTrace) {
    final technicalDetails = error is android_channel.AndroidStorageException
        ? '${error.nativeCode}: ${error.technicalMessage ?? ''} ${error.technicalDetails ?? ''}'.trim()
        : error.toString();
    _logger.warning(step, error, stackTrace);
    ref.notifier(pairingControllerProvider).logUiEvent(step, technicalDetails);
  }

  Future<void> _startPhotoChangeNotifications() async {
    try {
      if (!PhotoManager.notifyingOfChange) await PhotoManager.startChangeNotify();
    } catch (error, stackTrace) {
      _logPhotoError('photo_change_notifications', error, stackTrace);
    }
  }

  void _onPhotoManagerChange(MethodCall _) {
    if (!mounted || !const {_BrowserCategory.images, _BrowserCategory.videos, _BrowserCategory.audio}.contains(_category)) return;
    unawaited(_refreshAfterPhotoChange());
  }

  Future<void> _refreshAfterPhotoChange() async {
    try {
      await PhotoManager.clearFileCache();
    } catch (error, stackTrace) {
      _logPhotoError('clear_changed_photo_cache', error, stackTrace);
    }
    if (mounted) await _refreshCurrentCategory();
  }

  void _handleSearchControllerChanged() => _onSearchChanged(_searchController.text);

  Future<void> _openCategory(_BrowserCategory category) async {
    widget.onUserActivity?.call();
    _logBrowserReload(category);
    if (category == _BrowserCategory.apps) {
      _appsOpenedAt = DateTime.now();
      _loggedFirstAppCell = false;
      _loggedFirstAppIcon = false;
      _loggedAllAppIcons = false;
      _appIconsLoadedThisVisit.clear();
      unawaited(_refreshInstalledAppsInBackground());
    }
    setState(() {
      _category = category;
      _additionalSystemFiles.clear();
      _systemFilesOffset = 0;
      _hasMoreSystemFiles = false;
      _loadingMoreSystemFiles = false;
      _systemFilesPageError = false;
    });
    widget.onCategoryChanged?.call(category.label);
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
    } else if (category == _BrowserCategory.apps) {
      _apkFilesFuture ??= _loadApkFiles();
      unawaited(
        (_installedApplicationsFuture ??= _readCachedInstalledApps()).then((apps) {
          if (!mounted || _appsOpenedAt == null) return;
          _appIconTargetCount = apps.length;
          _logAllAppIconsIfReady();
        }),
      );
    }
    _scrollCategoryIntoView(category);
  }

  void _onSearchChanged(String value) {
    widget.onUserActivity?.call();
    _searchDebounce?.cancel();
    _cancelResumeWait();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _searchQuery = value.trim().toLowerCase());
      widget.onSearchChanged?.call(value);
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

  int _compareValues({
    required String nameA,
    required String nameB,
    DateTime? dateA,
    DateTime? dateB,
    int? sizeA,
    int? sizeB,
  }) {
    final result = switch (widget.sortMode) {
      BrowserSortMode.name => nameA.toLowerCase().compareTo(nameB.toLowerCase()),
      BrowserSortMode.date => (dateA ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(dateB ?? DateTime.fromMillisecondsSinceEpoch(0)),
      BrowserSortMode.size => (sizeA ?? 0).compareTo(sizeB ?? 0),
    };
    return widget.sortAscending ? result : -result;
  }

  List<android_channel.FileInfo> _sortFileInfos(Iterable<android_channel.FileInfo> source) {
    final files = source.toList();
    files.sort(
      (a, b) => _compareValues(
        nameA: _displayFileName(displayName: a.name, uri: a.uri),
        nameB: _displayFileName(displayName: b.name, uri: b.uri),
        dateA: DateTime.tryParse(a.lastModified ?? ''),
        dateB: DateTime.tryParse(b.lastModified ?? ''),
        sizeA: a.size,
        sizeB: b.size,
      ),
    );
    return files;
  }

  List<android_channel.AndroidBrowseEntry> _sortEntries(Iterable<android_channel.AndroidBrowseEntry> source) {
    final entries = source.toList();
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return _compareValues(
        nameA: _displayFileName(displayName: a.name, uri: a.uri),
        nameB: _displayFileName(displayName: b.name, uri: b.uri),
        dateA: DateTime.tryParse(a.lastModified ?? ''),
        dateB: DateTime.tryParse(b.lastModified ?? ''),
        sizeA: a.size,
        sizeB: b.size,
      );
    });
    return entries;
  }

  Future<List<AssetEntity>> _sortAssets(List<AssetEntity> source) async {
    final assets = [...source];
    if (widget.sortMode == BrowserSortMode.name) {
      final names = await Future.wait(
        assets.map((asset) => _assetTitles.putIfAbsent(asset.id, () => asset.titleAsync)),
      );
      final keyed = List.generate(assets.length, (index) => (assets[index], names[index]));
      keyed.sort((a, b) {
        final value = a.$2.toLowerCase().compareTo(b.$2.toLowerCase());
        return widget.sortAscending ? value : -value;
      });
      return keyed.map((entry) => entry.$1).toList();
    }
    if (widget.sortMode == BrowserSortMode.size) {
      final sizes = await Future.wait(assets.map((asset) => asset.fileSize));
      final keyed = List.generate(assets.length, (index) => (assets[index], sizes[index]));
      keyed.sort((a, b) {
        final value = a.$2.compareTo(b.$2);
        return widget.sortAscending ? value : -value;
      });
      return keyed.map((entry) => entry.$1).toList();
    }
    assets.sort((a, b) {
      final value = a.createDateTime.compareTo(b.createDateTime);
      return widget.sortAscending ? value : -value;
    });
    return assets;
  }

  Future<List<AssetEntity>> _sortedAssets(List<AssetEntity> source) {
    final key =
        '${_category.name}:${_activeAssetPath?.id}:${widget.sortMode.name}:${widget.sortAscending}:${source.map((asset) => asset.id).join(',')}';
    return _assetSortFutures.putIfAbsent(key, () => _sortAssets(source));
  }

  Future<List<_InstalledApp>> _sortedApps(List<_InstalledApp> source) {
    final key = '${widget.sortMode.name}:${widget.sortAscending}:${source.map((app) => '${app.packageName}:${app.versionCode}:${app.size}').join(',')}';
    return _appSortFutures.putIfAbsent(key, () async {
      final sorted = await compute(_sortInstalledApps, {
        'apps': source.map((app) => app.toJson()).toList(),
        'sortMode': widget.sortMode.name,
        'ascending': widget.sortAscending,
      });
      return sorted.map(_InstalledApp.fromJson).toList();
    });
  }

  void _logBrowserReload(_BrowserCategory category) {
    debugPrint('Browser data load #${++_reloadCount}: ${category.name}');
  }

  Future<void> _refreshCurrentCategory() async {
    _logBrowserReload(_category);
    switch (_category) {
      case _BrowserCategory.images:
        await _retryPhotoQuery();
        break;
      case _BrowserCategory.videos:
      case _BrowserCategory.audio:
        if (defaultTargetPlatform == TargetPlatform.android) {
          setState(() {
            _additionalSystemFiles.clear();
            _systemFilesOffset = 0;
            _systemFilesFuture = _loadSystemFiles(_category);
          });
        } else {
          await _retryPhotoQuery();
        }
        break;
      case _BrowserCategory.downloads:
      case _BrowserCategory.documents:
        setState(() {
          _additionalSystemFiles.clear();
          _systemFilesOffset = 0;
          _systemFilesFuture = _loadSystemFiles(_category);
        });
        break;
      case _BrowserCategory.files:
      case _BrowserCategory.text:
        final uri = _currentFolderUri;
        if (uri != null) setState(() => _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: uri));
        break;
      case _BrowserCategory.apps:
        setState(() => _apkFilesFuture = _loadApkFiles());
        unawaited(_refreshInstalledAppsInBackground());
        break;
    }
  }

  void _logPhotoError(String step, Object error, StackTrace stackTrace) {
    _logger.warning(step, error, stackTrace);
    ref.notifier(pairingControllerProvider).logUiEvent(step, error.toString());
  }

  Future<void> _retryPhotoQuery({AssetPathEntity? path}) async {
    final category = _category;
    if (path == null) {
      final future = _loadAssetPaths(category);
      setState(() {
        _assetPathsFuture = future;
        _assetsFuture = null;
        _additionalAssets.clear();
        _assetPage = 0;
        _hasMoreAssets = false;
      });
      if (category != _BrowserCategory.images) {
        setState(() => _assetsFuture = _loadAssets(category));
      }
      return;
    }
    final future = _loadAssets(category, path: path);
    setState(() {
      _assetsFuture = future;
      _additionalAssets.clear();
      _assetPage = 0;
      _hasMoreAssets = false;
    });
  }

  Future<void> _composeAndSendMessage() async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => const MessageInputDialog(),
    );
    if (!mounted || message == null || message.trim().isEmpty) return;
    ref.redux(selectedSendingFilesProvider).dispatch(AddMessageAction(message: message));
    await widget.onSendMessage?.call();
  }

  String _displayFileName({
    String? displayName,
    String? title,
    String? path,
    String? uri,
  }) {
    for (final candidate in [displayName, title]) {
      final value = candidate?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    final pathName = path?.split(RegExp(r'[/\\]')).last.trim();
    if (pathName != null && pathName.isNotEmpty) return pathName;
    final uriSegments = uri == null ? null : Uri.tryParse(uri)?.pathSegments;
    final uriPath = uriSegments == null || uriSegments.isEmpty ? null : uriSegments.last;
    final uriName = uriPath?.split('/').last.trim();
    return uriName == null || uriName.isEmpty ? BrowserStrings.unnamedFile : uriName;
  }

  Future<List<android_channel.FileInfo>> _loadSystemFiles(
    _BrowserCategory category,
  ) async {
    try {
      if (defaultTargetPlatform != TargetPlatform.android) return [];
      if (!await _ensureBrowsePermission(requestIfNeeded: true)) return [];
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
    try {
      if (!await _ensureBrowsePermission(requestIfNeeded: true)) return [];
      return PhotoManager.getAssetPathList(
        type: type,
        hasAll: true,
        filterOption: newestFirstPhotoFilter(),
      );
    } catch (error, stackTrace) {
      _logPhotoError('photo_paths_${category.name}', error, stackTrace);
      rethrow;
    }
  }

  Future<List<AssetEntity>> _loadAssets(
    _BrowserCategory category, {
    AssetPathEntity? path,
  }) async {
    try {
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
    } catch (error, stackTrace) {
      _logPhotoError('photo_assets_${category.name}', error, stackTrace);
      rethrow;
    }
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
      _logPhotoError('photo_page_${category.name}', error, stackTrace);
      if (mounted && category == _category) setState(() => _loadingMoreAssets = false);
    }
  }

  Future<List<AssetEntity>> _filterAssets(List<AssetEntity> assets) async {
    final existingAssets = assets.where((asset) => !_deletedAssetIds.contains(asset.id)).toList();
    if (_searchQuery.isEmpty) return existingAssets;
    final matches = await Future.wait(
      existingAssets.map((asset) async {
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
    () async {
      try {
        return await path.getAssetListPaged(page: 0, size: 1);
      } catch (error, stackTrace) {
        _logPhotoError('photo_album_cover', error, stackTrace);
        rethrow;
      }
    },
  );

  Future<void> _toggleApp(_InstalledApp app) async {
    final size = app.size ?? await File(app.apkFilePath).length();
    await _toggleFile(
      CrossFile(
        name: '${app.appName.trim()} - v${app.versionName}.apk',
        fileType: FileType.apk,
        thumbnail: _appIconMemory[_appIconCacheKey(app)],
        size: size,
        asset: null,
        path: app.apkFilePath,
        bytes: null,
        lastModified: null,
        lastAccessed: null,
      ),
    );
  }

  Future<void> _toggleAsset(AssetEntity asset) async {
    await _toggleFile(await CrossFileConverters.convertAssetEntity(asset));
  }

  Future<void> _toggleSystemFile(android_channel.FileInfo file) async {
    final namedFile = android_channel.FileInfo(
      name: _displayFileName(displayName: file.name, uri: file.uri),
      size: file.size,
      uri: file.uri,
      lastModified: file.lastModified,
    );
    await _toggleFile(await CrossFileConverters.convertFileInfo(namedFile));
  }

  Future<void> _toggleFolder(android_channel.AndroidBrowseEntry entry) async {
    final file = CrossFile(
      name: entry.name,
      fileType: FileType.other,
      size: entry.size,
      thumbnail: null,
      asset: null,
      path: entry.uri,
      bytes: null,
      lastModified: entry.lastModified,
      lastAccessed: null,
    );
    if (_isPathSelected(entry.uri)) {
      _selectedFolderUris.remove(entry.uri);
      _selectedFolderNames.remove(entry.uri);
    } else {
      _selectedFolderUris.add(entry.uri);
      _selectedFolderNames[entry.uri] = entry.name;
    }
    await _toggleFile(file);
  }

  Future<List<CrossFile>?> filesForSending(List<CrossFile> selection) async {
    final files = <CrossFile>[];
    final seenPaths = <String>{};
    try {
      for (final selected in selection) {
        final path = selected.path;
        if (path == null || !_selectedFolderUris.contains(path)) {
          if (path == null || seenPaths.add(path)) files.add(selected);
          continue;
        }

        final folderName = _selectedFolderNames[path] ?? selected.name;
        final folderFiles = await android_channel.listFolderTreeFilesAndroid(uri: path);
        for (final file in folderFiles) {
          if (!seenPaths.add(file.uri)) continue;
          files.add(
            await CrossFileConverters.convertFileInfo(
              file,
              name: p.join(folderName, file.name),
            ),
          );
        }
      }
    } catch (error, stackTrace) {
      _logStorageError('expand_selected_folder_for_send', error, stackTrace);
      _showBrowserMessage(BrowserStrings.couldNotLoadCategoryFiles);
      return null;
    }
    return files;
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

  Future<void> handleDeleteSelection() async {
    if (defaultTargetPlatform != TargetPlatform.android || !mounted) return;
    final selection = ref.read(selectedSendingFilesProvider);
    if (selection.isEmpty) return;

    late final List<Application> installedApps;
    try {
      installedApps = await DeviceApps.getInstalledApplications(
        includeSystemApps: true,
        onlyAppsWithLaunchIntent: false,
        includeAppIcons: false,
      );
    } catch (error, stackTrace) {
      _logStorageError('load_installed_apps_for_uninstall', error, stackTrace);
      _showBrowserMessage(BrowserStrings.uninstallFailed);
      return;
    }
    if (!mounted) return;

    final appsByPath = {for (final app in installedApps) app.apkFilePath: app};
    final selectedApps = <({CrossFile file, Application app})>[];
    final files = <CrossFile>[];
    for (final file in selection) {
      final app = file.path == null ? null : appsByPath[file.path];
      if (app == null) {
        files.add(file);
      } else {
        selectedApps.add((file: file, app: app));
      }
    }

    final blockedByTransfer = <String>{};
    for (final file in [...files, ...selectedApps.map((entry) => entry.file)]) {
      try {
        final path = await _verifiedPathForTransferCheck(file);
        if (path != null && _isPathInActiveTransfer(path)) blockedByTransfer.add(path);
      } catch (error, stackTrace) {
        _logStorageError('resolve_transfer_path', error, stackTrace);
      }
    }
    if (blockedByTransfer.isNotEmpty) _showBrowserMessage(BrowserStrings.activeTransferDeleteBlocked);

    final restrictedApps = selectedApps.where((entry) {
      final packageName = entry.app.packageName;
      return entry.app.systemApp || packageName == _selfPackageName || packageName == '$_selfPackageName.debug';
    }).toList();
    final eligibleApps = selectedApps.where((entry) {
      final packageName = entry.app.packageName;
      return !entry.app.systemApp &&
          packageName != _selfPackageName &&
          packageName != '$_selfPackageName.debug' &&
          !blockedByTransfer.contains(entry.file.path);
    }).toList();
    if (restrictedApps.isNotEmpty) _showBrowserMessage(BrowserStrings.restrictedAppsSkipped);

    if (!mounted) return;
    if (eligibleApps.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: Text(BrowserStrings.uninstallAppsConfirmation(eligibleApps.length)),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text(BrowserStrings.cancel)),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text(BrowserStrings.uninstall)),
          ],
        ),
      );
      if (!mounted) return;
      if (confirmed == true) await _uninstallSelectedApps(eligibleApps);
    }

    final fileCandidates = files.where((file) => file.path == null || !blockedByTransfer.contains(file.path)).toList();
    if (fileCandidates.isNotEmpty) await _deleteSelectedFiles(fileCandidates);
  }

  Future<void> _uninstallSelectedApps(List<({CrossFile file, Application app})> apps) async {
    for (final entry in apps) {
      if (!mounted) return;
      final resume = _waitForResume();
      try {
        ref.notifier(pairingControllerProvider).logUiEvent('uninstall_launch', entry.app.packageName);
        await android_channel.uninstallAppAndroid(packageName: entry.app.packageName);
        await resume;
        if (!mounted) return;
        final installedApps = await DeviceApps.getInstalledApplications(
          includeSystemApps: true,
          onlyAppsWithLaunchIntent: false,
          includeAppIcons: false,
        );
        final stillInstalled = installedApps.any((app) => app.packageName == entry.app.packageName);
        ref.notifier(pairingControllerProvider).logUiEvent('uninstall_return', '${entry.app.packageName} stillInstalled=$stillInstalled');
        if (stillInstalled) continue;
        _removeSelectedPaths({entry.file.path!});
      } catch (error, stackTrace) {
        _cancelResumeWait();
        _logStorageError('uninstall_app', error, stackTrace);
        _showBrowserMessage(
          error is android_channel.AndroidStorageException ? BrowserStrings.storageError(error.code) : BrowserStrings.uninstallFailed,
        );
      }
    }

    if (!mounted) return;
    _reloadCount++;
    unawaited(_refreshInstalledAppsInBackground());
    _refreshStorageStats();
  }

  Future<void> _deleteSelectedFiles(List<CrossFile> files) async {
    final sdk = ref.read(deviceInfoProvider).androidSdkInt ?? 0;
    final targets = <({CrossFile file, String path})>[];
    for (final file in files) {
      try {
        final path = await _verifiedDeletePath(file);
        if (path != null) targets.add((file: file, path: path));
      } catch (error, stackTrace) {
        _logDeleteRejected(file, 'path verification failed (${error.runtimeType})');
        _logger.warning('Could not verify delete path for ${file.name}', error, stackTrace);
      }
    }
    if (targets.length != files.length) _showBrowserMessage(BrowserStrings.filesCouldNotBeIdentified);
    if (targets.isEmpty || !mounted) return;
    if (sdk <= 29 && targets.any((target) => !target.path.startsWith('content://')) && !await _ensureBrowsePermission(requestIfNeeded: false)) {
      if (mounted) setState(() => _permissionRequired = true);
      return;
    }
    if (!mounted) return;

    final totalBytes = targets.fold<int>(0, (sum, target) => sum + target.file.size);
    final sizeInMb = '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    final selectedFolders = targets.where((target) => _selectedFolderUris.contains(target.path)).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(
          selectedFolders.length == 1 && targets.length == 1
              ? BrowserStrings.deleteFolderConfirmation(_selectedFolderNames[selectedFolders.single.path] ?? selectedFolders.single.file.name)
              : BrowserStrings.deleteFilesConfirmation(targets.length, sizeInMb),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text(BrowserStrings.cancel)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text(BrowserStrings.delete)),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    try {
      final result = await android_channel.deleteFilesAndroid(paths: targets.map((target) => target.path).toList());
      if (result.cancelled) return;
      if (result.deleted.isNotEmpty) {
        final deletedPaths = result.deleted.toSet();
        final selectedPaths = {
          ...deletedPaths,
          for (final target in targets)
            if (deletedPaths.contains(target.path) && target.file.path != null) target.file.path!,
        };
        final deletedAssets = targets
            .where((target) => deletedPaths.contains(target.path) && target.file.asset != null)
            .map((target) => target.file.asset!.id)
            .toSet();
        setState(() {
          _deletedAssetIds.addAll(deletedAssets);
          _additionalAssets.removeWhere((asset) => deletedAssets.contains(asset.id));
          _selectedFolderUris.removeAll(deletedPaths);
          for (final path in deletedPaths) {
            _selectedFolderNames.remove(path);
          }
        });
        _removeSelectedPaths(selectedPaths);
        try {
          await PhotoManager.clearFileCache();
        } catch (error, stackTrace) {
          _logPhotoError('clear_deleted_photo_cache', error, stackTrace);
        }
        await _reloadAffectedCategories();
        _refreshStorageStats();
      }
      if (result.failed.isNotEmpty) _showBrowserMessage(BrowserStrings.failedDeleteCount(result.failed.length));
    } catch (error, stackTrace) {
      _logStorageError('delete_files', error, stackTrace);
      _showBrowserMessage(
        error is android_channel.AndroidStorageException ? BrowserStrings.storageError(error.code) : BrowserStrings.storageActionFailed,
      );
    }
  }

  Future<void> _reloadAffectedCategories() async {
    if (!mounted) return;
    setState(() {
      _assetPathsFuture = null;
      _assetsFuture = null;
      _additionalAssets.clear();
      _assetPage = 0;
      _hasMoreAssets = false;
      _systemFilesFuture = null;
      _additionalSystemFiles.clear();
      _systemFilesOffset = 0;
      _hasMoreSystemFiles = false;
      _treeEntriesFuture = _currentFolderUri == null ? null : android_channel.listFolderTreeAndroid(uri: _currentFolderUri!);
    });
    await _refreshCurrentCategory();
  }

  Future<String?> _verifiedDeletePath(CrossFile file) async {
    if (file.asset != null) {
      final mediaCollection = switch (file.asset!.type) {
        AssetType.image => 'images',
        AssetType.video => 'video',
        AssetType.audio => 'audio',
        _ => null,
      };
      if (mediaCollection != null) {
        final mediaUri = 'content://media/external/$mediaCollection/media/${file.asset!.id}';
        if (isMediaStoreContentUri(mediaUri)) return mediaUri;
      }
      final origin = await file.asset!.originFile;
      if (origin == null) {
        _logDeleteRejected(file, 'photo asset has no original file');
        return null;
      }
      if (!p.isAbsolute(origin.path)) {
        _logDeleteRejected(file, 'photo asset path is not absolute');
        return null;
      }
      if (await FileSystemEntity.type(origin.path) != FileSystemEntityType.file) {
        _logDeleteRejected(file, 'photo asset path is not an existing file');
        return null;
      }
      return origin.path;
    }
    final path = file.path;
    if (path == null || path.isEmpty) {
      _logDeleteRejected(file, 'missing path');
      return null;
    }
    if (isMediaStoreContentUri(path)) return path;
    if (path.startsWith('content://')) {
      if (!_verifiedSafUris.contains(path)) {
        _logDeleteRejected(file, 'content URI is neither a verified MediaStore URI nor a browsed SAF URI');
        return null;
      }
      if (path == _treeRootUri || _selectedFolderNames[path]?.toLowerCase() == 'android') {
        _logDeleteRejected(file, 'storage root and Android folder are protected');
        return null;
      }
      return path;
    }
    final source = File(path);
    if (!p.isAbsolute(source.path)) {
      _logDeleteRejected(file, 'file path is not absolute');
      return null;
    }
    if (await FileSystemEntity.type(source.path) != FileSystemEntityType.file) {
      _logDeleteRejected(file, 'file path is not an existing file');
      return null;
    }
    return path;
  }

  void _logDeleteRejected(CrossFile file, String reason) {
    final message = '${file.name}: $reason';
    _logger.warning('Delete target rejected: $message');
    ref.notifier(pairingControllerProvider).logUiEvent('delete_target_rejected', message);
  }

  Future<String?> _verifiedPathForTransferCheck(CrossFile file) async {
    if (file.asset != null) {
      final origin = await file.asset!.originFile;
      return origin?.path;
    }
    return file.path;
  }

  bool _isPathInActiveTransfer(String path) {
    final sendSessions = ref.read(sendProvider).values;
    final receiveSession = ref.read(serverProvider)?.session;
    final transfers = <({SessionStatus status, Iterable<String> paths})>[
      for (final session in sendSessions)
        (
          status: session.status,
          paths: session.files.values.map((file) => file.path).whereType<String>(),
        ),
      if (receiveSession != null)
        (
          status: receiveSession.status,
          paths: receiveSession.files.values.map((file) => _receivingFilePath(receiveSession, file)).whereType<String>(),
        ),
    ];
    return activeTransferContainsPath(path: path, transfers: transfers);
  }

  String? _receivingFilePath(ReceiveSessionState session, ReceivingFile file) {
    if (file.path != null) return file.path;
    final desiredName = file.desiredName ?? file.file.fileName;
    return p.join(session.destinationDirectory, desiredName);
  }

  void _removeSelectedPaths(Set<String> paths) {
    final selected = ref.read(selectedSendingFilesProvider);
    for (var index = selected.length - 1; index >= 0; index--) {
      if (selected[index].path != null && paths.contains(selected[index].path)) {
        ref.redux(selectedSendingFilesProvider).dispatch(RemoveSelectedFileAction(index));
      }
    }
  }

  void _showBrowserMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isAssetSelected(AssetEntity asset) => ref.read(selectedSendingFilesProvider).any((file) => file.asset?.id == asset.id);

  bool _isPathSelected(String path) => ref.read(selectedSendingFilesProvider).any((file) => file.path == path);

  Future<int> _assetCountFuture(AssetPathEntity path) => _assetCountFutures.putIfAbsent(path.id, () {
    return () async {
      try {
        return await path.assetCountAsync;
      } catch (error, stackTrace) {
        _logPhotoError('photo_album_count', error, stackTrace);
        rethrow;
      }
    }();
  });

  Widget _assetCountIndicator(AssetPathEntity path) {
    return FutureBuilder<int>(
      future: _assetCountFuture(path),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Tooltip(
            message: BrowserStrings.couldNotLoadImages,
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
    super.build(context);
    context.watch(selectedSendingFilesProvider);
    final tokens = BrowserThemeTokens.of(context);
    final categories = _BrowserCategory.values;
    return Column(
      children: [
        SizedBox(
          height: 50 * 2 / 3,
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
                        horizontal: 10,
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
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            child: _category == category
                                ? Text(
                                    category.label,
                                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                      color: tokens.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : const SizedBox.shrink(),
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
                margin: EdgeInsets.fromLTRB(8, 0, 8, _category == _BrowserCategory.files ? 0 : 8),
                padding: EdgeInsets.zero,
                borderRadius: BorderRadius.circular(glassRadiusCard),
                child: RefreshIndicator(
                  onRefresh: _refreshCurrentCategory,
                  child: ScrollConfiguration(
                    behavior: const _AlwaysScrollableBrowserBehavior(),
                    child: _buildCategoryBody(),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_category == _BrowserCategory.files) ...[
          const SizedBox(height: 8),
          StorageStatisticsCard(refreshKey: _storageRefreshKey, onRetry: _refreshStorageStats),
        ],
      ],
    );
  }

  Widget _permissionAction() => FilledButton.icon(
    onPressed: () async {
      if (_permissionPermanentlyDenied) {
        await openAppSettings();
        return;
      }
      if (!await _ensureBrowsePermission(requestIfNeeded: true, explicitRequest: true)) return;
      if (!mounted) return;
      setState(() => _permissionRequired = false);
      await _refreshCurrentCategory();
    },
    icon: Icon(_permissionPermanentlyDenied ? Icons.settings_outlined : Icons.lock_open_outlined),
    label: Text(_permissionPermanentlyDenied ? BrowserStrings.openSettings : BrowserStrings.allowAccess),
  );

  Widget _permissionRequiredState() => _emptyState(
    icon: Icons.folder_off_outlined,
    message: BrowserStrings.storagePermissionRequired,
    action: _permissionAction(),
  );

  Widget _buildCategoryBody() {
    if (_permissionRequired) return _permissionRequiredState();
    return switch (_category) {
      _BrowserCategory.images => _buildImagesBrowser(),
      _BrowserCategory.videos ||
      _BrowserCategory.audio => defaultTargetPlatform == TargetPlatform.android ? _buildAndroidMediaBrowser() : _buildMediaBrowser(),
      _BrowserCategory.apps => _buildAppsBrowser(),
      _BrowserCategory.text => _buildFilesBrowser(textOnly: true),
      _BrowserCategory.downloads || _BrowserCategory.documents => _buildSystemFileBrowser(),
      _BrowserCategory.files => _buildFilesBrowser(),
    };
  }

  Widget _buildImagesBrowser() {
    final future = _assetPathsFuture ??= _loadAssetPaths(_category);
    return FutureBuilder<List<AssetPathEntity>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: BrowserStrings.couldNotLoadImages,
            action: TextButton.icon(
              onPressed: () => _retryPhotoQuery(),
              icon: const Icon(Icons.refresh),
              label: const Text(BrowserStrings.retry),
            ),
          );
        }
        final albums = snapshot.data ?? [];
        if (albums.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _permissionRequired ? BrowserStrings.mediaPermissionRequired : BrowserStrings.noImagesFound,
            action: _permissionRequired ? _permissionAction() : null,
          );
        }
        final photoAlbums = albums.length > 1 ? albums.skip(1).toList() : albums;
        final activeAlbum = _activeAssetPath ?? albums.first;
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
              child: _showAlbums ? _buildAlbumsList(photoAlbums) : _buildPhotosGrid(activeAlbum),
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
            message: BrowserStrings.couldNotLoadPhotos,
            action: TextButton.icon(
              onPressed: () => _retryPhotoQuery(path: album),
              icon: const Icon(Icons.refresh),
              label: const Text(BrowserStrings.retry),
            ),
          );
        final assets = [...?snapshot.data, ..._additionalAssets].where((asset) => !_deletedAssetIds.contains(asset.id)).toList();
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
            return FutureBuilder<List<AssetEntity>>(
              future: _sortedAssets(filteredAssets),
              builder: (context, sortedSnapshot) {
                if (sortedSnapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final sortedAssets = sortedSnapshot.data ?? filteredAssets;
                return NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.extentAfter < 360 && !_loadingMoreAssets) {
                      _loadMoreAssets(_BrowserCategory.images, album);
                    }
                    return false;
                  },
                  child: widget.sortMode == BrowserSortMode.date ? _buildChronologicalPhotoGrid(sortedAssets) : _buildFlatPhotoGrid(sortedAssets),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildFlatPhotoGrid(List<AssetEntity> assets) => GridView.builder(
    key: const PageStorageKey<String>('browser-photos-sorted'),
    padding: const EdgeInsets.all(6),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      crossAxisSpacing: 4,
      mainAxisSpacing: 4,
    ),
    itemCount: assets.length,
    itemBuilder: (context, index) => _photoCell(assets[index]),
  );

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
                errorBuilder: (context, error, stackTrace) {
                  _scheduleMissingAssetRemoval(asset);
                  return const SizedBox.shrink();
                },
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

  void _scheduleMissingAssetRemoval(AssetEntity asset) {
    if (!_scheduledMissingAssetIds.add(asset.id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledMissingAssetIds.remove(asset.id);
      if (!mounted || !_deletedAssetIds.add(asset.id)) return;
      setState(() {
        _additionalAssets.removeWhere((candidate) => candidate.id == asset.id);
      });
    });
  }

  Widget _buildMediaBrowser() {
    final future = _assetsFuture;
    if (future == null) return const Center(child: CircularProgressIndicator());
    return FutureBuilder<List<AssetEntity>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: BrowserStrings.couldNotLoadMedia,
            action: TextButton.icon(
              onPressed: () => _retryPhotoQuery(),
              icon: const Icon(Icons.refresh),
              label: const Text(BrowserStrings.retry),
            ),
          );
        }
        final assets = [...?snapshot.data, ..._additionalAssets].where((asset) => !_deletedAssetIds.contains(asset.id)).toList();
        if (assets.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _permissionRequired ? BrowserStrings.mediaPermissionRequired : BrowserStrings.noCategoryFiles,
            action: _permissionRequired
                ? _permissionAction()
                : TextButton.icon(
                    onPressed: () => _retryPhotoQuery(),
                    icon: const Icon(Icons.refresh),
                    label: const Text(BrowserStrings.checkAccess),
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
            return FutureBuilder<List<AssetEntity>>(
              future: _sortedAssets(filtered),
              builder: (context, sortedSnapshot) {
                if (sortedSnapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
                final sorted = sortedSnapshot.data ?? filtered;
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
                    itemCount: sorted.length,
                    itemBuilder: (context, index) {
                      final asset = sorted[index];
                      final selected = _isAssetSelected(asset);
                      final title = _assetTitles.putIfAbsent(asset.id, () => asset.titleAsync);
                      return FutureBuilder<String>(
                        future: title,
                        builder: (context, titleSnapshot) => _fileRow(
                          selected: selected,
                          icon: _category == _BrowserCategory.videos ? Icons.movie_outlined : Icons.audio_file_outlined,
                          title: _displayFileName(title: titleSnapshot.data),
                          subtitle: _category.label,
                          leading: _category == _BrowserCategory.videos
                              ? SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(glassRadiusSmall),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        AssetEntityImage(
                                          asset,
                                          isOriginal: false,
                                          thumbnailSize: const ThumbnailSize.square(180),
                                          fit: BoxFit.cover,
                                        ),
                                        Center(
                                          child: Icon(Icons.play_circle_fill, color: BrowserThemeTokens.of(context).textPrimary),
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
      },
    );
  }

  Widget _buildAppsBrowser() {
    final appsFuture = _installedApplicationsFuture ??= _readCachedInstalledApps();
    final apkFilesFuture = _apkFilesFuture ??= _loadApkFiles();
    return FutureBuilder<List<_InstalledApp>>(
      future: appsFuture,
      builder: (context, appsSnapshot) {
        if (appsSnapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        final apps = appsSnapshot.data ?? [];
        final matchingApps = apps.where((app) => _matchesSearch('${app.appName} ${app.packageName}')).toList();
        return FutureBuilder<List<_InstalledApp>>(
          future: _sortedApps(matchingApps),
          builder: (context, sortedSnapshot) {
            if (sortedSnapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            final orderedApps = sortedSnapshot.data ?? matchingApps;
            final orderedLocalApps = orderedApps.where((app) => !app.systemApp).toList();
            final orderedSystemApps = orderedApps.where((app) => app.systemApp).toList();
            return FutureBuilder<List<android_channel.ApkFile>>(
              future: apkFilesFuture,
              builder: (context, apkSnapshot) {
                final apkFiles = (apkSnapshot.data ?? []).where((file) => _matchesSearch(file.name)).toList();
                return CustomScrollView(
                  key: const PageStorageKey<String>('browser-apps'),
                  cacheExtent: 500,
                  slivers: [
                    _appSectionHeader(BrowserStrings.localApps, orderedLocalApps.length),
                    _appGrid(orderedLocalApps),
                    _appSectionHeader(BrowserStrings.systemApps, orderedSystemApps.length),
                    _appGrid(orderedSystemApps),
                    if (appsSnapshot.hasError)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(BrowserStrings.couldNotLoadInstalledApps),
                        ),
                      ),
                    if (matchingApps.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(_searchQuery.isEmpty ? BrowserStrings.noApplications : BrowserStrings.noFilesFound),
                        ),
                      ),
                    if (apkSnapshot.connectionState == ConnectionState.done) ...[
                      _appSectionHeader(BrowserStrings.apkFiles, apkFiles.length),
                      _apkGrid(apkFiles),
                      if (apkSnapshot.hasError)
                        SliverToBoxAdapter(
                          child: TextButton(
                            onPressed: () => setState(() => _apkFilesFuture = _loadApkFiles()),
                            child: const Text(BrowserStrings.couldNotLoadApkFiles),
                          ),
                        ),
                    ] else ...[
                      _appSectionHeader(BrowserStrings.apkFiles, 0),
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  SliverPersistentHeader _appSectionHeader(String title, int count) => SliverPersistentHeader(
    pinned: true,
    delegate: _AppSectionHeaderDelegate(title: title, count: count),
  );

  Widget _appGrid(List<_InstalledApp> apps) => apps.isEmpty
      ? const SliverToBoxAdapter(child: SizedBox.shrink())
      : SliverPadding(
          padding: const EdgeInsets.all(4),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1.0,
            ),
            itemCount: apps.length,
            addAutomaticKeepAlives: false,
            itemBuilder: (context, index) => _appCell(apps[index]),
          ),
        );

  Widget _apkGrid(List<android_channel.ApkFile> files) => files.isEmpty
      ? const SliverToBoxAdapter(child: SizedBox.shrink())
      : SliverPadding(
          padding: const EdgeInsets.all(4),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1.0,
            ),
            itemCount: files.length,
            itemBuilder: (context, index) => _apkCell(files[index]),
          ),
        );

  Widget _apkCell(android_channel.ApkFile apkFile) {
    return ApkFileCell(
      file: apkFile,
      info: _apkInfoFuture(apkFile),
      selected: _isPathSelected(apkFile.path),
      onSelect: () {
        unawaited(_toggleApkFile(apkFile));
      },
      onInstall: (path) {
        unawaited(_installApk(path));
      },
    );
  }

  Future<android_channel.ApkInfo?> _apkInfoFuture(android_channel.ApkFile file, {bool refresh = false}) {
    final key = '${file.path}\u0000${file.modified}';
    if (refresh) _apkInfoFutures.remove(key);
    return _apkInfoFutures.putIfAbsent(key, () {
      final completer = Completer<android_channel.ApkInfo?>();
      _apkInfoQueue.add(() async {
        try {
          completer.complete(await android_channel.getApkInfoAndroid(path: file.path));
        } on android_channel.AndroidStorageException catch (error) {
          if (error.code == android_channel.AndroidStorageErrorCode.notApk) {
            completer.complete(null);
          } else {
            _logStorageError('get_apk_info', error, StackTrace.current);
            completer.completeError(error);
          }
        } catch (error, stackTrace) {
          _logStorageError('get_apk_info', error, stackTrace);
          completer.completeError(error, stackTrace);
        }
      });
      _runApkInfoQueue();
      return completer.future;
    });
  }

  void _runApkInfoQueue() {
    while (_activeApkInfoLoads < 2 && _apkInfoQueue.isNotEmpty) {
      _activeApkInfoLoads++;
      unawaited(
        _apkInfoQueue.removeFirst()().whenComplete(() {
          _activeApkInfoLoads--;
          _runApkInfoQueue();
        }),
      );
    }
  }

  Future<void> _toggleApkFile(android_channel.ApkFile apkFile) async {
    final file = File(apkFile.path);
    if (!p.isAbsolute(file.path) || !await file.exists()) {
      _showBrowserMessage(BrowserStrings.storageErrorNoFile);
      return;
    }
    await _toggleFile(await CrossFileConverters.convertFile(file));
  }

  Future<void> _installApk(String path) async {
    try {
      await _launchApkInstaller(path);
    } on android_channel.AndroidStorageException catch (error, stackTrace) {
      _logStorageError('install_apk', error, stackTrace);
      if (shouldRequestInstallPermission(error)) {
        await _requestApkInstallPermission(path);
      } else {
        _showBrowserMessage(BrowserStrings.storageError(error.code));
      }
    } catch (error, stackTrace) {
      _logStorageError('install_apk', error, stackTrace);
      _showBrowserMessage(BrowserStrings.installApkFailed);
    }
  }

  Future<void> _launchApkInstaller(String path) async {
    final resume = _waitForResume();
    try {
      await android_channel.installApkAndroid(path: path);
      await resume;
      if (!mounted) return;
      final files = await (_apkFilesFuture ??= _loadApkFiles()).catchError((_) => <android_channel.ApkFile>[]);
      android_channel.ApkFile? apkFile;
      for (final file in files) {
        if (file.path == path) {
          apkFile = file;
          break;
        }
      }
      apkFile ??= android_channel.ApkFile(path: path, name: p.basename(path), size: 0, modified: 0);
      final infoFuture = _apkInfoFuture(apkFile, refresh: true);
      try {
        await infoFuture;
      } catch (_) {
        _showBrowserMessage(BrowserStrings.apkInfoUnavailable);
      }
      if (!mounted) return;
      _reloadCount++;
      unawaited(_refreshInstalledAppsInBackground());
      _refreshStorageStats();
    } catch (_) {
      _cancelResumeWait();
      rethrow;
    }
  }

  Future<void> _requestApkInstallPermission(String path) async {
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(BrowserStrings.allowInstallTitle),
        content: const Text(BrowserStrings.allowInstallMessage),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text(BrowserStrings.notNow)),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text(BrowserStrings.openSettingsAction)),
        ],
      ),
    );
    if (!mounted || openSettings != true) return;

    final resume = _waitForResume();
    try {
      await android_channel.openInstallSettingsAndroid();
      await resume;
      if (!mounted || !await android_channel.canInstallPackagesAndroid()) return;
      await _launchApkInstaller(path);
    } catch (error, stackTrace) {
      _cancelResumeWait();
      _logStorageError('open_apk_install_settings', error, stackTrace);
      _showBrowserMessage(
        error is android_channel.AndroidStorageException ? BrowserStrings.storageError(error.code) : BrowserStrings.installApkFailed,
      );
    }
  }

  Widget _appCell(_InstalledApp app) {
    if (!_loggedFirstAppCell && _category == _BrowserCategory.apps) {
      _loggedFirstAppCell = true;
      final elapsed = _appElapsedMilliseconds();
      if (elapsed != null) _logAppsEvent('apps_first_cell_ms', '$elapsed package=${app.packageName}');
    }
    final selected = _isPathSelected(app.apkFilePath);
    final tokens = BrowserThemeTokens.of(context);
    final deferIcon = Scrollable.recommendDeferredLoadingForContext(context);
    final iconFuture = deferIcon ? null : _appIconFuture(app);
    final nameStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
      height: 1,
    );
    final sizeStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: tokens.textSecondary,
      fontSize: (Theme.of(context).textTheme.labelSmall?.fontSize ?? 11) - 1,
      height: 1,
    );
    return RepaintBoundary(
      child: InkWell(
        key: ValueKey<String>('installed-app-${app.packageName}'),
        borderRadius: BorderRadius.circular(glassRadiusSmall),
        onTap: () => _toggleApp(app),
        child: BrowserSurface(
          blur: false,
          padding: EdgeInsets.zero,
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
                        child: iconFuture == null
                            ? Icon(Icons.android, size: 42, color: tokens.icon)
                            : FutureBuilder<Uint8List?>(
                                future: iconFuture,
                                builder: (context, snapshot) {
                                  final icon = snapshot.data;
                                  if (icon == null) return Icon(Icons.android, size: 42, color: tokens.icon);
                                  return Image.memory(
                                    icon,
                                    fit: BoxFit.contain,
                                    cacheWidth: 96,
                                    cacheHeight: 96,
                                    gaplessPlayback: true,
                                  );
                                },
                              ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 13,
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(app.appName, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: nameStyle),
                    ),
                  ),
                  SizedBox(
                    height: 12,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        app.size?.asReadableFileSize ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sizeStyle,
                      ),
                    ),
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  top: 1,
                  right: 1,
                  child: Icon(Icons.check_circle, size: 18, color: tokens.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSayHelloCard() {
    final tokens = BrowserThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(glassRadiusCard),
        onTap: _composeAndSendMessage,
        child: BrowserSurface(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          borderRadius: BorderRadius.circular(glassRadiusCard),
          child: Row(
            children: [
              Icon(Icons.chat_bubble_outline, color: tokens.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  BrowserStrings.sayHello,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(Icons.send_outlined, color: tokens.primary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilesBrowser({bool textOnly = false}) {
    final folderUri = _currentFolderUri;
    if (folderUri == null) {
      final emptyState = _emptyState(
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
      if (!textOnly) return emptyState;
      return Column(
        children: [
          _buildSayHelloCard(),
          Expanded(child: emptyState),
        ],
      );
    }

    final future = _treeEntriesFuture ??= android_channel.listFolderTreeAndroid(
      uri: folderUri,
    );
    return FutureBuilder<List<android_channel.AndroidBrowseEntry>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return textOnly
              ? Column(
                  children: [
                    _buildSayHelloCard(),
                    const Expanded(child: Center(child: CircularProgressIndicator())),
                  ],
                )
              : const Center(child: CircularProgressIndicator());
        }
        final entries = _sortEntries(
          [...?snapshot.data].where(
            (entry) {
              final name = _displayFileName(displayName: entry.name, uri: entry.uri);
              return (!textOnly || entry.isDirectory || _isTextFile(name)) && _matchesSearch(name);
            },
          ),
        );
        _verifiedSafUris.addAll((snapshot.data ?? []).where((entry) => entry.uri.startsWith('content://')).map((entry) => entry.uri));
        if (snapshot.hasError) {
          final error = _emptyState(
            icon: Icons.folder_off_outlined,
            message: BrowserStrings.couldNotLoadCategoryFiles,
            action: TextButton.icon(
              onPressed: () => setState(
                () => _treeEntriesFuture = android_channel.listFolderTreeAndroid(uri: folderUri),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          );
          if (!textOnly) return error;
          return Column(
            children: [
              _buildSayHelloCard(),
              Expanded(child: error),
            ],
          );
        }
        return Column(
          children: [
            if (textOnly) _buildSayHelloCard(),
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
                        final name = _displayFileName(displayName: entry.name, uri: entry.uri);
                        final file = android_channel.FileInfo(
                          name: name,
                          size: entry.size,
                          uri: entry.uri,
                          lastModified: entry.lastModified,
                        );
                        return _fileRow(
                          selected: entry.isDirectory ? _isPathSelected(entry.uri) : _isSystemFileSelected(file),
                          icon: entry.isDirectory ? Icons.folder_outlined : _fileTypeIcon(name),
                          title: name,
                          subtitle: entry.isDirectory ? BrowserStrings.folder : '${entry.size.asReadableFileSize}${_shortDate(entry.lastModified)}',
                          isText: textOnly && !entry.isDirectory,
                          onTrailingTap: entry.isDirectory ? () => _toggleFolder(entry) : () => _toggleSystemFile(file),
                          onTap: entry.isDirectory
                              ? () => setState(() {
                                  _treeBreadcrumbs.add((name, entry.uri));
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
    _verifiedSafUris.addAll(files.where((file) => file.uri.startsWith('content://')).map((file) => file.uri));
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
            message: BrowserStrings.couldNotLoadCategoryFiles,
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
        final files = _sortFileInfos(
          allFiles
              .where(
                (file) => _category != _BrowserCategory.text || _isTextFile(_displayFileName(displayName: file.name, uri: file.uri)),
              )
              .where((file) => _matchesSearch(_displayFileName(displayName: file.name, uri: file.uri))),
        );
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
            final name = _displayFileName(displayName: file.name, uri: file.uri);
            return _fileRow(
              selected: _isSystemFileSelected(file),
              icon: _fileTypeIcon(name),
              title: name,
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
    if (future == null) return const Center(child: Text(BrowserStrings.noFolderAccessForCategory));
    return FutureBuilder<List<android_channel.FileInfo>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) {
          return _emptyState(
            icon: _category.icon,
            message: BrowserStrings.couldNotLoadCategoryFiles,
            action: TextButton.icon(
              onPressed: () => setState(
                () => _systemFilesFuture = _loadSystemFiles(_category),
              ),
              icon: const Icon(Icons.refresh),
              label: const Text(BrowserStrings.retry),
            ),
          );
        }
        final files = _sortFileInfos(
          [
            ...?snapshot.data,
            ..._additionalSystemFiles,
          ].where((file) => _matchesSearch(_displayFileName(displayName: file.name, uri: file.uri))),
        );
        if (files.isEmpty) {
          return _emptyState(
            icon: _category.icon,
            message: _searchQuery.isNotEmpty
                ? BrowserStrings.noFilesFound
                : _permissionRequired
                ? BrowserStrings.mediaPermissionRequired
                : BrowserStrings.noCategoryFiles,
            action: _permissionRequired
                ? _permissionAction()
                : TextButton.icon(
                    onPressed: _refreshCurrentCategory,
                    icon: const Icon(Icons.refresh),
                    label: const Text(BrowserStrings.checkAccess),
                  ),
          );
        }
        return ListView.builder(
          key: PageStorageKey<String>('browser-${_category.name}'),
          itemCount: files.length + _systemFilesFooterCount,
          itemBuilder: (context, index) {
            if (index >= files.length) return _systemFilesFooter(_category);
            final file = files[index];
            final name = _displayFileName(displayName: file.name, uri: file.uri);
            final isVideo = _category == _BrowserCategory.videos;
            return _fileRow(
              selected: _isSystemFileSelected(file),
              icon: isVideo ? Icons.movie_outlined : Icons.audio_file_outlined,
              title: name,
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
    VoidCallback? onTrailingTap,
    Widget? leading,
    bool isText = false,
  }) {
    final tokens = BrowserThemeTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(isText ? 38 : 6, 3, isText ? 10 : 6, 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(isText ? glassRadiusCard : glassRadiusSmall),
        onTap: onTap,
        child: BrowserSurface(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          borderRadius: BorderRadius.circular(isText ? glassRadiusCard : glassRadiusSmall),
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
                        maxLines: 2,
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
                if (onTrailingTap == null)
                  Icon(
                    selected ? Icons.check_circle : Icons.add_circle_outline,
                    color: selected ? tokens.primary : tokens.icon,
                  )
                else
                  IconButton(
                    tooltip: selected ? BrowserStrings.clearSelection : BrowserStrings.addSelected,
                    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
                    padding: EdgeInsets.zero,
                    onPressed: onTrailingTap,
                    icon: Icon(
                      selected ? Icons.check_circle : Icons.add_circle_outline,
                      color: selected ? tokens.primary : tokens.icon,
                    ),
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

class _AppSectionHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final int count;

  const _AppSectionHeaderDelegate({required this.title, required this.count});

  @override
  double get minExtent => 36;

  @override
  double get maxExtent => 36;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return BrowserSurface(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderRadius: BorderRadius.zero,
      child: Text(
        '$title - $count',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _AppSectionHeaderDelegate oldDelegate) => title != oldDelegate.title || count != oldDelegate.count;
}

class _AlwaysScrollableBrowserBehavior extends MaterialScrollBehavior {
  const _AlwaysScrollableBrowserBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const AlwaysScrollableScrollPhysics();
}
