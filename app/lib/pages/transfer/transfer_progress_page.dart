import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/transfer/transfer_dock_visibility.dart';
import 'package:localsend_app/pages/transfer/transfer_gauge.dart';
import 'package:localsend_app/pages/transfer/transfer_strings.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:localsend_app/widget/custom_progress_bar.dart';
import 'package:localsend_app/widget/dialogs/error_dialog.dart';
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

class TransferProgressPage extends StatefulWidget {
  const TransferProgressPage({super.key});

  @override
  State<TransferProgressPage> createState() => _TransferProgressPageState();
}

class _TransferProgressPageState extends State<TransferProgressPage> with Refena {
  static const _refreshInterval = Duration(milliseconds: 100);
  final ValueNotifier<_TransferSnapshot> _snapshot = ValueNotifier(
    const _TransferSnapshot.empty(),
  );
  Timer? _timer;
  DateTime? _lastTaskbarProgressUpdate;
  SessionStatus? _lastTaskbarStatus;
  bool _wakelockEnabled = false;

  @override
  void initState() {
    super.initState();
    showTransferProgressPage();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshSnapshot();
      _timer = Timer.periodic(_refreshInterval, (_) => _refreshSnapshot());
    });
  }

  void _refreshSnapshot() {
    final sendSessions = ref.read(sendProvider);
    final receiveSession = ref.read(serverProvider)?.session;
    final transferState = ref.read(fileTransferProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessions = <_TransferSessionSnapshot>[
      for (final session in sendSessions.values) _fromSendSession(session, transferState),
      if (receiveSession != null) _fromReceiveSession(receiveSession, transferState),
    ];
    if (sessions.isEmpty && _snapshot.value.sessions.isNotEmpty) {
      final previous = _snapshot.value;
      if (!previous.isTerminal) {
        final completed = previous.sessions.every(
          (session) =>
              session.status == SessionStatus.finished ||
              (session.files.any(
                    (file) => file.status == FileStatus.finished,
                  ) &&
                  session.files.every(
                    (file) => file.status == FileStatus.finished || file.status == FileStatus.skipped,
                  )),
        );
        _snapshot.value = previous.closed(completed: completed);
      }
      _updateNativeFeedback(_snapshot.value);
      return;
    }
    _snapshot.value = _TransferSnapshot.fromSessions(sessions, now);
    _updateNativeFeedback(_snapshot.value);
  }

  void _updateNativeFeedback(_TransferSnapshot snapshot) {
    final active = snapshot.sessions.any(
      (session) => session.status == SessionStatus.sending,
    );
    if (checkPlatformIsNot([TargetPlatform.android]) && active != _wakelockEnabled) {
      _wakelockEnabled = active;
      unawaited(active ? WakelockPlus.enable() : WakelockPlus.disable());
    }

    final status = active
        ? SessionStatus.sending
        : snapshot.sessions
                  .firstWhereOrNull(
                    (session) => session.status != SessionStatus.finished,
                  )
                  ?.status ??
              snapshot.sessions.firstOrNull?.status;
    if (status != null && status != _lastTaskbarStatus) {
      _lastTaskbarStatus = status;
      unawaited(TaskbarHelper.visualizeStatus(status));
    }

    if (active) {
      final now = DateTime.now();
      if (_lastTaskbarProgressUpdate == null || now.difference(_lastTaskbarProgressUpdate!) >= const Duration(seconds: 1)) {
        _lastTaskbarProgressUpdate = now;
        unawaited(
          snapshot.total > 0
              ? TaskbarHelper.setProgressBar(
                  snapshot.transferred,
                  snapshot.total,
                )
              : TaskbarHelper.setProgressBar(0, double.maxFinite.toInt()),
        );
      }
    }
  }

  _TransferSessionSnapshot _fromSendSession(
    SendSessionState session,
    FileTransferNotifier transferState,
  ) {
    final files = <_TransferFileSnapshot>[
      for (final sendingFile in session.files.values)
        _TransferFileSnapshot(
          file: sendingFile.file,
          status: transferState.getStatus(
            sessionId: session.sessionId,
            fileId: sendingFile.file.id,
          ),
          progress: transferState.getProgress(
            sessionId: session.sessionId,
            fileId: sendingFile.file.id,
          ),
          errorMessage: sendingFile.errorMessage,
          sendingFile: sendingFile,
          receivingFile: null,
          path: sendingFile.path,
          thumbnail: sendingFile.thumbnail,
          asset: sendingFile.asset,
          savedToGallery: false,
        ),
    ];
    return _TransferSessionSnapshot(
      sessionId: session.sessionId,
      deviceName: session.target.alias,
      status: session.status,
      startTime: session.startTime,
      endTime: session.endTime,
      errorMessage: session.errorMessage,
      files: files,
      receiving: false,
    );
  }

  _TransferSessionSnapshot _fromReceiveSession(
    ReceiveSessionState session,
    FileTransferNotifier transferState,
  ) {
    final files = <_TransferFileSnapshot>[
      for (final receivingFile in session.files.values)
        _TransferFileSnapshot(
          file: receivingFile.file,
          status: transferState.getStatus(
            sessionId: session.sessionId,
            fileId: receivingFile.file.id,
          ),
          progress: transferState.getProgress(
            sessionId: session.sessionId,
            fileId: receivingFile.file.id,
          ),
          errorMessage: receivingFile.errorMessage,
          sendingFile: null,
          receivingFile: receivingFile,
          path: receivingFile.path,
          thumbnail: null,
          asset: null,
          savedToGallery: receivingFile.savedToGallery,
        ),
    ];
    return _TransferSessionSnapshot(
      sessionId: session.sessionId,
      deviceName: session.senderAlias,
      status: session.status,
      startTime: session.startTime,
      endTime: session.endTime,
      errorMessage: null,
      files: files,
      receiving: true,
    );
  }

  void _minimize() {
    for (final session in ref.read(sendProvider).values) {
      ref.notifier(sendProvider).setBackground(session.sessionId, true);
    }
    unawaited(Navigator.of(context).maybePop());
  }

  Future<void> _cancelTransfer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(TransferStrings.cancelTransfer),
        content: const Text(TransferStrings.cancelConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(TransferStrings.keepTransfer),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(TransferStrings.cancel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    for (final session in ref.read(sendProvider).values.toList()) {
      ref.notifier(sendProvider).cancelSession(session.sessionId);
    }
    if (ref.read(serverProvider)?.session != null) {
      ref.notifier(serverProvider).cancelSession();
    }
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  void _closeCompleted() {
    for (final session in ref.read(sendProvider).values.toList()) {
      ref.notifier(sendProvider).closeSession(session.sessionId);
    }
    if (ref.read(serverProvider)?.session != null) {
      ref.notifier(serverProvider).closeSession();
    }
    if (mounted) unawaited(Navigator.of(context).maybePop());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _snapshot.dispose();
    hideTransferProgressPage();
    unawaited(TaskbarHelper.clearProgressBar());
    if (_wakelockEnabled) {
      _wakelockEnabled = false;
      unawaited(WakelockPlus.disable());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          for (final session in ref.read(sendProvider).values) {
            ref.notifier(sendProvider).setBackground(session.sessionId, true);
          }
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final headerHeight = math.min(constraints.maxHeight / 3, 250.0);
              return Column(
                children: [
                  SizedBox(
                    height: headerHeight,
                    child: Column(
                      children: [
                        ValueListenableBuilder(
                          valueListenable: _snapshot,
                          builder: (context, snapshot, _) {
                            final sending = snapshot.sessions.any(
                              (session) => !session.receiving,
                            );
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      sending ? TransferStrings.sending : TransferStrings.receiving,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                  ),
                                  if (!snapshot.isTerminal)
                                    TextButton.icon(
                                      onPressed: _minimize,
                                      icon: const Icon(
                                        Icons.keyboard_arrow_down,
                                      ),
                                      label: const Text(
                                        TransferStrings.minimize,
                                      ),
                                    )
                                  else
                                    TextButton.icon(
                                      onPressed: _closeCompleted,
                                      icon: const Icon(Icons.close),
                                      label: const Text(TransferStrings.close),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, headerConstraints) {
                              final gaugeSize = math.min(
                                150.0,
                                math.min(
                                  headerConstraints.maxHeight,
                                  headerConstraints.maxWidth * 0.44,
                                ),
                              );
                              return ValueListenableBuilder(
                                valueListenable: _snapshot,
                                builder: (context, snapshot, _) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _CompactStatColumn(
                                          stats: [
                                            (
                                              TransferStrings.percentage,
                                              '${(snapshot.progress * 100).round()}%',
                                            ),
                                            (
                                              TransferStrings.total,
                                              snapshot.total.asReadableFileSize,
                                            ),
                                            (
                                              TransferStrings.filesRemaining,
                                              '${snapshot.filesRemaining}',
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      TransferGauge(
                                        size: gaugeSize,
                                        progress: snapshot.progress,
                                        elapsed: snapshot.elapsed,
                                        activeFile: snapshot.activeFile,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: _CompactStatColumn(
                                          stats: [
                                            (
                                              TransferStrings.transferred,
                                              snapshot.transferred.asReadableFileSize,
                                            ),
                                            (
                                              TransferStrings.speed,
                                              snapshot.speed == 0 ? TransferStrings.unavailable : '${snapshot.speed.asReadableFileSize}/s',
                                            ),
                                            (
                                              TransferStrings.estimatedTime,
                                              snapshot.eta,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ValueListenableBuilder(
                    valueListenable: _snapshot,
                    builder: (context, snapshot, _) => _DevicePill(sessions: snapshot.sessions),
                  ),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: _snapshot,
                      builder: (context, snapshot, _) => ListView(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                        children: [
                          if (snapshot.isTerminal)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: Text(
                                  snapshot.statusMessage,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                          if (snapshot.errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: SelectableText(
                                snapshot.errorMessage!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.warning,
                                ),
                              ),
                            ),
                          if (ref.read(pairingControllerProvider).multiRecipient &&
                              snapshot.sessions.any(
                                (session) => !session.receiving,
                              ))
                            _RecipientList(sessions: snapshot.sessions),
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 4),
                            child: Text(
                              TransferStrings.transferProgress,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          for (final entry in snapshot.fileEntries)
                            _TransferFileTile(
                              entry: entry.file,
                              onRetry: entry.file.status == FileStatus.failed && entry.file.sendingFile != null
                                  ? () => ref
                                        .notifier(sendProvider)
                                        .sendFile(
                                          sessionId: entry.session.sessionId,
                                          file: entry.file.sendingFile!,
                                          isRetry: true,
                                        )
                                  : null,
                            ),
                          if (!snapshot.isTerminal)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: OutlinedButton.icon(
                                onPressed: _cancelTransfer,
                                icon: const Icon(Icons.cancel_outlined),
                                label: const Text(
                                  TransferStrings.cancelTransfer,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CompactStatColumn extends StatelessWidget {
  final List<(String, String)> stats;

  const _CompactStatColumn({required this.stats});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < stats.length; index++) ...[
          Expanded(
            child: _CompactStat(
              label: stats[index].$1,
              value: stats[index].$2,
            ),
          ),
          if (index != stats.length - 1) const SizedBox(height: 4),
        ],
      ],
    );
  }
}

class _DevicePill extends StatelessWidget {
  final List<_TransferSessionSnapshot> sessions;

  const _DevicePill({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final names = sessions.map((session) => session.deviceName).where((name) => name.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.devices, size: 17),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${TransferStrings.device}: ${names.isEmpty ? TransferStrings.unavailable : names.join(', ')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  final String label;
  final String value;

  const _CompactStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(glassRadiusCard),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontSize: 9),
            ),
            Text(
              value.isEmpty ? TransferStrings.unavailable : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipientList extends StatelessWidget {
  final List<_TransferSessionSnapshot> sessions;

  const _RecipientList({required this.sessions});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Text(
          TransferStrings.devices,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        for (final session in sessions)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer,
                  child: Text(
                    session.deviceName.isEmpty ? '?' : session.deviceName.characters.first.toUpperCase(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        session.statusLabel,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text('${(session.progress * 100).round()}%'),
              ],
            ),
          ),
      ],
    );
  }
}

class _TransferFileTile extends StatelessWidget {
  final _TransferFileSnapshot entry;
  final VoidCallback? onRetry;

  const _TransferFileTile({required this.entry, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (entry.status) {
      FileStatus.queue => TransferStrings.queued,
      FileStatus.skipped => TransferStrings.skipped,
      FileStatus.sending => TransferStrings.active,
      FileStatus.failed => TransferStrings.failed,
      FileStatus.finished => entry.savedToGallery ? TransferStrings.savedToGallery : TransferStrings.finished,
    };
    final color = switch (entry.status) {
      FileStatus.failed => Theme.of(context).colorScheme.warning,
      FileStatus.finished => Theme.of(context).colorScheme.tertiary,
      FileStatus.sending => Theme.of(context).colorScheme.primary,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final fileName = entry.receivingFile?.desiredName ?? entry.file.fileName;
    final Uint8List? thumbnail = entry.thumbnail;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SmartFileThumbnail(
            bytes: thumbnail,
            asset: entry.asset,
            path: entry.path,
            fileType: entry.file.fileType,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                if (entry.status == FileStatus.sending)
                  CustomProgressBar(progress: entry.progress)
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          statusLabel,
                          style: TextStyle(color: color),
                        ),
                      ),
                      if (entry.errorMessage != null)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: TransferStrings.failed,
                          onPressed: () async {
                            await showDialog<void>(
                              context: context,
                              builder: (_) => ErrorDialog(error: entry.errorMessage!),
                            );
                          },
                          icon: Icon(
                            Icons.info_outline,
                            color: color,
                            size: 19,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (entry.path != null && entry.receivingFile != null && entry.status == FileStatus.finished && !entry.savedToGallery)
            IconButton(
              tooltip: TransferStrings.openFile,
              onPressed: () => openFile(context, entry.file.fileType, entry.path!),
              icon: const Icon(Icons.open_in_new),
            ),
          if (onRetry != null)
            IconButton(
              tooltip: TransferStrings.retry,
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
    );
  }
}

class _TransferSnapshot {
  final List<_TransferSessionSnapshot> sessions;
  final int transferred;
  final int total;
  final int speed;
  final int filesRemaining;
  final double progress;
  final String elapsed;
  final String eta;
  final String activeFile;
  final String? errorMessage;
  final bool isTerminal;
  final String statusMessage;
  final List<String> deviceNames;
  final List<_TransferFileEntry> fileEntries;

  const _TransferSnapshot({
    required this.sessions,
    required this.transferred,
    required this.total,
    required this.speed,
    required this.filesRemaining,
    required this.progress,
    required this.elapsed,
    required this.eta,
    required this.activeFile,
    required this.errorMessage,
    required this.isTerminal,
    required this.statusMessage,
    required this.deviceNames,
    required this.fileEntries,
  });

  const _TransferSnapshot.empty()
    : sessions = const [],
      transferred = 0,
      total = 0,
      speed = 0,
      filesRemaining = 0,
      progress = 0,
      elapsed = '00:00:00',
      eta = TransferStrings.unavailable,
      activeFile = TransferStrings.noActiveFile,
      errorMessage = null,
      isTerminal = false,
      statusMessage = TransferStrings.waiting,
      deviceNames = const [],
      fileEntries = const [];

  factory _TransferSnapshot.fromSessions(
    List<_TransferSessionSnapshot> sessions,
    int now,
  ) {
    final transferred = sessions.fold<int>(
      0,
      (sum, session) => sum + session.transferred,
    );
    final total = sessions.fold<int>(0, (sum, session) => sum + session.total);
    final statuses = sessions.map((session) => session.status).toList();
    final terminal =
        sessions.isNotEmpty &&
        statuses.every(
          (status) => const {
            SessionStatus.finished,
            SessionStatus.finishedWithErrors,
            SessionStatus.canceledBySender,
            SessionStatus.canceledByReceiver,
            SessionStatus.declined,
            SessionStatus.recipientBusy,
            SessionStatus.tooManyAttempts,
          }.contains(status),
        );
    final startTimes = sessions.map((session) => session.startTime).whereType<int>().toList();
    final startTime = startTimes.isEmpty ? now : startTimes.reduce((a, b) => a < b ? a : b);
    final endTimes = sessions.map((session) => session.endTime).whereType<int>().toList();
    final endTime = terminal && endTimes.isNotEmpty ? endTimes.reduce((a, b) => a > b ? a : b) : now;
    final elapsedMs = math.max(0, endTime - startTime).toInt();
    final speed = elapsedMs == 0 ? 0 : (transferred * 1000 / elapsedMs).round();
    final remaining = math.max(0, total - transferred).toInt();
    final remainingSeconds = speed == 0 ? null : (remaining / speed).ceil();
    final failed =
        statuses.contains(SessionStatus.finishedWithErrors) ||
        statuses.contains(SessionStatus.tooManyAttempts) ||
        sessions.any(
          (session) => session.files.any((file) => file.status == FileStatus.failed),
        );
    final cancelled = statuses.contains(SessionStatus.canceledBySender) || statuses.contains(SessionStatus.canceledByReceiver);
    final errorMessage = sessions.map((session) => session.errorMessage).whereType<String>().firstOrNull;
    final activeFile =
        sessions.expand((session) => session.files).where((file) => file.status == FileStatus.sending).firstOrNull?.file.fileName ??
        sessions.expand((session) => session.files).where((file) => file.status == FileStatus.queue).firstOrNull?.file.fileName ??
        TransferStrings.noActiveFile;
    final statusMessage = cancelled
        ? statuses.contains(SessionStatus.canceledBySender)
              ? TransferStrings.cancelledBySender
              : TransferStrings.cancelledByReceiver
        : statuses.contains(SessionStatus.declined)
        ? TransferStrings.declined
        : statuses.contains(SessionStatus.recipientBusy)
        ? TransferStrings.recipientBusy
        : statuses.contains(SessionStatus.tooManyAttempts)
        ? TransferStrings.tooManyAttempts
        : failed
        ? errorMessage ??
              sessions.expand((session) => session.files).map((file) => file.errorMessage).whereType<String>().firstOrNull ??
              TransferStrings.someFilesFailed
        : terminal
        ? TransferStrings.saveComplete
        : statuses.contains(SessionStatus.waiting)
        ? TransferStrings.waiting
        : '';

    return _TransferSnapshot(
      sessions: sessions,
      transferred: transferred,
      total: total,
      speed: speed,
      filesRemaining: sessions.fold<int>(
        0,
        (sum, session) => sum + session.filesRemaining,
      ),
      progress: total == 0 ? (terminal && !failed && !cancelled ? 1 : 0) : (transferred / total).clamp(0.0, 1.0),
      elapsed: _formatDuration(Duration(milliseconds: elapsedMs)),
      eta: remainingSeconds == null ? TransferStrings.unavailable : _formatDuration(Duration(seconds: remainingSeconds)),
      activeFile: activeFile,
      errorMessage: errorMessage,
      isTerminal: terminal,
      statusMessage: statusMessage,
      deviceNames: sessions.map((session) => session.deviceName).toList(),
      fileEntries: [
        for (final session in sessions)
          for (final file in session.files) _TransferFileEntry(session: session, file: file),
      ],
    );
  }

  _TransferSnapshot closed({required bool completed}) {
    return _TransferSnapshot(
      sessions: completed ? sessions.map((session) => session.withStatus(SessionStatus.finished)).toList() : sessions,
      transferred: completed ? total : transferred,
      total: total,
      speed: speed,
      filesRemaining: completed ? 0 : filesRemaining,
      progress: completed ? 1 : progress,
      elapsed: elapsed,
      eta: TransferStrings.unavailable,
      activeFile: activeFile,
      errorMessage: errorMessage,
      isTerminal: true,
      statusMessage: completed ? TransferStrings.saveComplete : TransferStrings.sessionClosed,
      deviceNames: deviceNames,
      fileEntries: fileEntries,
    );
  }
}

class _TransferSessionSnapshot {
  final String sessionId;
  final String deviceName;
  final SessionStatus status;
  final int? startTime;
  final int? endTime;
  final String? errorMessage;
  final List<_TransferFileSnapshot> files;
  final bool receiving;

  const _TransferSessionSnapshot({
    required this.sessionId,
    required this.deviceName,
    required this.status,
    required this.startTime,
    required this.endTime,
    required this.errorMessage,
    required this.files,
    required this.receiving,
  });

  int get transferred => files.fold<int>(
    0,
    (sum, file) => sum + (file.status == FileStatus.skipped ? 0 : (file.progress * file.file.size).round()),
  );

  int get total => files.fold<int>(
    0,
    (sum, file) => sum + (file.status == FileStatus.skipped ? 0 : file.file.size),
  );

  int get filesRemaining => files
      .where(
        (file) => file.status == FileStatus.queue || file.status == FileStatus.sending,
      )
      .length;

  double get progress => total == 0 ? 0 : (transferred / total).clamp(0.0, 1.0);

  String get statusLabel => switch (status) {
    SessionStatus.waiting => TransferStrings.waiting,
    SessionStatus.sending => TransferStrings.active,
    SessionStatus.finished => TransferStrings.finished,
    SessionStatus.finishedWithErrors => TransferStrings.failed,
    SessionStatus.canceledBySender => TransferStrings.cancelledBySender,
    SessionStatus.canceledByReceiver => TransferStrings.cancelledByReceiver,
    SessionStatus.declined => TransferStrings.declined,
    SessionStatus.recipientBusy => TransferStrings.recipientBusy,
    SessionStatus.tooManyAttempts => TransferStrings.tooManyAttempts,
  };

  _TransferSessionSnapshot withStatus(SessionStatus nextStatus) {
    return _TransferSessionSnapshot(
      sessionId: sessionId,
      deviceName: deviceName,
      status: nextStatus,
      startTime: startTime,
      endTime: endTime,
      errorMessage: errorMessage,
      files: files,
      receiving: receiving,
    );
  }
}

class _TransferFileSnapshot {
  final FileDto file;
  final FileStatus status;
  final double progress;
  final String? errorMessage;
  final SendingFile? sendingFile;
  final ReceivingFile? receivingFile;
  final String? path;
  final Uint8List? thumbnail;
  final AssetEntity? asset;
  final bool savedToGallery;

  const _TransferFileSnapshot({
    required this.file,
    required this.status,
    required this.progress,
    required this.errorMessage,
    required this.sendingFile,
    required this.receivingFile,
    required this.path,
    required this.thumbnail,
    required this.asset,
    required this.savedToGallery,
  });
}

class _TransferFileEntry {
  final _TransferSessionSnapshot session;
  final _TransferFileSnapshot file;

  const _TransferFileEntry({required this.session, required this.file});
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
