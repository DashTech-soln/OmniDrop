import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/pages/browser/browser_delete_helpers.dart';
import 'package:localsend_app/pages/browser/browser_strings.dart';
import 'package:localsend_isolates/model/session_status.dart';

void main() {
  test('formats the required deletion and uninstall confirmations', () {
    expect(BrowserStrings.deleteFilesConfirmation(3, '1.2 MB'), 'Are you sure you want to delete 3 files (1.2 MB)? This cannot be undone.');
    expect(
      BrowserStrings.deleteFolderConfirmation('Photos'),
      'Are you sure you want to delete the folder "Photos" and everything inside it? This cannot be undone.',
    );
    expect(BrowserStrings.uninstallAppsConfirmation(2), 'Are you sure you want to uninstall 2 apps?');
  });

  group('isMediaStoreContentUri', () {
    test('accepts known MediaStore file and media collection URIs', () {
      expect(isMediaStoreContentUri('content://media/external/file/42'), isTrue);
      expect(isMediaStoreContentUri('content://media/external_primary/video/media/7'), isTrue);
      expect(isMediaStoreContentUri('content://media/audio/media/9'), isTrue);
    });

    test('rejects URIs outside MediaStore or without a numeric item id', () {
      expect(isMediaStoreContentUri('content://com.example.provider/document/42'), isFalse);
      expect(isMediaStoreContentUri('content://media/external/file/not-an-id'), isFalse);
      expect(isMediaStoreContentUri('content://media/untrusted/file/42'), isFalse);
      expect(isMediaStoreContentUri('content://media/external/file/42?query=1'), isFalse);
      expect(isMediaStoreContentUri('/storage/emulated/0/file.txt'), isFalse);
    });
  });

  group('activeTransferContainsPath', () {
    test('blocks a matching file in a waiting or sending session', () {
      for (final status in [SessionStatus.waiting, SessionStatus.sending]) {
        expect(
          activeTransferContainsPath(
            path: '/storage/emulated/0/file.txt',
            transfers: [
              (status: status, paths: ['/storage/emulated/0/file.txt']),
            ],
          ),
          isTrue,
        );
      }
    });

    test('does not block unrelated or completed transfers', () {
      expect(
        activeTransferContainsPath(
          path: '/storage/emulated/0/file.txt',
          transfers: [
            (status: SessionStatus.sending, paths: ['/storage/emulated/0/other.txt']),
            (status: SessionStatus.finished, paths: ['/storage/emulated/0/file.txt']),
          ],
        ),
        isFalse,
      );
    });
  });
}
