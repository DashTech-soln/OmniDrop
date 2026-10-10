import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/pages/pairing/pairing_controller_page.dart';
import 'package:localsend_app/pages/pairing/pairing_strings.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/qr_payload_parser.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/glass/glass_card.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/rust/api/pairing.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const _avatarIcons = [Icons.person, Icons.face, Icons.account_circle, Icons.pets, Icons.rocket_launch, Icons.bolt];
const _pairingLifetime = Duration(minutes: 5);

class PairingPage extends StatelessWidget {
  const PairingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const ControllerPairingPage();
  }
}

class _SenderSessionTab extends StatefulWidget {
  final bool discoverable;

  const _SenderSessionTab({required this.discoverable});

  @override
  State<_SenderSessionTab> createState() => _SenderSessionTabState();
}

class _SenderSessionTabState extends State<_SenderSessionTab> with Refena {
  final Map<String, PairingDeviceInfo> _joined = {};
  final Set<String> _removed = {};
  final Set<String> _selected = {};
  StreamSubscription<HttpServerEvent>? _pairingActionSubscription;
  StreamSubscription<HttpServerPairingEvent>? _pairingSubscription;
  StreamSubscription<void>? _pairingDisconnectSubscription;
  Timer? _countdownTimer;
  android_channel.AndroidLocalOnlyHotspot? _hotspot;
  String? _sessionToken;
  DateTime? _expiresAt;
  String? _qrData;
  String? _error;
  bool _starting = false;
  bool _sending = false;
  int _remainingSeconds = 300;

  @override
  void initState() {
    super.initState();
    _listenForNativeDisconnect();
    if (!widget.discoverable) unawaited(_startSession());
  }

  void _listenForNativeDisconnect() {
    if (widget.discoverable || _pairingDisconnectSubscription != null) return;
    _pairingDisconnectSubscription = android_channel.pairingDisconnectEvents.listen((_) {
      unawaited(_stopSession(stopHotspot: false));
    });
  }

