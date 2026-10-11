import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('StorageStatsProvider');

class StorageStats {
  final int total;
  final int free;
  final int photos;
  final int videos;
  final int audio;
  final int docs;
  final int others;

  const StorageStats({
    required this.total,
    required this.free,
    required this.photos,
    required this.videos,
    required this.audio,
    required this.docs,
    required this.others,
  });
}

final storageStatsProvider = FutureFamilyProvider<StorageStats, int>((ref, refreshKey) async {
  try {
    final values = await android_channel.getStorageStatsAndroid();
    final total = values['total']!;
    final free = values['free']!;
    final photos = values['photos']!;
    final videos = values['videos']!;
    final audio = values['audio']!;
    final docs = values['docs']!;
    final used = total - free;
    final categorized = photos + videos + audio + docs;
    if (categorized > used) {
      throw FormatException('Storage categories ($categorized) exceed used storage ($used).');
    }
    return StorageStats(
      total: total,
      free: free,
      photos: photos,
      videos: videos,
      audio: audio,
      docs: docs,
      others: used - categorized,
    );
  } catch (error, stackTrace) {
    if (error is! MissingPluginException) _logger.warning('Could not read storage statistics', error, stackTrace);
    Error.throwWithStackTrace(error, stackTrace);
  }
}, debugLabel: 'StorageStatsProvider');
