import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/pairing/pairing_controller.dart';
import 'package:localsend_app/util/qr_payload_parser.dart';
import 'package:localsend_app/pages/pairing/pairing_cards.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust_model;
import 'package:localsend_isolates/rust/api/pairing.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

PairingDeviceInfo _device(String fingerprint, String alias) => PairingDeviceInfo(
  fingerprint: fingerprint,
  alias: alias,
  version: '2.2',
  deviceModel: null,
  deviceType: null,
  ip: '192.168.1.2',
  port: 53317,
  protocol: rust_model.ProtocolType.http,
  hasWebInterface: false,
);

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('single-recipient paired control event closes selection', () async {
    final service = Notifier.test(
      notifier: PairingController(),
      initialState: const PairingState(
        phase: PairingPhase.peerJoined,
        role: PairingRole.sender,
      ),
    );

    await service.notifier.handleControlEvent('paired');

    expect(service.state.phase, PairingPhase.closedForSelection);
    expect(service.state.sessionToken, isNull);
  });

  test('multi-recipient paired control event keeps the session open', () async {
    final service = Notifier.test(
      notifier: PairingController(),
      initialState: const PairingState(
        phase: PairingPhase.peerJoined,
        role: PairingRole.sender,
        sessionToken: 'active-session',
        multiRecipient: true,
      ),
    );

    await service.notifier.handleControlEvent('paired');

    expect(service.state.phase, PairingPhase.peerJoined);
    expect(service.state.sessionToken, 'active-session');
  });

  test(
    'multi-recipient flag keeps the sender pairing card open after a join',
    () {
      expect(shouldAutoClosePairingSenderCard(multiRecipient: true), isFalse);
      expect(shouldAutoClosePairingSenderCard(multiRecipient: false), isTrue);
    },
  );

  test('invalid PIN is rejected before attempting a join', () async {
    final service = Notifier.test(
      notifier: PairingController(),
      initialState: const PairingState(
        phase: PairingPhase.waitingForPin,
        role: PairingRole.receiver,
      ),
    );

    await service.notifier.submitPin('12345');

    expect(service.state.phase, PairingPhase.failed);
    expect(service.state.failureReason, 'PIN must be exactly six digits.');
  });

  test('receiver can retry after manual Wi-Fi fallback', () async {
    final service = Notifier.test(notifier: PairingController());
    const payload = PairQrPayload(
      alias: 'sender',
      ip: '192.168.1.2',
      port: 53317,
      https: true,
      fingerprint: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      sessionToken: 'session-token',
      ssid: 'network',
      password: 'password',
      pinRequired: true,
      expiresAtMs: 4_000_000_000_000,
    );

    await service.notifier.receiveQr(payload);
    expect(service.state.phase, PairingPhase.manualGuide);

    await service.notifier.continueAfterManualWifi();
    expect(service.state.phase, PairingPhase.waitingForPin);

    await service.notifier.retry();
    expect(service.state.phase, PairingPhase.manualGuide);
  });

  test(
    'control events do not tear down the session; explicit stop does',
    () async {
      final service = Notifier.test(
        notifier: PairingController(),
        initialState: const PairingState(
          phase: PairingPhase.peerJoined,
          role: PairingRole.sender,
          sessionToken: 'active-session',
        ),
      );

      await service.notifier.handleControlEvent('finalized');
      expect(service.state.phase, PairingPhase.closedForSelection);
      expect(service.state.sessionToken, 'active-session');

      final explicitStop = Notifier.test(
        notifier: PairingController(),
        initialState: const PairingState(
          phase: PairingPhase.peerJoined,
          role: PairingRole.sender,
        ),
      );
      await explicitStop.notifier.stop();
      expect(explicitStop.state.phase, PairingPhase.idle);
    },
  );

  test('edited PIN reaches the Rust pairing session options', () {
    const options = PairingOptions(
      mode: PairingMode.sameNetwork,
      multiRecipient: false,
      pinEnabled: true,
      pin: '827164',
      encrypted: true,
    );

    final task = options.toSessionTask(
      sender: _device('SENDER', 'Sender'),
      avatarIndex: 2,
    );

    expect(task.pin, '827164');
  });

  test('pending pairing lifetime is two minutes', () {
    expect(PairingController.sessionLifetime, const Duration(minutes: 2));
  });

  test('expiry does not stop a paired session', () async {
    final service = Notifier.test(
      notifier: PairingController(),
      initialState: PairingState(
        phase: PairingPhase.peerJoined,
        role: PairingRole.sender,
        sessionToken: 'paired-session',
        peers: [_device('RECEIVER', 'Receiver')],
      ),
    );

    await service.notifier.stop(expired: true);

    expect(service.state.sessionToken, 'paired-session');
    expect(service.state.phase, PairingPhase.peerJoined);
    expect(service.state.peers, hasLength(1));
  });

  test('stopping receiver pairing returns the controller to idle', () async {
    final service = Notifier.test(
      notifier: PairingController(),
      initialState: const PairingState(
        phase: PairingPhase.scanning,
        role: PairingRole.receiver,
      ),
    );

    await service.notifier.stop();

    expect(service.state.phase, PairingPhase.idle);
    expect(service.state.role, isNull);
  });

  test('pairing connection reset clears peers and recipient selection', () {
    final service = Notifier.test(notifier: PairingConnectionController());
    final peer = _device('RECEIVER', 'Receiver');
    service.notifier.connect(
      role: PairingRole.sender,
      sessionToken: 'connection',
      peers: [peer],
    );
    service.notifier.rememberSelection({'RECEIVER'});

    service.notifier.clear();

    expect(service.state.isConnected, isFalse);
    expect(service.state.lastSelectedFingerprints, isEmpty);
    expect(service.state.activeTransferCount, 0);
  });

  test('recipient selection toggles all and individual devices', () {
    const ids = {'A', 'B', 'C'};
    final all = PairingRecipientSelection.toggleAll({}, ids);
    expect(all, ids);
    expect(PairingRecipientSelection.toggleAll(all, ids), isEmpty);
    expect(PairingRecipientSelection.togglePeer(all, 'B', false), {'A', 'C'});
    expect(PairingRecipientSelection.togglePeer({'A', 'C'}, 'B', true), ids);
  });

  test(
    'a single connected peer is selected directly without a picker selection',
    () {
      final peer = _device('RECEIVER', 'Receiver');

      expect(pairingTargetsForSelection([peer], {}), [peer]);
    },
  );
}
