import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/engine/intercom_engine.dart';
import 'package:intercom_talkie/engine/rtc_backend.dart';
import 'package:intercom_talkie/engine/settings.dart';
import 'package:intercom_talkie/platform/native_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fakeSdp =
    'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';

// ---------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------

class FakeTrack implements RtcAudioTrack {
  FakeTrack(this._id);

  final String _id;
  bool enabled = true;

  @override
  String get id => _id;

  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
  }
}

class FakeMicrophone implements RtcMicrophone {
  @override
  final FakeTrack track = FakeTrack('local-mic');
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakePeer implements RtcPeer {
  FakePeer(this.microphone);

  final FakeMicrophone microphone;
  FakeTrack? remoteTrack;

  void Function(String state)? _iceState;
  void Function(RtcCandidate candidate)? _candidate;
  void Function(RtcAudioTrack track)? _track;

  bool localSet = false;
  bool remoteSet = false;
  bool closed = false;
  int iceCandidatesAdded = 0;

  @override
  Future<RtcDescription> createOffer() async {
    _emitCandidate();
    return const RtcDescription(type: 'offer', sdp: fakeSdp);
  }

  @override
  Future<RtcDescription> createAnswer() async {
    _emitCandidate();
    return const RtcDescription(type: 'answer', sdp: fakeSdp);
  }

  void _emitCandidate() {
    Timer(const Duration(milliseconds: 5), () {
      _candidate?.call(
          const RtcCandidate(candidate: 'candidate:1', sdpMid: '0', sdpMLineIndex: 0));
    });
  }

  void _maybeConnect() {
    if (localSet && remoteSet) {
      Timer(const Duration(milliseconds: 20), () {
        if (closed) {
          return;
        }
        remoteTrack = FakeTrack('remote-audio');
        _track?.call(remoteTrack!);
        _iceState?.call('connected');
      });
    }
  }

  void simulateIceFailure() {
    _iceState?.call('failed');
  }

  @override
  Future<void> setLocalDescription(RtcDescription description) async {
    localSet = true;
    _maybeConnect();
  }

  @override
  Future<void> setRemoteDescription(RtcDescription description) async {
    remoteSet = true;
    _maybeConnect();
  }

  @override
  Future<void> addIceCandidate(RtcCandidate candidate) async {
    iceCandidatesAdded++;
  }

  @override
  Future<List<Map<String, dynamic>>> getStats() async {
    return <Map<String, dynamic>>[
      {
        'type': 'candidate-pair',
        'state': 'succeeded',
        'selected': true,
        'currentRoundTripTime': 0.012,
      },
      {
        'type': 'inbound-rtp',
        'kind': 'audio',
        'jitter': 0.004,
        'packetsLost': 2,
        'packetsReceived': 100,
        'audioLevel': 0.7,
        'bytesReceived': 12000,
        'timestamp': 1.0,
      },
      {
        'type': 'outbound-rtp',
        'kind': 'audio',
        'audioLevel': 0.4,
        'bytesSent': 11000,
        'timestamp': 1.0,
      },
    ];
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  void setOnIceCandidate(void Function(RtcCandidate candidate) callback) {
    _candidate = callback;
  }

  @override
  void setOnIceConnectionState(void Function(String state) callback) {
    _iceState = callback;
  }

  @override
  void setOnRemoteAudioTrack(void Function(RtcAudioTrack track) callback) {
    _track = callback;
  }
}

class FakeRtcBackend implements RtcBackend {
  final List<FakePeer> peers = [];
  int micOpens = 0;
  bool? lastMicMute;
  bool? lastSpeakerphone;
  int audioSessionRecoveries = 0;

  @override
  Future<void> prepareAudioSession() async {}

  @override
  Future<RtcMicrophone> openMicrophone() async {
    micOpens++;
    return FakeMicrophone();
  }

  @override
  Future<RtcPeer> createPeer(RtcMicrophone microphone) async {
    final peer = FakePeer(microphone as FakeMicrophone);
    peers.add(peer);
    return peer;
  }

  @override
  Future<void> muteMicrophone(bool muted) async {
    lastMicMute = muted;
  }

  @override
  Future<void> setSpeakerphone(bool enabled) async {
    lastSpeakerphone = enabled;
  }

  @override
  Future<void> recoverAudioSession() async {
    audioSessionRecoveries++;
  }
}

class FakeNativeBridge implements NativeBridge {
  int startServiceCalls = 0;
  int stopServiceCalls = 0;
  int recoverAudioCalls = 0;
  bool keepScreenOn = false;

  @override
  void Function(NativeEvent event)? onEvent;

  @override
  void start() {}

  @override
  void dispose() {
    onEvent = null;
  }

  @override
  Future<void> startForegroundService({
    required String title,
    required String text,
  }) async {
    startServiceCalls++;
  }

  @override
  Future<void> updateForegroundService({required String text}) async {}

  @override
  Future<void> stopForegroundService() async {
    stopServiceCalls++;
  }

  @override
  Future<void> recoverAudio() async {
    recoverAudioCalls++;
  }

  @override
  Future<List<AudioRoute>> getAudioRoutes() async => const <AudioRoute>[];

  @override
  Future<bool> setAudioRoute(String id) async => false;

  @override
  Future<void> setKeepScreenOn(bool enabled) async {
    keepScreenOn = enabled;
  }

  @override
  Future<void> openHotspotSettings() async {}

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => false;

  @override
  Future<Map<String, String>> platformInfo() async =>
      const <String, String>{'platform': 'test'};

  // ----- Shared music (not used by the engine tests) -----

  @override
  Future<Map<String, String>?> pickMusicFile() async => null;

  @override
  Future<int> musicLoad(String path) async => 0;

  @override
  Future<void> musicPlay() async {}

  @override
  Future<void> musicPause() async {}

  @override
  Future<void> musicStop() async {}

  @override
  Future<void> musicSeek(int milliseconds) async {}

  @override
  Future<int> musicPosition() async => 0;
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

Future<int> freeTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<bool> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return condition();
}

Future<IntercomSettings> testSettings({String name = '', String code = ''}) async {
  final settings = IntercomSettings();
  await settings.load();
  settings.deviceName = name;
  settings.passcode = code;
  return settings;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('host and client establish a session over loopback', () async {
    final port = await freeTcpPort();
    final hostBackend = FakeRtcBackend();
    final clientBackend = FakeRtcBackend();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'HostPhone'),
      backend: hostBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'ClientPhone'),
      backend: clientBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );

    await hostEngine.startHost();
    expect(hostEngine.state, IntercomState.waitingForPeer);

    await clientEngine.startClient(manualHost: '127.0.0.1');

    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
      reason: 'engines should become connected',
    );

