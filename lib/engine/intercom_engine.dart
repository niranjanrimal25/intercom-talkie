import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../core/beacon.dart';
import '../core/net_utils.dart';
import '../core/protocol.dart';
import '../core/sdp_tools.dart';
import '../core/signaling.dart';
import '../platform/native_bridge.dart';
import 'rtc_backend.dart';
import 'settings.dart';

/// Which side of the hotspot this device is on.
enum IntercomRole { host, client }

/// High-level engine state exposed to the UI.
enum IntercomState {
  /// Nothing happening.
  idle,

  /// Setting up (binding sockets, permissions etc.).
  starting,

  /// Host: waiting for a client to join.
  waitingForPeer,

  /// Client: looking for the host (beacon/probing).
  discovering,

  /// Client: TCP + WebRTC handshake in progress.
  connecting,

  /// Live two-way audio session.
  connected,

  /// Temporarily muted because of a phone call or audio focus loss.
  /// Auto-resumes when the call ends.
  paused,

  /// Session was lost and the client is retrying automatically.
  reconnecting,

  /// Shutting down.
  stopping,
}

/// Snapshot of the link quality, refreshed from WebRTC stats.
class LinkStats {
  LinkStats();

  double? rttMs;
  double? jitterMs;
  int? packetsLost;
  int? packetsReceived;
  double? audioLevelIn; // 0..1, remote voice we receive
  double? audioLevelOut; // 0..1, our voice being sent
  double? sendKbps;
  double? recvKbps;
  double? sendLossPct;

  int _lastBytesSent = 0;
  double _lastSentTs = 0;
  int _lastBytesReceived = 0;
  double _lastRecvTs = 0;

  void update(List<Map<String, dynamic>> reports) {
    double? rtt;
    for (final report in reports) {
      if (report['type'] == 'candidate-pair' &&
          report['state'] == 'succeeded' &&
          report['currentRoundTripTime'] != null) {
        final value = _toDouble(report['currentRoundTripTime']);
        if (value != null) {
          if (report['selected'] == true) {
            rtt = value * 1000;
            break;
          }
          rtt ??= value * 1000;
        }
      }
    }
    rttMs = rtt;

    for (final report in reports) {
      final type = report['type'];
      if (type == 'inbound-rtp' && report['kind'] == 'audio') {
        final jitter = _toDouble(report['jitter']);
        jitterMs = jitter == null ? null : jitter * 1000;
        packetsLost = _toInt(report['packetsLost']);
        packetsReceived = _toInt(report['packetsReceived']);
        audioLevelIn = _toDouble(report['audioLevel']);
        final bytes = _toInt(report['bytesReceived']) ?? 0;
        final ts = _toDouble(report['timestamp']) ?? 0;
        if (_lastRecvTs > 0 && ts > _lastRecvTs && ts - _lastRecvTs < 30) {
          final kbps = (bytes - _lastBytesReceived) * 8 / (ts - _lastRecvTs) / 1000;
          if (kbps >= 0) {
            recvKbps = kbps;
          }
        }
        _lastBytesReceived = bytes;
        _lastRecvTs = ts;
        final lost = packetsLost ?? 0;
        final received = packetsReceived ?? 0;
        if (lost + received > 0) {
          sendLossPct = lost * 100.0 / (lost + received);
        }
      } else if (type == 'outbound-rtp' && report['kind'] == 'audio') {
        audioLevelOut = _toDouble(report['audioLevel']);
        final bytes = _toInt(report['bytesSent']) ?? 0;
        final ts = _toDouble(report['timestamp']) ?? 0;
        if (_lastSentTs > 0 && ts > _lastSentTs && ts - _lastSentTs < 30) {
          final kbps = (bytes - _lastBytesSent) * 8 / (ts - _lastSentTs) / 1000;
          if (kbps >= 0) {
            sendKbps = kbps;
          }
        }
        _lastBytesSent = bytes;
        _lastSentTs = ts;
      }
    }
  }

  static double? _toDouble(dynamic value) {
    if (value is double) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  static int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}

/// Bundles everything belonging to one live peer session.
class _Session {
  _Session(this.connection, this.epoch);

  final SignalConnection connection;
  final int epoch;

  RtcPeer? peer;
  RtcMicrophone? microphone;
  RtcAudioTrack? remoteTrack;

