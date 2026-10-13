import 'package:localsend_isolates/model/session_status.dart';

bool isMediaStoreContentUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'content' ||
      uri.host.toLowerCase() != 'media' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }

  final segments = uri.pathSegments;
  if (segments.length < 3 || segments.length > 4 || segments.any((segment) => segment.isEmpty)) {
    return false;
  }
  if (!RegExp(r'^[0-9]+$').hasMatch(segments.last) || int.parse(segments.last) <= 0) return false;

  const mediaCollections = {'images', 'video', 'audio'};
  final isVolumeId =
      const {'external', 'external_primary', 'internal'}.contains(segments[0]) || RegExp(r'^[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}$').hasMatch(segments[0]);
  if (segments.length == 3) {
    final collectionUri = mediaCollections.contains(segments[0]) && segments[1] == 'media';
    final filesUri = isVolumeId && segments[1] == 'file';
    return collectionUri || filesUri;
  }

  return isVolumeId && mediaCollections.contains(segments[1]) && segments[2] == 'media';
}

bool activeTransferContainsPath({
  required String path,
  required Iterable<({SessionStatus status, Iterable<String> paths})> transfers,
}) {
  return transfers.any(
    (transfer) => (transfer.status == SessionStatus.waiting || transfer.status == SessionStatus.sending) && transfer.paths.contains(path),
  );
}