    expect(hostEngine.peerName, 'ClientPhone');
    expect(clientEngine.peerName, 'HostPhone');
    expect(hostBackend.micOpens, 1);
    expect(clientBackend.micOpens, 1);
    expect(
      hostBackend.peers.first.iceCandidatesAdded +
          clientBackend.peers.first.iceCandidatesAdded,
      greaterThanOrEqualTo(2),
      reason: 'ICE candidates should have been exchanged',
    );

    await hostEngine.stop();
    await clientEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('passcode mismatch is reported and stops the client', () async {
    final port = await freeTcpPort();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host', code: '9999'),
      backend: FakeRtcBackend(),
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientBridge = FakeNativeBridge();
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'Client', code: '0000'),
      backend: FakeRtcBackend(),
      bridge: clientBridge,
      signalingPort: port,
    );

    await hostEngine.startHost();
    await clientEngine.startClient(manualHost: '127.0.0.1');

    expect(
      await until(() => clientEngine.state == IntercomState.idle),
      isTrue,
      reason: 'client should stop after badcode',
    );
    expect(clientEngine.lastError, contains('Passcode'));

    await hostEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('mic mute propagates to the peer and disables the local track',
      () async {
    final port = await freeTcpPort();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host'),
      backend: FakeRtcBackend(),
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientBackend = FakeRtcBackend();
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'Client'),
      backend: clientBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );

