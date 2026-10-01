import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/app_log.dart';

/// Transport-agnostic description of an SDP offer/answer.
class RtcDescription {
  const RtcDescription({required this.type, required this.sdp});

  final String type; // 'offer' | 'answer'
  final String sdp;
}

/// Transport-agnostic ICE candidate.
class RtcCandidate {
  const RtcCandidate({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  final String? candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

/// Handle to an audio track (local or remote) supporting enable/disable.
abstract class RtcAudioTrack {
  String get id;
  bool get enabled;
  Future<void> setEnabled(bool value);
}

/// Handle to a WebRTC peer connection.
abstract class RtcPeer {
  /// ICE connection states delivered as plain strings:
  /// new | checking | connected | completed | failed | disconnected | closed
  void setOnIceConnectionState(void Function(String state) callback);
  void setOnIceCandidate(void Function(RtcCandidate candidate) callback);
  void setOnRemoteAudioTrack(void Function(RtcAudioTrack track) callback);

  Future<RtcDescription> createOffer();
  Future<RtcDescription> createAnswer();
  Future<void> setLocalDescription(RtcDescription description);
  Future<void> setRemoteDescription(RtcDescription description);
  Future<void> addIceCandidate(RtcCandidate candidate);
  Future<List<Map<String, dynamic>>> getStats();
  Future<void> close();
}

/// Handle to the open microphone (local capture).
abstract class RtcMicrophone {
  RtcAudioTrack? get track;
  Future<void> close();
}

/// Factory abstraction over the WebRTC stack. The engine depends only on
/// this interface, which keeps it unit-testable with fakes.
abstract class RtcBackend {
  /// Applies platform audio configuration for a voice-communication session
  /// (communication mode on Android, playAndRecord + Bluetooth HFP on iOS).
  Future<void> prepareAudioSession();

  /// Opens the microphone with echo cancellation enabled.
  Future<RtcMicrophone> openMicrophone();

  /// Creates a peer connection configured for direct local connections
  /// (no STUN/TURN servers — everything happens on the hotspot LAN).
  ///
  /// The microphone's audio track is attached to the new peer connection
  /// before the SDP offer/answer is created.
  Future<RtcPeer> createPeer(RtcMicrophone microphone);

  /// Mutes or unmutes the microphone at the audio-device level.
  Future<void> muteMicrophone(bool muted);

  /// Toggles speakerphone (false = prefer Bluetooth headset/earpiece).
  Future<void> setSpeakerphone(bool enabled);

  /// Re-asserts the audio session/routing (used after phone-call
  /// interruptions to recover audio).
  Future<void> recoverAudioSession();
}

/// Production backend backed by `flutter_webrtc`.
class WebRtcBackend implements RtcBackend {
  @override
  Future<void> prepareAudioSession() async {
    try {
      if (Platform.isAndroid) {
        await AndroidNativeAudioManagement.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
      } else if (Platform.isIOS) {
        await AppleNativeAudioManagement.setAppleAudioConfiguration(
          AppleAudioConfiguration(
            appleAudioCategory: AppleAudioCategory.playAndRecord,
            appleAudioCategoryOptions: {
              AppleAudioCategoryOption.allowBluetooth,
              AppleAudioCategoryOption.mixWithOthers,
            },
            appleAudioMode: AppleAudioMode.voiceChat,
          ),
        );
        await NativeAudioManagement.ensureAudioSession();
      }
    } catch (error) {
      AppLog.instance
          .w('rtc', 'prepareAudioSession failed (continuing): $error');
    }
  }

  @override
  Future<RtcMicrophone> openMicrophone() async {
    final stream = await navigator.mediaDevices.getUserMedia(
      <String, dynamic>{'audio': true, 'video': false},
    );
    final tracks = stream.getAudioTracks();
    if (tracks.isEmpty) {
      await stream.dispose();
      throw StateError('getUserMedia returned no audio track');
    }
    return _WebRtcMicrophone(stream, tracks.first);
  }

  @override
  Future<RtcPeer> createPeer(RtcMicrophone microphone) async {
    final configuration = <String, dynamic>{
      'iceServers': <dynamic>[],
      'sdpSemantics': 'unified-plan',
    };
    final peerConnection = await createPeerConnection(configuration);
    final nativeMic = microphone as _WebRtcMicrophone;
    await peerConnection.addTrack(nativeMic._track, nativeMic._stream);
    return _WebRtcPeer(peerConnection);
  }

  @override
  Future<void> muteMicrophone(bool muted) async {
    try {
      await NativeAudioManagement.setMicrophoneMuted(muted);
    } catch (error) {
      AppLog.instance.w('rtc', 'setMicrophoneMuted failed: $error');
    }
  }

  @override
  Future<void> setSpeakerphone(bool enabled) async {
    try {
      await NativeAudioManagement.setSpeakerphoneOn(enabled);
    } catch (error) {
      AppLog.instance.w('rtc', 'setSpeakerphoneOn failed: $error');
    }
  }

  @override
  Future<void> recoverAudioSession() async {
    try {
      if (Platform.isIOS) {
        await NativeAudioManagement.ensureAudioSession();
      }
      // Android recovery is handled by the native bridge (audio mode +
      // communication device + focus re-request).
    } catch (error) {
      AppLog.instance.w('rtc', 'recoverAudioSession failed: $error');
    }
  }
}

class _WebRtcMicrophone implements RtcMicrophone {
  _WebRtcMicrophone(this._stream, this._track);

  final MediaStream _stream;
  final MediaStreamTrack _track;
  bool _closed = false;

  @override
  RtcAudioTrack get track => _WebRtcAudioTrack(_track);

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _track.stop();
    } catch (_) {
      // Ignore.
    }
    try {
      await _stream.dispose();
    } catch (_) {
      // Ignore.
    }
  }
}

class _WebRtcAudioTrack implements RtcAudioTrack {
  _WebRtcAudioTrack(this._track);

