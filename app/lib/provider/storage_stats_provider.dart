import 'package:flutter/services.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('StorageStatsProvider');

typedef StorageStats = android_channel.StorageStats;

final storageStatsProvider = FutureFamilyProvider<StorageStats, int>((ref, refreshKey) async {
  try {
    return await android_channel.getStorageStatsAndroid();
  } catch (error, stackTrace) {
    if (error is! MissingPluginException) _logger.warning('Could not read storage statistics', error, stackTrace);
    final technicalDetails = error is android_channel.AndroidStorageException
        ? '${error.nativeCode}: ${error.technicalMessage ?? ''} ${error.technicalDetails ?? ''}'.trim()
        : error.toString();
    ref.notifier(pairingControllerProvider).logUiEvent('storage_stats', technicalDetails);
    Error.throwWithStackTrace(error, stackTrace);
  }
}, debugLabel: 'StorageStatsProvider');