  final Completer<void> iceConnected = Completer<void>();
  final Completer<void> sessionEnd = Completer<void>();

  String iceState = 'new';
  bool ended = false;
  bool handshakeDone = false;
  Timer? iceWatchdog;
  Timer? disconnectedGrace;
}

/// Central orchestrator: signaling, WebRTC session, phone-call
/// interruption handling, keep-alive and auto-reconnect.
class IntercomEngine extends ChangeNotifier {
  IntercomEngine({
    required this.settings,
    RtcBackend? backend,
    NativeBridge? bridge,
    this.signalingPort = BeaconDefaults.tcpPort,
  })  : backend = backend ?? WebRtcBackend(),
        bridge = bridge ?? NativeBridge();

  final IntercomSettings settings;
  final RtcBackend backend;
  final NativeBridge bridge;

  /// TCP port used for signaling. Injectable so tests can avoid collisions.
  final int signalingPort;

  static const _tag = 'engine';

  // ----- Public observable state -----
  IntercomState state = IntercomState.idle;
  IntercomRole? role;
  String peerName = '';
  String? lastError;
  String connectingTarget = '';
  int reconnectAttempt = 0;
  bool peerMicMuted = false;
  Duration sessionDuration = Duration.zero;
  LinkStats stats = LinkStats();

  bool get micMuted => _micMutedByUser;
  bool get pttActive => _pttActive;
  bool get speakerOn => _speakerOn;
  bool get interrupted => _interrupted;
  bool get isLive =>
      state == IntercomState.connected || state == IntercomState.paused;

  bool _micMutedByUser = false;
  bool _pttActive = false;
  bool _speakerOn = false;
  bool _interrupted = false;

  // ----- Internals -----
  int _epoch = 0;
  bool _running = false;
  _Session? _session;
  SignalingServer? _server;
  BeaconBroadcaster? _beacon;

  Timer? _heartbeatTimer;
  Timer? _statsTimer;
  Timer? _durationTimer;
  Timer? _beaconStopWatchdog;

  DateTime _lastPongAt = DateTime.now();
  bool _lastNotifiedMicOpen = false;

  final List<SignalMessage> _pendingMessages = <SignalMessage>[];
  final List<_MessageWaiter> _waiters = <_MessageWaiter>[];

  String _sessionId = '';

  // -------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------

  /// Starts hosting: enables the hotspot device role. The other phone joins
  /// this device's hotspot and connects over the LAN.
  Future<void> startHost() async {
    if (_running) {
      await stop();
    }
    final epoch = ++_epoch;
    _running = true;
    _resetPublicState();
    role = IntercomRole.host;
    _sessionId = _newSessionId();
    _setState(IntercomState.starting);
    AppLog.instance.i(_tag, 'Starting HOST session ($_sessionId)');

    await _platformSetup();

    try {
      _server = await SignalingServer.bind(port: signalingPort);
      AppLog.instance
          .i(_tag, 'Signaling server listening on port ${_server!.port}');
    } catch (error) {
      await _handleFatal('Could not start signaling server: $error');
      return;
    }

    _beacon = BeaconBroadcaster();
    final displayName = _displayName();
    await _beacon!.start(hostName: displayName, tcpPort: _server!.port);
    AppLog.instance.i(_tag, 'Beacon broadcasting as "$displayName"');

    unawaited(_runHostLoop(epoch));
  }

  /// Starts the client role: joins an existing hotspot.
  ///
  /// When [manualHost] is provided, only that address is tried (manual entry
  /// in the UI). Otherwise the engine discovers the host via UDP beacon and
  /// gateway probing.
  Future<void> startClient({String? manualHost}) async {
    if (_running) {
      await stop();
    }
    final epoch = ++_epoch;
    _running = true;
    _resetPublicState();
    role = IntercomRole.client;
    _sessionId = _newSessionId();
    _setState(IntercomState.discovering);
    AppLog.instance.i(_tag, 'Starting CLIENT session ($_sessionId)');

    await _platformSetup();

    if (manualHost != null && manualHost.isNotEmpty) {
      connectingTarget = manualHost;
      unawaited(_runClientLoop(epoch, preferredHost: manualHost));
      return;
    }
    unawaited(_runClientLoop(epoch));
  }

