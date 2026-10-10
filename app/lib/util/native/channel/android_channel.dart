import 'dart:async';
import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

part 'android_channel.mapper.dart';

const _methodChannel = MethodChannel('com.omnidrop.app/localsend');
final _logger = Logger('AndroidSaf');
final _pairingDisconnectEvents = StreamController<String?>.broadcast(sync: true);
bool _pairingDisconnectHandlerInstalled = false;

Stream<String?> get pairingDisconnectEvents {
  if (!_pairingDisconnectHandlerInstalled) {
    _methodChannel.setMethodCallHandler((call) async {
      try {
        if (call.method != 'pairingDisconnected') {
          _logger.warning('Unknown native pairing callback: ${call.method}');
          return;
        }
        _pairingDisconnectEvents.add(call.arguments is String ? call.arguments as String : null);
      } catch (error, stackTrace) {
        _logger.severe('Could not handle native pairing callback', error, stackTrace);
      }
    });
    _pairingDisconnectHandlerInstalled = true;
  }
  return _pairingDisconnectEvents.stream;
}

/// From Android 10 and above, we need to use the Storage Access Framework (SAF) to access files due to the scoped storage.
/// SAF itself is available from Android 4.4 (API level 19).
/// We implemented our own algorithm to build encode and decode content URIs.
/// Older versions might also work but the encoded content URI is not guaranteed to work with our algorithm.
const contentUriMinSdk = 27;

Future<PickDirectoryResult?> pickDirectoryAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('pickDirectory');
  if (result == null) {
    return null;
  }

  return PickDirectoryResultMapper.fromJson({
    'directoryUri': result['directoryUri'],
    'files': (result['files'] as List).map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList(),
  });
}

Future<String?> pickDirectoryPathAndroid() async {
  final result = await _methodChannel.invokeMethod<String>('pickDirectoryPath');
  return result;
}

Future<List<FileInfo>?> pickFilesAndroid() async {
  final result = await _methodChannel.invokeMethod<List>('pickFiles');
  if (result == null) {
    return null;
  }

  return result.map((e) => FileInfoMapper.fromJson((e as Map).cast<String, dynamic>())).toList();
}

Future<List<FileInfo>> queryMediaFilesAndroid({
  required String category,
  int? offset,
  int? limit,
}) async {
  final arguments = <String, Object?>{'category': category};
  if (offset != null) arguments['offset'] = offset;
  if (limit != null) arguments['limit'] = limit;
  final result = await _methodChannel.invokeMethod<List>(
    'queryMediaFiles',
    arguments,
  );
  return (result ?? [])
      .map(
        (file) => FileInfoMapper.fromJson((file as Map).cast<String, dynamic>()),
      )
      .toList();
}

Future<Uint8List?> loadMediaThumbnailAndroid({
  required String uri,
  required String category,
}) => _methodChannel.invokeMethod<Uint8List>('loadMediaThumbnail', {
  'uri': uri,
  'category': category,
});

Future<String?> pickFolderTreeAndroid() => pickStorageTreeAndroid();

Future<String?> pickStorageTreeAndroid({String storage = 'internal'}) => _methodChannel.invokeMethod<String>('pickStorageTree', {
  'storage': storage,
});

Future<String?> getStorageTreeAndroid({String storage = 'internal'}) => _methodChannel.invokeMethod<String>('getStorageTree', {'storage': storage});

Future<String> getSaveLocationAndroid() async => await _methodChannel.invokeMethod<String>('getSaveLocation') ?? 'internal';

Future<bool> hasRemovableStorageAndroid() async => await _methodChannel.invokeMethod<bool>('hasRemovableStorage') ?? false;

Future<bool> setSaveLocationAndroid({required String storage}) async =>
    await _methodChannel.invokeMethod<bool>('setSaveLocation', {
      'storage': storage,
    }) ??
    false;

Future<List<AndroidBrowseEntry>> listFolderTreeAndroid({
  required String uri,
}) async {
  final result = await _methodChannel.invokeMethod<List>('listFolderTree', {
    'uri': uri,
  });
  return (result ?? [])
      .map(
        (entry) => AndroidBrowseEntry.fromMap((entry as Map).cast<String, dynamic>()),
      )
      .toList();
}

