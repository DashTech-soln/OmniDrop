import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/pages/pairing/pairing_strings.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/qr_payload_parser.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/glass/glass_card.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/rust/api/pairing.dart';
import 'package:localsend_isolates/util/rust.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class ControllerPairingPage extends StatelessWidget {
  const ControllerPairingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(PairingStrings.pairing),
          bottom: const TabBar(
            tabs: [
              Tab(text: PairingStrings.qr, icon: Icon(Icons.qr_code_2)),
              Tab(text: PairingStrings.wifiDirect, icon: Icon(Icons.wifi_find)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _SenderPairingTab(mode: PairingMode.qr),
            _SenderPairingTab(mode: PairingMode.sameNetwork),
          ],
        ),
      ),
    );
  }
}

class _SenderPairingTab extends StatefulWidget {
  final PairingMode mode;

  const _SenderPairingTab({required this.mode});

  @override
  State<_SenderPairingTab> createState() => _SenderPairingTabState();
}

class _SenderPairingTabState extends State<_SenderPairingTab> with Refena {
  late final TextEditingController _pinController;
  final Set<String> _selected = {};
  final Set<String> _deselected = {};
  bool _multiRecipient = false;
  bool _pinEnabled = false;
  bool _encrypted = true;
  bool _sending = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final controller = ref.notifier(pairingControllerProvider);
    _pinController = TextEditingController(text: controller.suggestPin());
    _encrypted = ref.read(serverProvider)?.https ?? ref.read(settingsProvider).https;
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await ref
          .notifier(pairingControllerProvider)
          .startSender(
            PairingOptions(
              mode: widget.mode,
              multiRecipient: _multiRecipient,
              pinEnabled: _pinEnabled,
              pin: _pinController.text,
              encrypted: _encrypted,
            ),
          );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyPairingError(error))));
    }
  }

  Future<void> _sendToSelected(List<PairingDeviceInfo> peers) async {
    var files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty) {
      await AddFileDialog.open(context: context, options: FilePickerOption.getOptionsForPlatform());
      files = ref.read(selectedSendingFilesProvider);
      if (!mounted || files.isEmpty) return;
    }
    final selected = peers
        .where((peer) => !_deselected.contains(peer.fingerprint) && (_selected.isEmpty || _selected.contains(peer.fingerprint)))
        .toList();
    if (selected.isEmpty) return;

    setState(() => _sending = true);
    final controller = ref.notifier(pairingControllerProvider);
    controller.setTransferring(true);
    try {
      await Future.wait(
        selected.map(
          (peer) => ref
              .notifier(sendProvider)
              .startSession(
                target: DeviceFromPairingInfo.convert(peer),
                files: files,
                background: true,
                skipChecksums: true,
              ),
        ),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyPairingError(error))));
    } finally {
      controller.setTransferring(false);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pairingControllerProvider);
    final colors = Theme.of(context).colorScheme;
    final hasSession = state.sessionToken != null;
    final expiryMinutes = state.expiresAt?.difference(DateTime.now()).inMinutes.clamp(0, 5);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (!hasSession) ...[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow multiple receivers'),
            value: _multiRecipient,
            onChanged: (value) => setState(() => _multiRecipient = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Require a six-digit PIN'),
            value: _pinEnabled,
            onChanged: (value) => setState(() => _pinEnabled = value),
          ),
          if (_pinEnabled)
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                labelText: 'Pairing PIN',
                counterText: '',
                suffixIcon: IconButton(
                  tooltip: 'Suggest PIN',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _pinController.text = ref.notifier(pairingControllerProvider).suggestPin(),
                ),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Encrypted connection (HTTPS)'),
            value: _encrypted,
            onChanged: (value) => setState(() => _encrypted = value),
          ),
          if (state.phase == PairingPhase.startingHotspot || state.phase == PairingPhase.startingSession)
            const Center(child: CircularProgressIndicator())
          else
            FilledButton.icon(
              onPressed: _start,
              icon: Icon(widget.mode == PairingMode.qr ? Icons.qr_code_2 : Icons.wifi_find),
              label: Text(widget.mode == PairingMode.qr ? PairingStrings.startQr : PairingStrings.startNearby),
            ),
        ] else ...[
          Row(
            children: [
              Expanded(child: Text(widget.mode == PairingMode.qr ? PairingStrings.waitingForDevices : PairingStrings.visibleToNearby)),
              if (expiryMinutes != null) Text('$expiryMinutes min'),
              IconButton(
                tooltip: PairingStrings.stop,
                onPressed: () => ref.notifier(pairingControllerProvider).stop(),
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ],
          ),
          if (state.qrPayload != null) ...[
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280, maxHeight: 280),
                child: GlassCard(
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(12),
                  child: PrettyQrView.data(
                    data: state.qrPayload!,
                    decoration: PrettyQrDecoration(shape: PrettyQrSmoothSymbol(color: colors.onSurface)),
                  ),
                ),
              ),
            ),
            if (state.ssid != null) _CredentialLine(label: PairingStrings.ssid, value: state.ssid!),
            if (state.password != null) _CredentialLine(label: PairingStrings.password, value: state.password!),
          ],
          if (state.pinRequired && state.pin != null) _CredentialLine(label: 'Pairing PIN', value: state.pin!),
          const SizedBox(height: 12),
          if (state.peers.isEmpty)
            const Center(
              child: Padding(padding: EdgeInsets.all(20), child: Text(PairingStrings.noJoinedDevices)),
            )
          else ...[
            Text(PairingStrings.device, style: Theme.of(context).textTheme.titleMedium),
            for (final peer in state.peers)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: !_deselected.contains(peer.fingerprint),
                title: Text(peer.alias),
                subtitle: Text(peer.deviceModel ?? peer.ip),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _selected.add(peer.fingerprint);
                    _deselected.remove(peer.fingerprint);
                  } else {
                    _deselected.add(peer.fingerprint);
                    _selected.remove(peer.fingerprint);
                  }
                }),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _sending ? null : () => _sendToSelected(state.peers),
              icon: _sending ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
              label: Text(PairingStrings.sendToSelected),
            ),
          ],
        ],
        if (state.failureReason != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(state.failureReason!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        if (state.locationSettingsRequired && checkPlatform([TargetPlatform.android]))
          TextButton.icon(
            onPressed: android_channel.openLocationSettingsAndroid,
            icon: const Icon(Icons.location_on_outlined),
            label: const Text(PairingStrings.locationSettings),
          ),
      ],
    );
  }
}