  /// Fully stops everything and returns to idle.
  Future<void> stop() async {
    if (!_running && state == IntercomState.idle) {
      return;
    }
    AppLog.instance.i(_tag, 'Stopping session');
    _epoch++;
    _running = false;
    _setState(IntercomState.stopping);
    await _teardownAll();
    _setState(IntercomState.idle);
    notifyListeners();
  }

  @override
  void dispose() {
    _epoch++;
    _running = false;
    _teardownAll();
    bridge.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // User controls
  // -------------------------------------------------------------------

  void setMicMuted(bool muted) {
    if (_micMutedByUser == muted) {
      return;
    }
    _micMutedByUser = muted;
    _applyAudioState();
  }

  void setPttActive(bool active) {
    if (_pttActive == active) {
      return;
    }
    _pttActive = active;
    _applyAudioState();
  }

  Future<void> setSpeakerOn(bool on) async {
    _speakerOn = on;
    notifyListeners();
    await backend.setSpeakerphone(on);
  }

  // -------------------------------------------------------------------
  // Host loop
  // -------------------------------------------------------------------

  Future<void> _runHostLoop(int epoch) async {
    while (_epoch == epoch && _running) {
      _setState(IntercomState.waitingForPeer);
      _updateServiceText();
      _startBeaconWatchdog(epoch);
      SignalConnection connection;
      try {
        connection = await _server!.acceptClient();
      } catch (error) {
        if (_epoch == epoch && _running) {
          AppLog.instance.e(_tag, 'acceptClient failed: $error');
        }
        return;
      }
      if (_epoch != epoch) {
        connection.close();
        return;
      }
      _cancelBeaconWatchdog();
      AppLog.instance.i(
          _tag, 'Client connecting from ${connection.label}');

      try {
        await _serveHostConnection(connection, epoch);
      } catch (error) {
        AppLog.instance.w(_tag, 'Host session error: $error');
        if (_epoch == epoch) {
          lastError = 'Session error: $error';
        }
      }
      _finalizeSession(epoch);
      if (_epoch != epoch) {
        return;
      }
      AppLog.instance.i(_tag, 'Waiting for next client...');
    }
  }

  Future<void> _serveHostConnection(
      SignalConnection connection, int epoch) async {
    final session = _Session(connection, epoch);
    _session = session;
    _bindConnection(session);

    // 1. Await hello.
    final hello = await _awaitMessage(
      const {'hello'},
      const Duration(seconds: 10),
    );
    final code = (hello['code'] as String? ?? '').trim();
    if (code != settings.passcode.trim()) {
      AppLog.instance.w(_tag, 'Passcode mismatch from ${connection.label}');
      connection.send(SignalMessage.error('badcode'));
      connection.close();
      throw _HandshakeException('passcode');
    }
    peerName = (hello['name'] as String? ?? '').trim();
    if (peerName.isEmpty) {
      peerName = 'Client';
    }
    AppLog.instance.i(_tag, 'Peer joined: "$peerName"');

    // 2. Welcome + prepare audio.
    connection.send(SignalMessage.welcome(name: _displayName()));
    await backend.prepareAudioSession();
    await _ensureMicrophone(session);

    // 3. Await the client's offer.
    final offer = await _awaitMessage(
      const {'offer'},
      const Duration(seconds: 15),
    );
    final offerSdp = offer['sdp'] as String? ?? '';
    if (offerSdp.isEmpty) {
      throw const _HandshakeException('empty offer');
    }

    // 4. Create the peer connection and answer.
    final peer = await backend.createPeer(session.microphone!);
    session.peer = peer;
    _bindPeer(session);

    await peer.setRemoteDescription(
      RtcDescription(type: 'offer', sdp: offerSdp),
    );
    final answer = await peer.createAnswer();
    final tunedAnswer = RtcDescription(
      type: 'answer',
      sdp: SdpTools.tuneOpus(
        answer.sdp,
        maxAverageBitrateBps: settings.opusBitrateBps,
        enableDtx: settings.enableDtx,
      ),
    );
    await peer.setLocalDescription(tunedAnswer);
    connection.send(SignalMessage.answer(sdp: tunedAnswer.sdp));
    session.handshakeDone = true;
    _lastPongAt = DateTime.now();
    _startHeartbeat(epoch);

    AppLog.instance.i(_tag, 'Answer sent; waiting for ICE...');

    // 5. Wait for ICE.
    session.iceWatchdog = Timer(const Duration(seconds: 25), () {
      if (!session.iceConnected.isCompleted) {
        AppLog.instance.w(_tag, 'ICE watchdog fired');
        session.iceConnected.completeError(TimeoutException('ice'));
      }
    });
    try {
      await session.iceConnected.future;
    } catch (_) {
      throw const _HandshakeException('ice-timeout');
    }
    _onSessionEstablished(session);

    // 6. Ride until the session dies.
    await session.sessionEnd.future;
  }

  // -------------------------------------------------------------------
  // Client loop
  // -------------------------------------------------------------------

  Future<void> _runClientLoop(int epoch, {String? preferredHost}) async {
    var backoff = const Duration(seconds: 1);
    final storedHost = settings.lastHostAddress;
    String? knownHost = preferredHost ?? (storedHost.isEmpty ? null : storedHost);

    while (_epoch == epoch && _running) {
      if (state != IntercomState.connecting &&
          state != IntercomState.discovering) {
        _setState(IntercomState.reconnecting);
        reconnectAttempt++;
        _updateServiceText();
      }

      // Build the target list.
      final targets = <String>[];
      if (knownHost != null) {
        targets.add(knownHost);
      }
      if (knownHost == null || reconnectAttempt > 0) {
        final discovered = await _discoverHostAddress(epoch);
        if (discovered != null && !targets.contains(discovered)) {
          targets.add(discovered);
        }
      }
      if (knownHost == null) {
        for (final candidate in await NetUtils.gatewayCandidates()) {
          if (!targets.contains(candidate)) {
            targets.add(candidate);
          }
        }
      }
      if (targets.isEmpty) {
        targets.addAll(await NetUtils.gatewayCandidates());
      }

      for (final target in targets) {
        if (_epoch != epoch) {
          return;
        }
        connectingTarget = target;
        AppLog.instance.d(_tag, 'Trying host $target...');
        try {
          final established = await _clientHandshake(target, epoch);
          if (established) {
            reconnectAttempt = 0;
            _onSessionEstablished(_session!);
            await _session!.sessionEnd.future;
            // Session ended — fall through to reconnect logic.
            if (_epoch != epoch) {
              return;
            }
            AppLog.instance.w(_tag, 'Session ended, reconnecting...');
          }
        } on _HandshakeException catch (error) {
          AppLog.instance.w(_tag, 'Handshake with $target failed: ${error.reason}');
          if (error.reason == 'badcode') {
            lastError =
                'Passcode rejected by host. Check the passcode in Settings.';
            await stop();
            return;
          }
        } catch (error) {
          AppLog.instance
              .d(_tag, 'Connect to $target failed: ${NetUtils.describeError(error)}');
        }
        _finalizeSession(epoch);
        if (_epoch != epoch) {
          return;
        }
      }

      if (!settings.autoReconnect) {
        lastError = 'Could not reach the host device.';
        await stop();
        return;
      }
      if (reconnectAttempt == 0) {
        reconnectAttempt = 1;
      }
      AppLog.instance.i(
          _tag, 'All targets failed; retrying in ${backoff.inMilliseconds}ms');
      await _sleep(backoff, epoch);
      if (_epoch != epoch) {
        return;
      }
      backoff = Duration(
          milliseconds: min(backoff.inMilliseconds * 2, 8000));
      // After the first failure drop the stale known host so discovery runs.
      if (knownHost != null && reconnectAttempt > 1) {
        knownHost = null;
      }
    }
  }

  /// Quick beacon listen used between reconnect attempts.
  Future<String?> _discoverHostAddress(int epoch) async {
    final listener = BeaconListener();
    try {
      await listener.start();
      final host = await listener.waitForBeacon(
        timeout: const Duration(milliseconds: 2500),
      );
      await listener.stop();
      if (host == null) {
        return null;
      }
      AppLog.instance
          .i(_tag, 'Beacon found: "${host.name}" @ ${host.address}');
      return host.address;
    } catch (error) {
      AppLog.instance
          .w(_tag, 'Beacon listener failed: ${NetUtils.describeError(error)}');
      try {
        await listener.stop();
      } catch (_) {
        // Ignore.
      }
      return null;
    }
  }

  Future<bool> _clientHandshake(String host, int epoch) async {
    final connection =
        await SignalingClient.connect(host,
            port: signalingPort, timeout: const Duration(seconds: 4));
    if (_epoch != epoch) {
      connection.close();
      return false;
    }
    final session = _Session(connection, epoch);
    _session = session;
    _bindConnection(session);

    _setState(IntercomState.connecting);
    _updateServiceText();

    connection.send(SignalMessage.hello(
      name: _displayName(),
      role: 'client',
      code: settings.passcode.trim(),
      sessionId: _sessionId,
    ));

    final reply = await _awaitMessage(
      const {'welcome', 'busy', 'error'},
      const Duration(seconds: 8),
    );
    if (reply.type == 'busy') {
      connection.close();
      throw const _HandshakeException('busy');
    }
    if (reply.type == 'error') {
      connection.close();
      throw const _HandshakeException('badcode');
    }
    peerName = (reply['name'] as String? ?? '').trim();
    if (peerName.isEmpty) {
      peerName = 'Host';
    }
    AppLog.instance.i(_tag, 'Host "$peerName" welcomed us');

    await backend.prepareAudioSession();
    await _ensureMicrophone(session);

    final peer = await backend.createPeer(session.microphone!);
    session.peer = peer;
    _bindPeer(session);

    final offer = await peer.createOffer();
    final tunedOffer = RtcDescription(
      type: 'offer',
      sdp: SdpTools.tuneOpus(
        offer.sdp,
        maxAverageBitrateBps: settings.opusBitrateBps,
        enableDtx: settings.enableDtx,
      ),
    );
    await peer.setLocalDescription(tunedOffer);
    connection.send(SignalMessage.offer(sdp: tunedOffer.sdp));

    final answer = await _awaitMessage(
      const {'answer'},
      const Duration(seconds: 12),
    );
    final answerSdp = answer['sdp'] as String? ?? '';
    if (answerSdp.isEmpty) {
      throw const _HandshakeException('empty answer');
    }
    await peer.setRemoteDescription(
      RtcDescription(type: 'answer', sdp: answerSdp),
    );

    session.handshakeDone = true;
    _lastPongAt = DateTime.now();
    _startHeartbeat(epoch);

    session.iceWatchdog = Timer(const Duration(seconds: 25), () {
      if (!session.iceConnected.isCompleted) {
        AppLog.instance.w(_tag, 'ICE watchdog fired');
        session.iceConnected.completeError(TimeoutException('ice'));
      }
    });
    try {
      await session.iceConnected.future;
    } catch (_) {
      throw const _HandshakeException('ice-timeout');
    }

    settings.lastHostAddress = host;
    unawaited(settings.save());
    return true;
  }

  // -------------------------------------------------------------------
  // Session plumbing
  // -------------------------------------------------------------------

  void _bindConnection(_Session session) {
    session.connection.onMessage = (message) => _onSignal(session, message);
    session.connection.onClosed = () => _onLinkClosed(session);
  }

  void _bindPeer(_Session session) {
    final peer = session.peer!;
    peer.setOnIceCandidate((candidate) {
      if (session.ended) {
        return;
      }
      session.connection.send(SignalMessage.ice(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ));
    });
    peer.setOnIceConnectionState((state) {
      session.iceState = state;
      AppLog.instance.d(_tag, 'ICE state: $state');
      if (state == 'connected' || state == 'completed') {
        if (!session.iceConnected.isCompleted) {
          session.iceConnected.complete();
        }
        session.disconnectedGrace?.cancel();
        session.disconnectedGrace = null;
      } else if (state == 'failed') {
        if (!session.iceConnected.isCompleted) {
          session.iceConnected.completeError(StateError('ice failed'));
        }
        _endSession(session, 'ICE failed');
      } else if (state == 'disconnected') {
        session.disconnectedGrace?.cancel();
        session.disconnectedGrace = Timer(const Duration(seconds: 6), () {
          if (!session.ended &&
              (session.iceState == 'disconnected' ||
                  session.iceState == 'failed')) {
            _endSession(session, 'ICE disconnected too long');
          }
        });
      }
    });
    peer.setOnRemoteAudioTrack((track) {
      AppLog.instance.i(_tag, 'Remote audio track attached');
      session.remoteTrack = track;
      _applyAudioState();
    });
  }

  void _onSignal(_Session session, SignalMessage message) {
    if (_session != session || session.ended) {
      return;
    }
    switch (message.type) {
      case 'ice':
        final candidate = RtcCandidate(
          candidate: message['candidate'] as String?,
          sdpMid: message['sdpMid'] as String?,
          sdpMLineIndex: message['sdpMLineIndex'] as int?,
        );
        session.peer?.addIceCandidate(candidate).catchError((Object error) {
          AppLog.instance
              .d(_tag, 'addIceCandidate ignored: ${NetUtils.describeError(error)}');
        });
        break;
      case 'ping':
        session.connection.send(SignalMessage.pong());
        break;
      case 'pong':
        _lastPongAt = DateTime.now();
        break;
      case 'mute':
        final muted = message['muted'] == true;
        if (peerMicMuted != muted) {
          peerMicMuted = muted;
          notifyListeners();
        }
        break;
      case 'bye':
        AppLog.instance.i(_tag, 'Peer said bye: ${message['reason'] ?? ''}');
        _endSession(session, 'peer left');
        break;
      default:
        break;
    }
    _dispatchToWaiters(message);
  }

  void _onLinkClosed(_Session session) {
    if (_session != session) {
      return;
    }
    AppLog.instance.w(_tag, 'Signaling link closed');
    _endSession(session, 'link closed');
  }

  void _onSessionEstablished(_Session session) {
    session.iceWatchdog?.cancel();
    _lastNotifiedMicOpen = false; // re-announce mic state to the new peer
    if (!_interrupted) {
      _setState(IntercomState.connected);
    } else {
      _setState(IntercomState.paused);
    }
    sessionDuration = Duration.zero;
    _startSessionTimers();
    _applyAudioState();
    _updateServiceText();
    AppLog.instance.i(_tag, 'Session established with "$peerName"');
    if (role == IntercomRole.host) {
      unawaited(_beacon?.stop());
    }
  }

  void _endSession(_Session session, String reason) {
    if (session.ended) {
      return;
    }
    session.ended = true;
    AppLog.instance.w(_tag, 'Ending session: $reason');
    session.iceWatchdog?.cancel();
    session.disconnectedGrace?.cancel();
    if (!session.iceConnected.isCompleted) {
      session.iceConnected.completeError(StateError(reason));
    }
    _stopSessionTimers();
    session.connection.close();
    session.peer?.close();
    session.microphone?.close();
    _failWaiters('session ended: $reason');
    if (_session == session) {
      _session = null;
      peerName = '';
      peerMicMuted = false;
    }
    if (role == IntercomRole.host && _running && _epoch == session.epoch) {
      _server?.releaseActive();
    }
    if (!session.sessionEnd.isCompleted) {
      session.sessionEnd.complete();
    }
    notifyListeners();
  }

  Future<void> _ensureMicrophone(_Session session) async {
    if (session.microphone == null) {
      session.microphone = await backend.openMicrophone();
      AppLog.instance.i(_tag, 'Microphone opened');
    }
  }

  // -------------------------------------------------------------------
  // Message waiters (handshake sequencing)
  // -------------------------------------------------------------------

  Future<SignalMessage> _awaitMessage(Set<String> types, Duration timeout) {
    for (var i = 0; i < _pendingMessages.length; i++) {
      final message = _pendingMessages[i];
      if (types.contains(message.type)) {
        _pendingMessages.removeAt(i);
        return Future.value(message);
      }
    }
    final waiter = _MessageWaiter(types, timeout);
    _waiters.add(waiter);
    return waiter.completer.future;
  }

  void _dispatchToWaiters(SignalMessage message) {
    for (var i = 0; i < _waiters.length; i++) {
      final waiter = _waiters[i];
      if (waiter.types.contains(message.type)) {
        _waiters.removeAt(i);
        waiter.dispose();
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(message);
        }
        return;
      }
    }
    if (message.type != 'ice' &&
        message.type != 'ping' &&
        message.type != 'pong') {
      _pendingMessages.add(message);
      if (_pendingMessages.length > 40) {
        _pendingMessages.removeRange(0, _pendingMessages.length - 40);
      }
    }
  }