  Future<void> _startSession() async {
    if (_starting || _sessionToken != null) return;
    _listenForNativeDisconnect();
    setState(() {
      _starting = true;
      _error = null;
    });

    try {
      if (!widget.discoverable) {
        if (!checkPlatform([TargetPlatform.android])) throw StateError(PairingStrings.hotspotUnavailable);
        _hotspot = await android_channel.startLocalOnlyHotspotAndroid();
      }

      if (ref.read(serverProvider) == null) {
        await ref.notifier(serverProvider).startServerFromSettings();
      }
      final localDevice = ref.read(deviceFullInfoProvider);
      final hostIp = _hotspot?.hostIp ?? ref.read(localIpProvider).localIps.firstOrNull;
      if (hostIp == null || hostIp.isEmpty || localDevice.port < 1) throw StateError(PairingStrings.noHostAddress);

      final sender = PairingDeviceInfo(
        fingerprint: localDevice.fingerprint,
        alias: localDevice.alias,
        version: localDevice.version,
        deviceModel: localDevice.deviceModel,
        deviceType: localDevice.deviceType.toRust(),
        ip: hostIp,
        port: localDevice.port,
        protocol: localDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        hasWebInterface: localDevice.download,
      );
      final avatarIndex = ref.read(persistenceProvider).getProfileAvatar() % _avatarIcons.length;
      final createStream = ref
          .redux(parentIsolateProvider)
          .dispatchTakeResult(
            IsolateHttpServerPairingAction(
              task: HttpServerPairingTask(
                operation: HttpServerPairingOperation.create,
                sender: sender,
                discoverable: widget.discoverable,
                avatarIndex: avatarIndex,
              ),
            ),
          );
      final created =
          (await createStream.firstWhere((event) => event is HttpServerPairingEvent && event.sessionToken != null)) as HttpServerPairingEvent;
      final token = created.sessionToken!;
      final expiry = DateTime.now().add(_pairingLifetime);
      _sessionToken = token;
      _expiresAt = expiry;
      if (!widget.discoverable) {
        _qrData = Uri(
          scheme: 'omnidrop',
          host: 'pair',
          queryParameters: {
            'alias': localDevice.alias,
            'ssid': _hotspot!.ssid,
            'password': _hotspot!.password,
            'ip': hostIp,
            'port': localDevice.port.toString(),
            'https': localDevice.https.toString(),
            'fp': localDevice.fingerprint,
            'token': token,
            'exp': expiry.millisecondsSinceEpoch.toString(),
          },
        ).toString();
      }

      final serverService = ref.notifier(serverProvider);
      _pairingSubscription = serverService.pairingEvents.where((event) => event.sessionToken == token).listen((event) {
        if (!mounted || event.event == null) return;
        final pairingEvent = event.event!;
        if (pairingEvent is RsPairingEvent_DeviceJoined) {
          setState(() {
            final device = pairingEvent.device.device;
            _joined[device.fingerprint] = device;
            _selected.add(device.fingerprint);
          });
        }
      });
      _pairingActionSubscription = ref
          .redux(parentIsolateProvider)
          .dispatchTakeResult(
            IsolateHttpServerPairingAction(
              task: HttpServerPairingTask(operation: HttpServerPairingOperation.listen, sessionToken: token),
            ),
          )
          .listen(
            (event) {
              if (event is HttpServerPairingEvent) serverService.forwardPairingEvent(event);
            },
            onError: (Object error) {
              if (mounted) setState(() => _error = friendlyPairingError(error));
            },
          );
      await _refreshSnapshot();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining = _expiresAt!.difference(DateTime.now()).inSeconds;
        if (remaining <= 0) {
          if (mounted) {
            setState(() {
              _remainingSeconds = 0;
              _error = PairingStrings.expired;
            });
          }
          unawaited(_stopSession());
        } else if (mounted) {
          setState(() => _remainingSeconds = remaining);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyPairingError(error));
      await _releaseResources();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _refreshSnapshot() async {
    final token = _sessionToken;
    if (token == null) return;
    final events = ref
        .redux(parentIsolateProvider)
        .dispatchTakeResult(
          IsolateHttpServerPairingAction(
            task: HttpServerPairingTask(operation: HttpServerPairingOperation.snapshot, sessionToken: token),
          ),
        );
    final event = (await events.firstWhere((value) => value is HttpServerPairingEvent && value.snapshot != null)) as HttpServerPairingEvent;
    if (!mounted) return;
    setState(() {
      for (final joined in event.snapshot!.joinedDevices) {
        _joined[joined.device.fingerprint] = joined.device;
        _selected.add(joined.device.fingerprint);
      }
    });
  }

  Future<void> _stopSession({bool stopHotspot = true}) async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    await _releaseResources(stopHotspot: stopHotspot);
    if (mounted) {
      setState(() {
        _sessionToken = null;
        _expiresAt = null;
        _qrData = null;
        _joined.clear();
        _removed.clear();
        _selected.clear();
      });
    }
  }

  Future<void> _releaseResources({bool stopHotspot = true}) async {
    final token = _sessionToken;
    _sessionToken = null;
    await _pairingDisconnectSubscription?.cancel();
    _pairingDisconnectSubscription = null;
    await _pairingActionSubscription?.cancel();
    _pairingActionSubscription = null;
    await _pairingSubscription?.cancel();
    _pairingSubscription = null;
    if (token != null) {
      try {
        await ref
            .redux(parentIsolateProvider)
            .dispatchTakeResult(
              IsolateHttpServerPairingAction(
                task: HttpServerPairingTask(operation: HttpServerPairingOperation.invalidate, sessionToken: token),
              ),
            )
            .drain<void>();
      } catch (_) {
        // The server may already have stopped while the app was backgrounded.
      }
    }
    if (_hotspot != null && stopHotspot) {
      _hotspot = null;
      try {
        await android_channel.stopLocalOnlyHotspotAndroid();
      } catch (_) {
        // The native reservation may already have been released by Android.
      }
    } else if (!stopHotspot) {
      _hotspot = null;
    }
  }

  Future<void> _sendToSelected() async {
    final recipients = _joined.entries.where((entry) => !_removed.contains(entry.key) && _selected.contains(entry.key)).toList();
    if (recipients.isEmpty) return;
    var files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty) {
      await AddFileDialog.open(context: context, options: FilePickerOption.getOptionsForPlatform());
      files = ref.read(selectedSendingFilesProvider);
      if (!context.mounted || files.isEmpty) return;
    }
    setState(() => _sending = true);
    try {
      final notifier = ref.notifier(sendProvider);
      await Future.wait(
        recipients.map(
          (entry) => notifier.startSession(
            target: _deviceFromPairingInfo(entry.value),
            files: files,
            background: true,
            skipChecksums: true,
          ),
        ),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyPairingError(error))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessionToken = _sessionToken;
    final visibleDevices = _joined.entries.where((entry) => !_removed.contains(entry.key)).toList();
    final colors = Theme.of(context).colorScheme;
    final visibleFingerprints = visibleDevices.map((entry) => entry.key).toSet();
    final transferSessions = ref
        .watch(sendProvider)
        .values
        .where(
          (session) =>
              visibleFingerprints.contains(session.target.fingerprint) &&
              {SessionStatus.waiting, SessionStatus.sending, SessionStatus.finishedWithErrors}.contains(session.status),
        )
        .toList();

    return SafeArea(
      child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(20, 18, 20, transferSessions.isEmpty ? 20 : 116),
            children: [
              if (widget.discoverable) _buildProfileHeader(context),
              if (_error != null) _ErrorStrip(message: _error!, onRetry: _startSession),
              if (sessionToken == null) ...[
                if (!widget.discoverable) _buildProfileHeader(context),
                const SizedBox(height: 14),
                Center(
                  child: _starting
                      ? const CircularProgressIndicator()
                      : FilledButton.icon(
                          onPressed: _startSession,
                          icon: const Icon(Icons.visibility_outlined),
                          label: const Text(PairingStrings.start),
                        ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: colors.tertiary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.discoverable ? PairingStrings.visibleToNearby : PairingStrings.waitingForDevices,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(_formatCountdown(_remainingSeconds), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(width: 8),
                    IconButton(tooltip: PairingStrings.stop, onPressed: _stopSession, icon: const Icon(Icons.stop_circle_outlined)),
                  ],
                ),
                if (_qrData != null) ...[
                  const SizedBox(height: 12),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
                      child: GlassCard(
                        margin: EdgeInsets.zero,
                        padding: const EdgeInsets.all(12),
                        child: PrettyQrView.data(
                          data: _qrData!,
                          decoration: PrettyQrDecoration(
                            shape: PrettyQrSmoothSymbol(color: colors.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _CredentialRow(label: PairingStrings.ssid, value: _hotspot!.ssid),
                  _CredentialRow(label: PairingStrings.password, value: _hotspot!.password),
                ],
                const SizedBox(height: 16),
                _JoinedDevicesSection(
                  devices: visibleDevices,
                  selected: _selected,
                  onToggle: (fingerprint, selected) => setState(() {
                    selected ? _selected.add(fingerprint) : _selected.remove(fingerprint);
                  }),
                  onRemove: (fingerprint) => setState(() {
                    _removed.add(fingerprint);
                    _selected.remove(fingerprint);
                  }),
                ),
                if (visibleDevices.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _sending ? null : _sendToSelected,
                    icon: _sending ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
                    label: Text(_selected.length == visibleDevices.length ? PairingStrings.sendToAll : PairingStrings.sendToSelected),
                  ),
                ],
              ],
            ],
          ),
          if (transferSessions.isNotEmpty)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _PairingTransferDock(sessions: transferSessions),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader(BuildContext context) {
    final device = ref.watch(deviceFullInfoProvider);
    final avatarIndex = ref.read(persistenceProvider).getProfileAvatar() % _avatarIcons.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        children: [
          CircleAvatar(radius: 34, child: Icon(_avatarIcons[avatarIndex], size: 32)),
          const SizedBox(height: 10),
          Text(device.alias, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class PairingReceiveDialog extends StatelessWidget {
  final bool allowWebDropLinks;

  const PairingReceiveDialog({required this.allowWebDropLinks, super.key});

  @override
  Widget build(BuildContext context) {
    return ControllerPairingReceiveDialog(allowWebDropLinks: allowWebDropLinks);
  }
}

enum _ReceiverState { scanning, connecting, joining, joined, failed }

class _QrReceiverTab extends StatefulWidget {
  final bool allowWebDropLinks;

  const _QrReceiverTab({required this.allowWebDropLinks});

  @override
  State<_QrReceiverTab> createState() => _QrReceiverTabState();
}

class _QrReceiverTabState extends State<_QrReceiverTab> with Refena {
  PairQrPayload? _payload;
  _ReceiverState _state = _ReceiverState.scanning;
  String? _message;
  bool _handledCode = false;
  int _scannerKey = 0;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handledCode) return;
    final value = capture.barcodes.map((barcode) => barcode.rawValue).whereType<String>().firstOrNull;
    if (value == null) return;

    final parsed = parseQrPayload(value);
    if (parsed case ParsedPairQr(:final payload)) {
      _handledCode = true;
      setState(() {
        _payload = payload;
        _state = _ReceiverState.connecting;
        _message = null;
      });
      if (checkPlatform([TargetPlatform.android])) {
        try {
          final result = await android_channel.connectToWifiHotspotAndroid(ssid: payload.ssid, password: payload.password);
          if (result.succeeded) {
            await _join(payload);
            return;
          }
          if (mounted) setState(() => _message = '${PairingStrings.hotspotConnectionFailed} (${result.code}) ${result.message}');
        } catch (error) {
          if (mounted) setState(() => _message = '${PairingStrings.hotspotConnectionFailed} $error');
        }
        if (mounted) setState(() => _message ??= PairingStrings.hotspotConnectionFailed);
      } else {
        setState(() => _message = PairingStrings.connectToHotspot);
      }
      return;
    }
    if (parsed is ExpiredPairQr) {
      setState(() => _message = PairingStrings.expired);
      return;
    }
    if (parsed case ParsedWebDropQr(:final uri)) {
      if (!widget.allowWebDropLinks) {
        setState(() => _message = PairingStrings.invalidQr);
        return;
      }
      final openLink = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(PairingStrings.openLinkQuestion),
          content: Text(uri.toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text(PairingStrings.close)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text(PairingStrings.open)),
          ],
        ),
      );
      if (openLink == true) await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    setState(() => _message = PairingStrings.invalidQr);
  }

  Future<void> _join(PairQrPayload payload) async {
    setState(() {
      _state = _ReceiverState.joining;
      _message = null;
    });
    try {
      final localDevice = await _ensureLocalServer();
      final request = PairingJoinRequest(
        sessionToken: payload.sessionToken,
        fingerprint: localDevice.fingerprint,
        alias: localDevice.alias,
        version: localDevice.version,
        deviceModel: localDevice.deviceModel,
        deviceType: localDevice.deviceType.toRust(),
        port: localDevice.port,
        protocol: localDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        hasWebInterface: localDevice.download,
      );
      final client = ref.read(httpProvider).pinnedTo(payload.fingerprint, timeout: const Duration(seconds: 3));
      final response = await client.joinPairing(
        protocol: payload.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        ip: payload.ip,
        port: payload.port,
        request: request,
      );
      if (!response.success) throw StateError(PairingStrings.sessionExpired);
      if (mounted) setState(() => _state = _ReceiverState.joined);
    } catch (error) {
      if (mounted) {
        setState(() {
          _state = _ReceiverState.failed;
          _message = friendlyPairingError(error);
        });
      }
    }
  }

  Future<Device> _ensureLocalServer() async {
    if (ref.read(serverProvider) == null) await ref.notifier(serverProvider).startServerFromSettings();
    final device = ref.read(deviceFullInfoProvider);
    if (device.port < 1 || device.ip == '-') throw StateError(PairingStrings.noHostAddress);
    return device;
  }

  Future<void> _retry() async {
    final payload = _payload;
    if (payload == null) {
      setState(() {
        _handledCode = false;
        _state = _ReceiverState.scanning;
        _message = null;
      });
      return;
    }
    await _join(payload);
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  void _retryScanner() {
    setState(() => _scannerKey++);
  }

  @override
  Widget build(BuildContext context) {
    final cameraUnavailable = !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);
    final payload = _payload;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_receiverStateLabel(_state), style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        if (_state == _ReceiverState.scanning)
          if (cameraUnavailable)
            SizedBox(
              height: 220,
              child: Center(child: Text(PairingStrings.cameraUnavailable, textAlign: TextAlign.center)),
            )
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 250,
                child: MobileScanner(
                  key: ValueKey(_scannerKey),
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          error.errorCode == MobileScannerErrorCode.permissionDenied
                              ? PairingStrings.cameraPermissionDenied
                              : PairingStrings.cameraUnavailable,
                          textAlign: TextAlign.center,
                        ),
                        if (error.errorCode == MobileScannerErrorCode.permissionDenied)
                          TextButton.icon(
                            onPressed: _retryScanner,
                            icon: const Icon(Icons.refresh),
                            label: const Text(PairingStrings.retry),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        if (payload != null && _state != _ReceiverState.joined) ...[
          const SizedBox(height: 14),
          _CredentialRow(label: PairingStrings.ssid, value: payload.ssid, onCopy: () => _copy(payload.ssid)),
          _CredentialRow(label: PairingStrings.password, value: payload.password, onCopy: () => _copy(payload.password)),
          if (_state == _ReceiverState.connecting)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: FilledButton.icon(
                onPressed: () => _join(payload),
                icon: const Icon(Icons.wifi),
                label: const Text(PairingStrings.imConnected),
              ),
            ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(
            _message!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
        if (_state == _ReceiverState.joined)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 30),
            child: Icon(Icons.check_circle, size: 52, color: glassGreen),
          ),
        if (_state == _ReceiverState.failed || _state == _ReceiverState.joined)
          Center(
            child: TextButton.icon(
              onPressed: _state == _ReceiverState.joined ? _retryScan : _retry,
              icon: const Icon(Icons.refresh),
              label: const Text(PairingStrings.retry),
            ),
          ),
      ],
    );
  }

  Future<void> _retryScan() async {
    String? disconnectError;
    if (checkPlatform([TargetPlatform.android])) {
      try {
        await android_channel.disconnectFromWifiHotspotAndroid();
      } catch (error) {
        disconnectError = friendlyPairingError(error);
      }
    }
    if (!mounted) return;
    setState(() {
      _payload = null;
      _handledCode = false;
      _state = _ReceiverState.scanning;
      _message = disconnectError;
    });
  }
}

class _NearbyReceiverTab extends StatefulWidget {
  const _NearbyReceiverTab();

  @override
  State<_NearbyReceiverTab> createState() => _NearbyReceiverTabState();
}

class _NearbyReceiverTabState extends State<_NearbyReceiverTab> with Refena {
  final Map<String, _NearbyPairingOffer> _offers = {};
  String? _joiningFingerprint;
  String? _joinedFingerprint;
  String? _error;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_scan());
    });
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
      _offers.clear();
    });
    try {
      ref.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
      await ref.global.dispatchAsync(StartSmartScan());
      final devices = ref.read(nearbyDevicesProvider).devices.values.where((device) => device.ip != null && device.port > 0).toList();
      await Future.wait(devices.map(_queryOffer));
      if (mounted && _offers.isEmpty) setState(() => _error = PairingStrings.noOffer);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyPairingError(error));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _queryOffer(Device device) async {
    try {
      final client = ref.read(httpProvider).pinnedTo(device.fingerprint, timeout: const Duration(milliseconds: 900));
      final offer = await client.sendOffer(
        protocol: device.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        ip: device.ip!,
        port: device.port,
      );
      if (offer == null || offer.expiresAtMs.toInt() <= DateTime.now().millisecondsSinceEpoch || !mounted) return;
      setState(() => _offers[device.fingerprint] = _NearbyPairingOffer(device: device, offer: offer));
    } catch (_) {
      // A timeout, non-pairing device, or unreachable discovery result is not an active offer.
    }
  }