class ControllerPairingReceiveDialog extends StatefulWidget {
  final bool allowWebDropLinks;

  const ControllerPairingReceiveDialog({required this.allowWebDropLinks, super.key});

  @override
  State<ControllerPairingReceiveDialog> createState() => _ControllerPairingReceiveDialogState();
}

class _ControllerPairingReceiveDialogState extends State<ControllerPairingReceiveDialog> with Refena {
  late final TextEditingController _pinController;
  int _scannerKey = 0;
  bool _handledCode = false;
  PairQrPayload? _payload;

  @override
  void initState() {
    super.initState();
    _pinController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initializeReceiver());
    });
  }

  Future<void> _initializeReceiver() async {
    final controller = ref.notifier(pairingControllerProvider);
    await controller.enterReceiver();
    await controller.scanNearbyOffers();
  }

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handledCode) return;
    final value = capture.barcodes.map((barcode) => barcode.rawValue).whereType<String>().firstOrNull;
    if (value == null) return;
    final parsed = parseQrPayload(value);
    if (parsed case ParsedPairQr(:final payload)) {
      _handledCode = true;
      _payload = payload;
      await ref.notifier(pairingControllerProvider).receiveQr(payload);
      return;
    }
    if (parsed is ExpiredPairQr) {
      _showMessage(PairingStrings.expired);
      return;
    }
    if (parsed case ParsedWebDropQr(:final uri)) {
      if (!widget.allowWebDropLinks) {
        _showMessage(PairingStrings.invalidQr);
        return;
      }
      final open = await showDialog<bool>(
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
      if (open == true) await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    _showMessage(PairingStrings.invalidQr);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _retry() async {
    final phase = ref.read(pairingControllerProvider).phase;
    if (phase == PairingPhase.waitingForPin ||
        phase == PairingPhase.manualGuide ||
        phase == PairingPhase.failed && ref.read(pairingControllerProvider).pinRequired) {
      if (phase == PairingPhase.manualGuide && _payload != null) {
        await ref.notifier(pairingControllerProvider).continueAfterManualWifi();
      } else {
        await ref.notifier(pairingControllerProvider).submitPin(_pinController.text);
      }
      return;
    }
    if (phase == PairingPhase.failed && _payload == null) {
      await ref.notifier(pairingControllerProvider).enterReceiver();
      return;
    }
    await ref.notifier(pairingControllerProvider).retry();
  }

  Future<void> _scanNearby() => ref.notifier(pairingControllerProvider).scanNearbyOffers();

  Future<void> _joinOffer(PairingNearbyOffer offer) => ref.notifier(pairingControllerProvider).joinNearby(offer);

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pairingControllerProvider);
    final size = MediaQuery.sizeOf(context);
    final height = (size.height * 0.82).clamp(260.0, 720.0).toDouble();
    final width = (size.width - 32).clamp(280.0, 540.0).toDouble();
    return DefaultTabController(
      length: 2,
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text(PairingStrings.pairing, style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(tooltip: PairingStrings.close, onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: PairingStrings.qrScanner, icon: Icon(Icons.qr_code_scanner)),
                  Tab(text: PairingStrings.nearby, icon: Icon(Icons.devices)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildQrContent(state),
                    _buildNearbyContent(state),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQrContent(PairingState state) {
    final cameraUnavailable = !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_receiverLabel(state.phase), style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        if (state.phase == PairingPhase.scanning || state.phase == PairingPhase.enablingWifi)
          if (cameraUnavailable)
            const SizedBox(
              height: 220,
              child: Center(child: Text(PairingStrings.cameraUnavailable, textAlign: TextAlign.center)),
            )
          else
            SizedBox(
              height: 250,
              child: MobileScanner(key: ValueKey(_scannerKey), onDetect: _onDetect),
            ),
        if (state.phase == PairingPhase.manualGuide && _payload != null) ...[
          _CredentialLine(label: PairingStrings.ssid, value: _payload!.ssid),
          _CredentialLine(label: PairingStrings.password, value: _payload!.password, copy: true),
          const Text('Connect to this Wi-Fi network, then continue pairing.'),
        ],
        if (state.phase == PairingPhase.waitingForPin)
          TextField(
            controller: _pinController,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Enter the six-digit PIN', counterText: ''),
          ),
        if (state.wifiEnabled == false && checkPlatform([TargetPlatform.android]))
          TextButton.icon(
            onPressed: android_channel.openWifiSettingsAndroid,
            icon: const Icon(Icons.settings),
            label: const Text('Open Wi-Fi settings'),
          ),
        if (state.failureReason != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              state.failureReason!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ),
        if (state.phase == PairingPhase.joined)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Icon(Icons.check_circle, size: 52, color: Colors.green),
          ),
        if ({PairingPhase.manualGuide, PairingPhase.waitingForPin, PairingPhase.failed}.contains(state.phase))
          FilledButton.icon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
            label: Text(state.phase == PairingPhase.manualGuide ? 'Continue' : PairingStrings.retry),
          ),
        if (state.phase == PairingPhase.joined)
          TextButton.icon(
            onPressed: () {
              _payload = null;
              _handledCode = false;
              setState(() => _scannerKey++);
              unawaited(ref.notifier(pairingControllerProvider).enterReceiver());
            },
            icon: const Icon(Icons.refresh),
            label: const Text(PairingStrings.retry),
          ),
      ],
    );
  }

  Widget _buildNearbyContent(PairingState state) {
    final offers = [...state.offers]..sort((a, b) => a.device.alias.toLowerCase().compareTo(b.device.alias.toLowerCase()));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(child: Text(state.phase == PairingPhase.scanning ? PairingStrings.scanning : PairingStrings.nearby)),
              IconButton(
                tooltip: PairingStrings.refresh,
                onPressed: state.phase == PairingPhase.scanning ? null : _scanNearby,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (state.failureReason != null) Padding(padding: const EdgeInsets.all(10), child: Text(state.failureReason!)),
        Expanded(
          child: offers.isEmpty
              ? const Center(child: Text(PairingStrings.noOffer))
              : ListView(
                  children: [
                    for (final item in offers)
                      ListTile(
                        title: Text(item.device.alias),
                        subtitle: Text(PairingStrings.visibleToNearby),
                        trailing: IconButton(icon: const Icon(Icons.login), onPressed: () => _joinOffer(item)),
                        onTap: () => _joinOffer(item),
                      ),
                  ],
                ),
        ),
        if (state.phase == PairingPhase.waitingForPin)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _pinController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: 'Enter the six-digit PIN', counterText: ''),
                  onSubmitted: (_) => ref.notifier(pairingControllerProvider).submitPin(_pinController.text),
                ),
                FilledButton(
                  onPressed: () => ref.notifier(pairingControllerProvider).submitPin(_pinController.text),
                  child: const Text('Join'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CredentialLine extends StatelessWidget {
  final String label;
  final String value;
  final bool copy;

  const _CredentialLine({required this.label, required this.value, this.copy = false});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: SelectableText(value),
      trailing: copy
          ? IconButton(
              tooltip: PairingStrings.copy,
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            )
          : null,
    );
  }
}

String _receiverLabel(PairingPhase phase) => switch (phase) {
  PairingPhase.enablingWifi => 'Enabling Wi-Fi',
  PairingPhase.scanning => PairingStrings.scanning,
  PairingPhase.connecting => PairingStrings.connecting,
  PairingPhase.joining => PairingStrings.joining,
  PairingPhase.waitingForPin => 'PIN required',
  PairingPhase.joined => PairingStrings.joined,
  PairingPhase.manualGuide => 'Connect to the sender network',
  PairingPhase.failed => PairingStrings.failed,
  _ => PairingStrings.scanning,
};

class DeviceFromPairingInfo {
  static Device convert(PairingDeviceInfo info) {
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
      channels: const [],
    );
  }
}