  void _failWaiters(String reason) {
    for (final waiter in _waiters) {
      waiter.dispose();
      if (!waiter.completer.isCompleted) {
        waiter.completer
            .completeError(StateError(reason));
      }
    }
    _waiters.clear();
    _pendingMessages.clear();
  }

  /// Ends the current session if it belongs to [epoch] and somehow survived
  /// a failed handshake (e.g. an exception between steps).
  void _finalizeSession(int epoch) {
    final session = _session;
    if (session != null && session.epoch == epoch && !session.ended) {
      _endSession(session, 'handshake finished');
    }
  }

  // -------------------------------------------------------------------
  // Timers
  // -------------------------------------------------------------------

  void _startHeartbeat(int epoch) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      final session = _session;
      if (_epoch != epoch || session == null || session.ended) {
        timer.cancel();
        return;
      }
      final silence = DateTime.now().difference(_lastPongAt);
      if (silence.inMilliseconds > 10000) {
        AppLog.instance.w(_tag,
            'Heartbeat timeout (${silence.inSeconds}s silent) — dropping link');
        _endSession(session, 'heartbeat timeout');
        return;
      }
      session.connection.send(SignalMessage.ping());
    });
  }

  void _startSessionTimers() {
    _stopSessionTimers();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isLive) {
        sessionDuration += const Duration(seconds: 1);
        notifyListeners();
      }
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final session = _session;
      if (session == null || session.peer == null || !isLive) {
        return;
      }
      try {
        final reports = await session.peer!.getStats();
        stats.update(reports);
        notifyListeners();
      } catch (_) {
        // Stats are best-effort.
      }
    });
  }

  void _stopSessionTimers() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startBeaconWatchdog(int epoch) {
    // The host keeps the beacon running while waiting; if it was stopped
    // after a session, restart it.
    _beaconStopWatchdog?.cancel();
    _beaconStopWatchdog = Timer(const Duration(milliseconds: 500), () {
      if (_epoch == epoch &&
          _running &&
          role == IntercomRole.host &&
          _beacon != null &&
          !_beacon!.isRunning &&
          state == IntercomState.waitingForPeer) {
        _beacon!
            .start(hostName: _displayName(), tcpPort: _server!.port)
            .catchError((Object error) {
          AppLog.instance.w(_tag, 'Beacon restart failed: $error');
        });
      }
    });
  }

  void _cancelBeaconWatchdog() {
    _beaconStopWatchdog?.cancel();
    _beaconStopWatchdog = null;
  }

  Future<void> _sleep(Duration duration, int epoch) {
    final completer = Completer<void>();
    Timer(duration, () => completer.complete());
    return completer.future;
  }

  // -------------------------------------------------------------------
  // Audio state application (mute / PTT / interruption)
  // -------------------------------------------------------------------

  void _applyAudioState({bool restartMic = false}) {
    final session = _session;
    final live = isLive;
    final effectiveMicOpen = live &&
        !_micMutedByUser &&
        !_interrupted &&
        (!settings.pushToTalk || _pttActive);

    if (session == null) {
      notifyListeners();
      return;
    }

    final micTrack = session.microphone?.track;
    if (restartMic && micTrack != null) {
      // Force the audio device to restart capture by toggling the track.
      micTrack.setEnabled(false);
    }
    micTrack?.setEnabled(effectiveMicOpen);
    unawaited(backend.muteMicrophone(!effectiveMicOpen));
    session.remoteTrack?.setEnabled(!_interrupted);

    if (_lastNotifiedMicOpen != effectiveMicOpen) {
      _lastNotifiedMicOpen = effectiveMicOpen;
      session.connection.send(SignalMessage.mute(muted: !effectiveMicOpen));
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // Native events (phone calls, focus, routes)
  // -------------------------------------------------------------------

  void handleNativeEvent(NativeEvent event) {
    switch (event.type) {
      case 'interruptionBegan':
      case 'focusLoss':
        _onCallInterruptionBegan();
        break;
      case 'interruptionEnded':
      case 'focusGain':
        _onCallInterruptionEnded();
        break;
      case 'routeChanged':
        AppLog.instance.i(_tag, 'Audio route changed: ${event.data ?? '?'}');
        break;
      case 'serviceStopped':
        unawaited(stop());
        break;
      case 'mediaServicesReset':
        AppLog.instance.w(_tag, 'Media services reset — recovering audio');
        unawaited(backend.recoverAudioSession());
        _applyAudioState(restartMic: true);
        break;
      default:
        break;
    }
  }

  void _onCallInterruptionBegan() {
    if (!isLive || _interrupted) {
      return;
    }
    _interrupted = true;
    AppLog.instance
        .w(_tag, 'Audio interruption began (phone call?) — pausing audio');
    _setState(IntercomState.paused);
    _applyAudioState();
    _updateServiceText();
  }

  void _onCallInterruptionEnded() {
    if (!_interrupted) {
      return;
    }
    _interrupted = false;
    AppLog.instance.i(_tag, 'Interruption ended — resuming audio');
    unawaited(bridge.recoverAudio());
    unawaited(backend.recoverAudioSession());
    if (state == IntercomState.paused) {
      _setState(IntercomState.connected);
    }
    _applyAudioState(restartMic: true);
    _updateServiceText();
  }

  // -------------------------------------------------------------------
  // Platform helpers
  // -------------------------------------------------------------------

  Future<void> _platformSetup() async {
    bridge.start();
    bridge.onEvent = handleNativeEvent;
    _lastNotifiedMicOpen = false;
    await bridge.startForegroundService(
      title: 'Intercom Talkie',
      text: _serviceText(),
    );
    await bridge.setKeepScreenOn(settings.keepScreenOn);
    _micMutedByUser = false;
    _pttActive = false;
    _interrupted = false;
  }

  String _serviceText() {
    switch (state) {
      case IntercomState.idle:
        return 'Idle';
      case IntercomState.starting:
        return 'Starting…';
      case IntercomState.waitingForPeer:
        return 'Waiting for the other phone to join…';
      case IntercomState.discovering:
        return 'Looking for the host phone…';
      case IntercomState.connecting:
        return 'Connecting…';
      case IntercomState.connected:
        return 'Live with $peerName';
      case IntercomState.paused:
        return 'Paused — phone call in progress';
      case IntercomState.reconnecting:
        return 'Reconnecting…';
      case IntercomState.stopping:
        return 'Stopping…';
    }
  }

  void _updateServiceText() {
    unawaited(bridge.updateForegroundService(text: _serviceText()));
  }

  String _displayName() {
    final name = settings.deviceName.trim();
    return name.isEmpty ? defaultDeviceName : name;
  }

  Future<void> _handleFatal(String message) async {
    AppLog.instance.e(_tag, message);
    lastError = message;
    _epoch++;
    _running = false;
    await _teardownAll();
    _setState(IntercomState.idle);
  }

  Future<void> _teardownAll() async {
    _stopSessionTimers();
    _cancelBeaconWatchdog();
    _failWaiters('engine stopping');
    final session = _session;
    _session = null;
    if (session != null && !session.ended) {
      session.connection.send(SignalMessage.bye());
      session.ended = true;
      session.connection.close();
      session.peer?.close();
      session.microphone?.close();
      if (!session.sessionEnd.isCompleted) {
        session.sessionEnd.complete();
      }
    }
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {
        // Ignore.
      }
    }
    await _beacon?.stop();
    _beacon = null;
    await bridge.stopForegroundService();
    await bridge.setKeepScreenOn(false);
    peerName = '';
    peerMicMuted = false;
    connectingTarget = '';
    reconnectAttempt = 0;
    sessionDuration = Duration.zero;
    stats = LinkStats();
    _interrupted = false;
  }

  void _setState(IntercomState next) {
    if (state == next) {
      return;
    }
    state = next;
    AppLog.instance.d(_tag, 'State → ${next.name}');
    notifyListeners();
  }

  void _resetPublicState() {
    lastError = null;
    peerName = '';
    peerMicMuted = false;
    sessionDuration = Duration.zero;
    reconnectAttempt = 0;
    stats = LinkStats();
  }

  static String _newSessionId() {
    final random = Random();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Default device name until the user sets one.
  static String defaultDeviceName = 'Intercom';
}

class _MessageWaiter {
  _MessageWaiter(this.types, Duration timeout) {
    _timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
            TimeoutException('Timed out waiting for ${types.join('/')}'));
      }
    });
  }

  final Set<String> types;
  final Completer<SignalMessage> completer = Completer<SignalMessage>();
  late final Timer _timer;

  void dispose() {
    _timer.cancel();
  }
}

class _HandshakeException implements Exception {
  const _HandshakeException(this.reason);
  final String reason;

  @override
  String toString() => 'HandshakeException($reason)';
}