Future<List<FileInfo>> listFolderTreeFilesAndroid({required String uri}) async {
  final result = await _methodChannel.invokeMethod<List>(
    'listFolderTreeFiles',
    {'uri': uri},
  );
  return (result ?? [])
      .map(
        (file) => FileInfoMapper.fromJson((file as Map).cast<String, dynamic>()),
      )
      .toList();
}

/// Returns the global "Download" directory, e.g. /storage/emulated/0/Download.
Future<String?> getDownloadsDirectoryAndroid() async {
  try {
    return await _methodChannel.invokeMethod<String>('getDownloadsDirectory');
  } catch (e) {
    _logger.warning('Could not get downloads directory', e);
    return null;
  }
}

Future<bool> getSystemAnimationsStatusAndroid() async {
  return await _methodChannel.invokeMethod('isAnimationsEnabled') ?? true;
}

/// Requests the "Nearby devices" permission gating local network access on Android 17+.
/// Returns true when granted or when running on an older Android version.
Future<bool> requestLocalNetworkPermissionAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>(
          'requestLocalNetworkPermission',
        ) ??
        false;
  } catch (e) {
    _logger.warning('Could not request local network permission', e);
    return false;
  }
}

Future<void> openContentUri({required String uri}) async {
  _logger.info('Opening content URI: $uri');
  await _methodChannel.invokeMethod('openContentUri', {'uri': uri});
}

/// Tells MainActivity that the Dart side is now subscribed to the share_handler media stream,
/// so share intents that were held back during app start can be replayed.
Future<void> flushPendingShareIntentsAndroid() async {
  try {
    await _methodChannel.invokeMethod('shareIntentReady');
  } catch (e) {
    _logger.warning('Could not flush pending share intents', e);
  }
}

Future<void> openGallery() async {
  _logger.info('Opening gallery');
  await _methodChannel.invokeMethod('openGallery');
}

Future<bool> shareInstalledApkAndroid() async {
  try {
    return await _methodChannel.invokeMethod<bool>('shareInstalledApk') ?? false;
  } catch (e) {
    _logger.warning('Could not share installed APK', e);
    return false;
  }
}

Future<void> shareTextInviteAndroid() async {
  await _methodChannel.invokeMethod<void>('shareTextInvite');
}

Future<void> openWifiSettingsAndroid() async {
  await _methodChannel.invokeMethod<void>('openWifiSettings');
}

Future<void> openLocationSettingsAndroid() async {
  await _methodChannel.invokeMethod<void>('openLocationSettings');
}

Future<AndroidLocalOnlyHotspot> startLocalOnlyHotspotAndroid({
  bool prefer5GHz = false,
}) async {
  final result = await _methodChannel.invokeMethod<Map>(
    'startLocalOnlyHotspot',
    {'prefer5GHz': prefer5GHz},
  );
  final ssid = result?['ssid'];
  final password = result?['password'];
  final supports5GHz = result?['supports5GHz'];
  final canRequest5GHz = result?['canRequest5GHz'];
  final hostIp = result?['hostIp'];
  if (ssid is! String ||
      ssid.isEmpty ||
      password is! String ||
      password.isEmpty ||
      supports5GHz is! bool ||
      canRequest5GHz is! bool ||
      hostIp is! String ||
      hostIp.isEmpty) {
    throw const FormatException(
      'Android returned invalid local-only hotspot details.',
    );
  }
  return AndroidLocalOnlyHotspot(
    ssid: ssid,
    password: password,
    supports5GHz: supports5GHz,
    canRequest5GHz: canRequest5GHz,
    hostIp: hostIp,
  );
}

Future<void> stopLocalOnlyHotspotAndroid() async {
  await _methodChannel.invokeMethod<void>('stopLocalOnlyHotspot');
}

Future<void> startPairingKeepAliveAndroid() async {
  await _methodChannel.invokeMethod<void>('startPairingKeepAlive');
}

Future<void> stopPairingKeepAliveAndroid() async {
  await _methodChannel.invokeMethod<void>('stopPairingKeepAlive');
}

Future<AndroidHotspotConnectionResult> connectToWifiHotspotAndroid({
  required String ssid,
  required String password,
}) async {
  final result = await _methodChannel.invokeMethod<Map>(
    'connectToWifiHotspot',
    {'ssid': ssid, 'password': password},
  );
  final code = result?['code'];
  final message = result?['message'];
  if (code is! String || message is! String) {
    throw const FormatException(
      'Android returned an invalid Wi-Fi connection result.',
    );
  }
  return AndroidHotspotConnectionResult(code: code, message: message);
}