  Future<void> _join(_NearbyPairingOffer item) async {
    setState(() {
      _joiningFingerprint = item.device.fingerprint;
      _error = null;
    });
    try {
      if (ref.read(serverProvider) == null) await ref.notifier(serverProvider).startServerFromSettings();
      final localDevice = ref.read(deviceFullInfoProvider);
      final request = PairingJoinRequest(
        sessionToken: item.offer.joinToken,
        fingerprint: localDevice.fingerprint,
        alias: localDevice.alias,
        version: localDevice.version,
        deviceModel: localDevice.deviceModel,
        deviceType: localDevice.deviceType.toRust(),
        port: localDevice.port,
        protocol: localDevice.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        hasWebInterface: localDevice.download,
      );
      final client = ref.read(httpProvider).pinnedTo(item.device.fingerprint, timeout: const Duration(seconds: 3));
      final response = await client.joinPairing(
        protocol: item.device.https ? rust_model.ProtocolType.https : rust_model.ProtocolType.http,
        ip: item.device.ip!,
        port: item.device.port,
        request: request,
      );
      if (!response.success) throw StateError(PairingStrings.sessionExpired);
      if (mounted) setState(() => _joinedFingerprint = item.device.fingerprint);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyPairingError(error));
    } finally {
      if (mounted) setState(() => _joiningFingerprint = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offers = _offers.values.toList()..sort((a, b) => a.device.alias.toLowerCase().compareTo(b.device.alias.toLowerCase()));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(child: Text(_scanning ? PairingStrings.scanning : PairingStrings.nearby, style: Theme.of(context).textTheme.titleMedium)),
              IconButton(
                tooltip: PairingStrings.refresh,
                onPressed: _scanning ? null : _scan,
                icon: _scanning ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_error != null && offers.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            ),
          )
        else
          Expanded(
            child: offers.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: offers.length,
                    itemBuilder: (context, index) {
                      final item = offers[index];
                      final avatar = _avatarWidget(item.offer.avatarIndex, item.device.alias);
                      final joining = _joiningFingerprint == item.device.fingerprint;
                      final joined = _joinedFingerprint == item.device.fingerprint;
                      return ListTile(
                        leading: avatar,
                        title: Text(item.device.alias, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(joined ? PairingStrings.joined : PairingStrings.visibleToNearby),
                        trailing: joined
                            ? const Icon(Icons.check_circle, color: glassGreen)
                            : IconButton(
                                tooltip: PairingStrings.joining,
                                onPressed: joining ? null : () => _join(item),
                                icon: joining
                                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.login),
                              ),
                        onTap: joined || joining ? null : () => _join(item),
                      );
                    },
                  ),
          ),
        if (offers.any((item) => item.offer.avatarIndex == null))
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(PairingStrings.avatarInitialsNotice, textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

class _NearbyPairingOffer {
  final Device device;
  final PairingSendOffer offer;

  const _NearbyPairingOffer({required this.device, required this.offer});
}

class _JoinedDevicesSection extends StatelessWidget {
  final List<MapEntry<String, PairingDeviceInfo>> devices;
  final Set<String> selected;
  final void Function(String fingerprint, bool selected) onToggle;
  final void Function(String fingerprint) onRemove;

  const _JoinedDevicesSection({required this.devices, required this.selected, required this.onToggle, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text(PairingStrings.noJoinedDevices)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(PairingStrings.device, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(PairingStrings.avatarInitialsNotice),
        ),
        for (final entry in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(child: Text(_initials(entry.value.alias))),
            title: Text(entry.value.alias, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(entry.value.deviceModel ?? entry.value.ip, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Checkbox(value: selected.contains(entry.key), onChanged: (value) => onToggle(entry.key, value ?? false)),
                IconButton(
                  tooltip: PairingStrings.remove,
                  onPressed: () => onRemove(entry.key),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PairingTransferDock extends StatelessWidget {
  final List<SendSessionState> sessions;

  const _PairingTransferDock({required this.sessions});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface.withValues(alpha: 0.96),
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 140),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: sessions.map((session) {
                return Row(
                  children: [
                    const Icon(Icons.upload_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(session.target.alias, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Text(_transferStatus(session.status)),
                    const SizedBox(width: 8),
                    if (session.status == SessionStatus.waiting || session.status == SessionStatus.sending)
                      const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      const Icon(Icons.error_outline, size: 18, color: Colors.red),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onCopy;

  const _CredentialRow({required this.label, required this.value, this.onCopy});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.labelMedium),
      subtitle: SelectableText(value),
      trailing: onCopy == null ? null : IconButton(tooltip: PairingStrings.copy, onPressed: onCopy, icon: const Icon(Icons.copy)),
    );
  }
}

class _ErrorStrip extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorStrip({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
              IconButton(tooltip: PairingStrings.retry, onPressed: onRetry, icon: const Icon(Icons.refresh)),
            ],
          ),
        ),
      ),
    );
  }
}

Device _deviceFromPairingInfo(PairingDeviceInfo info) {
  final https = info.protocol == rust_model.ProtocolType.https;
  return Device(
    signalingId: null,
    ip: info.ip,
    version: info.version,
    port: info.port,
    https: https,
    fingerprint: info.fingerprint,
    alias: info.alias,
    deviceModel: info.deviceModel,
    deviceType: info.deviceType?.toDart() ?? DeviceType.desktop,
    download: info.hasWebInterface,
    channels: [HttpChannel(host: info.ip, port: info.port, https: https)],
  );
}

Widget _avatarWidget(int? avatarIndex, String alias) {
  if (avatarIndex != null && avatarIndex >= 0 && avatarIndex < _avatarIcons.length) {
    return CircleAvatar(child: Icon(_avatarIcons[avatarIndex]));
  }
  return CircleAvatar(child: Text(_initials(alias)));
}

String _initials(String alias) {
  final words = alias.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).take(2);
  final initials = words.map((word) => word.characters.first.toUpperCase()).join();
  return initials.isEmpty ? '?' : initials;
}

String _formatCountdown(int seconds) {
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
}

String _receiverStateLabel(_ReceiverState state) => switch (state) {
  _ReceiverState.scanning => PairingStrings.scanning,
  _ReceiverState.connecting => PairingStrings.connecting,
  _ReceiverState.joining => PairingStrings.joining,
  _ReceiverState.joined => PairingStrings.joined,
  _ReceiverState.failed => PairingStrings.failed,
};

String _transferStatus(SessionStatus status) => switch (status) {
  SessionStatus.waiting => PairingStrings.connecting,
  SessionStatus.sending => PairingStrings.sendingFiles,
  SessionStatus.finished => PairingStrings.finished,
  SessionStatus.finishedWithErrors => PairingStrings.failed,
  _ => PairingStrings.failed,
};