  final MediaStreamTrack _track;

  @override
  String get id => _track.id ?? '';

  @override
  bool get enabled => _track.enabled;

  @override
  Future<void> setEnabled(bool value) async {
    _track.enabled = value;
  }
}

class _WebRtcPeer implements RtcPeer {
  _WebRtcPeer(this._peer);

  final RTCPeerConnection _peer;
  bool _closed = false;

  void Function(String state)? _iceStateCallback;
  void Function(RtcCandidate candidate)? _candidateCallback;
  void Function(RtcAudioTrack track)? _trackCallback;

  void _wire() {
    _peer.onIceConnectionState = (state) {
      _iceStateCallback?.call(_iceStateName(state));
    };
    _peer.onIceCandidate = (candidate) {
      _candidateCallback?.call(RtcCandidate(
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      ));
    };
    _peer.onTrack = (event) {
      if (event.track.kind == 'audio') {
        _trackCallback?.call(_WebRtcAudioTrack(event.track));
      }
    };
  }

  static String _iceStateName(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateNew:
        return 'new';
      case RTCIceConnectionState.RTCIceConnectionStateChecking:
        return 'checking';
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
        return 'connected';
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        return 'completed';
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
        return 'failed';
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        return 'disconnected';
      case RTCIceConnectionState.RTCIceConnectionStateClosed:
        return 'closed';
      case RTCIceConnectionState.RTCIceConnectionStateCount:
        return 'new';
    }
  }

  @override
  void setOnIceConnectionState(void Function(String state) callback) {
    _iceStateCallback = callback;
    _wire();
  }

  @override
  void setOnIceCandidate(void Function(RtcCandidate candidate) callback) {
    _candidateCallback = callback;
    _wire();
  }

  @override
  void setOnRemoteAudioTrack(void Function(RtcAudioTrack track) callback) {
    _trackCallback = callback;
    _wire();
  }

  @override
  Future<RtcDescription> createOffer() async {
    final description = await _peer.createOffer(const <String, dynamic>{});
    return _toDescription(description);
  }

  @override
  Future<RtcDescription> createAnswer() async {
    final description = await _peer.createAnswer(const <String, dynamic>{});
    return _toDescription(description);
  }

  @override
  Future<void> setLocalDescription(RtcDescription description) async {
    await _peer.setLocalDescription(
      RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> setRemoteDescription(RtcDescription description) async {
    await _peer.setRemoteDescription(
      RTCSessionDescription(description.sdp, description.type),
    );
  }

  @override
  Future<void> addIceCandidate(RtcCandidate candidate) async {
    await _peer.addCandidate(
      RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getStats() async {
    final reports = await _peer.getStats();
    return reports
        .map((report) => Map<String, dynamic>.from(report.values))
        .toList(growable: false);
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _peer.close();
    } catch (_) {
      // Ignore.
    }
  }
}