Future<void> disconnectFromWifiHotspotAndroid() async {
  await _methodChannel.invokeMethod<void>('disconnectFromWifiHotspot');
}

Future<AndroidWifiEnableResult> enableWifiAndroid() async {
  final result = await _methodChannel.invokeMethod<Map>('enableWifi');
  final success = result?['success'];
  final path = result?['path'];
  final message = result?['message'];
  if (success is! bool || path is! String) {
    throw const FormatException(
      'Android returned an invalid Wi-Fi enable result.',
    );
  }
  return AndroidWifiEnableResult(
    success: success,
    path: path,
    message: message is String ? message : null,
  );
}

Future<bool> is5GHzBandSupportedAndroid() async {
  final supported = await _methodChannel.invokeMethod<bool>(
    'is5GHzBandSupported',
  );
  if (supported == null)
    throw const FormatException(
      'Android did not return Wi-Fi band capability.',
    );
  return supported;
}

Future<bool> canRequest5GHzAndroid() async {
  final canRequest = await _methodChannel.invokeMethod<bool>('canRequest5GHz');
  if (canRequest == null)
    throw const FormatException(
      'Android did not return Wi-Fi band request capability.',
    );
  return canRequest;
}

Future<List<AndroidPairingLogEntry>> getNativePairingLogAndroid() async {
  final entries = await _methodChannel.invokeMethod<List>(
    'getNativePairingLog',
  );
  return (entries ?? []).map((entry) {
    if (entry is! Map || entry['timestamp'] is! int || entry['step'] is! String || entry['message'] is! String) {
      throw const FormatException(
        'Android returned an invalid native pairing log entry.',
      );
    }

    return AndroidPairingLogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(entry['timestamp'] as int),
      step: entry['step'] as String,
      message: entry['message'] as String,
    );
  }).toList();
}

Future<String?> getLastNativeCrashAndroid() => _methodChannel.invokeMethod<String>('getLastNativeCrash');

Future<void> openAppNotificationSettingsAndroid() async {
  await _methodChannel.invokeMethod<void>('openAppNotificationSettings');
}

Future<void> openAppPermissionsSettingsAndroid() async {
  await _methodChannel.invokeMethod<void>('openAppPermissionsSettings');
}

class AndroidLocalOnlyHotspot {
  final String ssid;
  final String password;
  final bool supports5GHz;
  final bool canRequest5GHz;
  final String hostIp;

  const AndroidLocalOnlyHotspot({
    required this.ssid,
    required this.password,
    required this.supports5GHz,
    required this.canRequest5GHz,
    required this.hostIp,
  });
}

class AndroidHotspotConnectionResult {
  final String code;
  final String message;

  const AndroidHotspotConnectionResult({
    required this.code,
    required this.message,
  });

  bool get succeeded => code == 'success';
}

class AndroidWifiEnableResult {
  final bool success;
  final String path;
  final String? message;

  const AndroidWifiEnableResult({
    required this.success,
    required this.path,
    required this.message,
  });
}

class AndroidPairingLogEntry {
  final DateTime timestamp;
  final String step;
  final String message;

  const AndroidPairingLogEntry({
    required this.timestamp,
    required this.step,
    required this.message,
  });
}

@MappableClass()
class PickDirectoryResult with PickDirectoryResultMappable {
  final String directoryUri;
  final List<FileInfo> files;

  PickDirectoryResult({required this.directoryUri, required this.files});
}

@MappableClass()
class FileInfo with FileInfoMappable {
  final String name;
  final int size;
  final String uri;

  /// RFC 3339 in UTC. Null when the document provider does not know it.
  final String? lastModified;

  FileInfo({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
  });
}

class AndroidBrowseEntry {
  final String name;
  final int size;
  final String uri;
  final String? lastModified;
  final bool isDirectory;

  const AndroidBrowseEntry({
    required this.name,
    required this.size,
    required this.uri,
    required this.lastModified,
    required this.isDirectory,
  });

  factory AndroidBrowseEntry.fromMap(Map<String, dynamic> map) => AndroidBrowseEntry(
    name: map['name'] as String? ?? '',
    size: map['size'] as int? ?? 0,
    uri: map['uri'] as String? ?? '',
    lastModified: map['lastModified'] as String?,
    isDirectory: map['isDirectory'] as bool? ?? false,
  );
}
