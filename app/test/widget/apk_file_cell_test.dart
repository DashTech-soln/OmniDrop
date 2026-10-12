import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/browser_surface_style.dart';
import 'package:localsend_app/pages/browser/apk_file_cell.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;

const _channel = MethodChannel('com.omnidrop.app/localsend');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  test('maps APK install states to their pill labels', () {
    expect(apkInstallActionLabel(android_channel.ApkInstallState.notInstalled), BrowserStrings.install);
    expect(apkInstallActionLabel(android_channel.ApkInstallState.update), BrowserStrings.update);
    expect(apkInstallActionLabel(android_channel.ApkInstallState.installed), isNull);
    expect(apkInstallActionLabel(null), isNull);
  });

  testWidgets('APK cell selects on its body tap but the install pill only starts installation', (tester) async {
    var selectionCount = 0;
    final installPaths = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: ApkFileCell(
                key: const ValueKey('apk-cell'),
                file: const android_channel.ApkFile(path: '/files/example.apk', name: 'example.apk', size: 100, modified: 1),
                info: Future.value(
                  const android_channel.ApkInfo(
                    packageName: 'example.app',
                    label: 'Example',
                    versionName: '1.0',
                    versionCode: 1,
                    state: android_channel.ApkInstallState.notInstalled,
                    icon: null,
                  ),
                ),
                selected: false,
                surfaceStyle: BrowserSurfaceStyle.clean,
                onSelect: () => selectionCount++,
                onInstall: installPaths.add,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Example'));
    expect(selectionCount, 1);
    expect(installPaths, isEmpty);

    await tester.tap(find.text(BrowserStrings.install));
    expect(selectionCount, 1);
    expect(installPaths, ['/files/example.apk']);
  });

  test('install errors from a fake channel select a friendly UI action', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      expect(call.method, 'installApk');
      throw PlatformException(code: 'INSTALL_NOT_ALLOWED', message: 'raw platform details');
    });

    try {
      await android_channel.installApkAndroid(path: '/files/example.apk');
      fail('Expected an install permission error.');
    } on android_channel.AndroidStorageException catch (error) {
      expect(shouldRequestInstallPermission(error), isTrue);
      expect(BrowserStrings.storageError(error.code), BrowserStrings.allowInstallMessage);
      expect(BrowserStrings.storageError(error.code), isNot(contains('raw platform details')));
    }
  });

  test('shareability errors from a fake channel use a friendly message, not platform text', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'FILE_NOT_SHAREABLE', message: 'raw provider details');
    });

    try {
      await android_channel.installApkAndroid(path: '/saf/example.apk');
      fail('Expected an APK shareability error.');
    } on android_channel.AndroidStorageException catch (error) {
      expect(shouldRequestInstallPermission(error), isFalse);
      expect(BrowserStrings.storageError(error.code), BrowserStrings.installFileLocationNotShareable);
      expect(BrowserStrings.storageError(error.code), isNot(contains('raw provider details')));
    }
  });
}
