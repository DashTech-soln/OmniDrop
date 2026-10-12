import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;

const _channel = MethodChannel('com.omnidrop.app/localsend');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test('parses storage statistics and clamps unclassified storage at zero', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'getStorageStats');
      return {'total': 1000, 'free': 100, 'photos': 400, 'videos': 300, 'audio': 200, 'docs': 100};
    });

    final stats = await android_channel.getStorageStatsAndroid();

    expect(stats.total, 1000);
    expect(stats.free, 100);
    expect(stats.photos, 400);
    expect(stats.others, 0);
  });

  test('parses delete results including user cancellation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'deleteFiles');
      expect((call.arguments as Map)['paths'], ['/storage/emulated/0/a.txt']);
      return {
        'deleted': <String>[],
        'failed': <String>[],
        'cancelled': true,
      };
    });

    final result = await android_channel.deleteFilesAndroid(paths: ['/storage/emulated/0/a.txt']);

    expect(result.deleted, isEmpty);
    expect(result.failed, isEmpty);
    expect(result.cancelled, isTrue);
  });

  test('maps native error codes to safe friendly messages', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'SYSTEM_APP', message: 'raw native diagnostic');
    });

    await expectLater(
      android_channel.uninstallAppAndroid(packageName: 'example.system'),
      throwsA(
        isA<android_channel.AndroidStorageException>()
            .having((error) => error.code, 'code', android_channel.AndroidStorageErrorCode.systemApp)
            .having((error) => error.technicalMessage, 'technical message', 'raw native diagnostic'),
      ),
    );
    expect(BrowserStrings.storageError(android_channel.AndroidStorageErrorCode.systemApp), BrowserStrings.storageErrorSystemApp);
  });

  test('parses APK information with and without an icon', () async {
    final icon = Uint8List.fromList([1, 2, 3]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'getApkInfo');
      if ((call.arguments as Map)['path'] == '/first.apk') {
        return {
          'package': 'example.first',
          'label': 'First',
          'versionName': '1.0',
          'versionCode': 1,
          'state': 'not_installed',
          'icon': icon,
        };
      }
      return {
        'package': 'example.second',
        'label': 'Second',
        'versionName': '2.0',
        'versionCode': 2,
        'state': 'installed',
      };
    });

    final withIcon = await android_channel.getApkInfoAndroid(path: '/first.apk');
    final withoutIcon = await android_channel.getApkInfoAndroid(path: '/second.apk');

    expect(withIcon.icon, icon);
    expect(withIcon.state, android_channel.ApkInstallState.notInstalled);
    expect(withoutIcon.icon, isNull);
    expect(withoutIcon.state, android_channel.ApkInstallState.installed);
  });
}