    await hostEngine.startHost();
    await clientEngine.startClient(manualHost: '127.0.0.1');
    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
    );

    clientEngine.setMicMuted(true);
    expect(clientBackend.peers.last.microphone.track.enabled, isFalse);

    expect(
      await until(() => hostEngine.peerMicMuted),
      isTrue,
      reason: 'host should learn the peer muted',
    );

    clientEngine.setMicMuted(false);
    expect(clientBackend.peers.last.microphone.track.enabled, isTrue);
    expect(
      await until(() => !hostEngine.peerMicMuted),
      isTrue,
    );

    await hostEngine.stop();
    await clientEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('phone-call interruption pauses and auto-resumes', () async {
    final port = await freeTcpPort();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host'),
      backend: FakeRtcBackend(),
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientBackend = FakeRtcBackend();
    final clientBridge = FakeNativeBridge();
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'Client'),
      backend: clientBackend,
      bridge: clientBridge,
      signalingPort: port,
    );

    await hostEngine.startHost();
    await clientEngine.startClient(manualHost: '127.0.0.1');
    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
    );

    final clientPeer = clientBackend.peers.last;
    expect(clientPeer.microphone.track.enabled, isTrue);

    // An incoming phone call arrives on the client phone.
    clientBridge.onEvent?.call(const NativeEvent('interruptionBegan'));
    expect(
      await until(() => clientEngine.state == IntercomState.paused),
      isTrue,
      reason: 'engine should pause during a call',
    );
    expect(clientPeer.microphone.track.enabled, isFalse,
        reason: 'mic must be muted during a phone call');
    expect(clientPeer.remoteTrack?.enabled, isFalse,
        reason: 'remote playback must stop during a phone call');

    // The call ends — audio must resume without user action.
    clientBridge.onEvent?.call(const NativeEvent('interruptionEnded', 'resume'));
    expect(
      await until(() => clientEngine.state == IntercomState.connected),
      isTrue,
      reason: 'engine should auto-resume after the call',
    );
    expect(clientPeer.microphone.track.enabled, isTrue);
    expect(clientPeer.remoteTrack?.enabled, isTrue);
    expect(clientBridge.recoverAudioCalls, greaterThanOrEqualTo(1));
    expect(clientBackend.audioSessionRecoveries, greaterThanOrEqualTo(1));

    // The host never noticed anything except a mute blip.
    expect(hostEngine.state, IntercomState.connected);

    await hostEngine.stop();
    await clientEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('push-to-talk keeps the mic closed until pressed', () async {
    final port = await freeTcpPort();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host'),
      backend: FakeRtcBackend(),
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientBackend = FakeRtcBackend();
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'Client'),
      backend: clientBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    clientEngine.settings.pushToTalk = true;

    await hostEngine.startHost();
    await clientEngine.startClient(manualHost: '127.0.0.1');
    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
    );

    final clientPeer = clientBackend.peers.last;
    expect(clientPeer.microphone.track.enabled, isFalse,
        reason: 'PTT mode starts muted');

    clientEngine.setPttActive(true);
    expect(clientPeer.microphone.track.enabled, isTrue);

    clientEngine.setPttActive(false);
    expect(clientPeer.microphone.track.enabled, isFalse);

    await hostEngine.stop();
    await clientEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('auto-reconnect rebuilds the link after ICE failure', () async {
    final port = await freeTcpPort();
    final hostBackend = FakeRtcBackend();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host'),
      backend: hostBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );
    final clientBackend = FakeRtcBackend();
    final clientEngine = IntercomEngine(
      settings: await testSettings(name: 'Client'),
      backend: clientBackend,
      bridge: FakeNativeBridge(),
      signalingPort: port,
    );

    await hostEngine.startHost();
    await clientEngine.startClient(manualHost: '127.0.0.1');
    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
    );
    expect(clientBackend.micOpens, 1);

    // Simulate a catastrophic link failure on both sides.
    hostBackend.peers.last.simulateIceFailure();
    clientBackend.peers.last.simulateIceFailure();

    // Host returns to waiting, client reconnects automatically.
    expect(
      await until(() =>
          hostEngine.state == IntercomState.connected &&
          clientEngine.state == IntercomState.connected),
      isTrue,
      reason: 'link should be rebuilt automatically',
    );
    expect(clientBackend.micOpens, greaterThanOrEqualTo(2),
        reason: 'client re-opened the mic for the new session');
    expect(clientEngine.reconnectAttempt, 0,
        reason: 'attempt counter resets after success');

    await hostEngine.stop();
    await clientEngine.stop();
    await hostEngine.dispose();
    await clientEngine.dispose();
  });

  test('LinkStats parses candidate-pair and rtp reports', () {
    final stats = LinkStats();
    stats.update(<Map<String, dynamic>>[
      {
        'type': 'candidate-pair',
        'state': 'succeeded',
        'selected': true,
        'currentRoundTripTime': 0.0125,
      },
      {
        'type': 'inbound-rtp',
        'kind': 'audio',
        'jitter': 0.0032,
        'packetsLost': 3,
        'packetsReceived': 297,
        'audioLevel': 0.65,
      },
    ]);
    expect(stats.rttMs, closeTo(12.5, 0.001));
    expect(stats.jitterMs, closeTo(3.2, 0.01));
    expect(stats.packetsLost, 3);
    expect(stats.packetsReceived, 297);
    expect(stats.audioLevelIn, closeTo(0.65, 0.001));
    expect(stats.sendLossPct, closeTo(1.0, 0.01));
  });

  test('stop() returns to idle and tears down the platform service',
      () async {
    final port = await freeTcpPort();
    final hostBridge = FakeNativeBridge();
    final hostEngine = IntercomEngine(
      settings: await testSettings(name: 'Host'),
      backend: FakeRtcBackend(),
      bridge: hostBridge,
      signalingPort: port,
    );

    await hostEngine.startHost();
    expect(hostEngine.state, IntercomState.waitingForPeer);
    expect(hostBridge.startServiceCalls, 1);

    await hostEngine.stop();
    expect(hostEngine.state, IntercomState.idle);
    expect(hostBridge.stopServiceCalls, 1);

    await hostEngine.dispose();
  });
}
