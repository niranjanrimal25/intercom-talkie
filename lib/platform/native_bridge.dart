import 'dart:async';

import 'package:flutter/services.dart';

import '../core/app_log.dart';

/// Events pushed from the native side (Kotlin/Swift) to Dart.
class NativeEvent {
  const NativeEvent(this.type, [this.data]);

  /// One of:
  ///  * interruptionBegan  — a phone call / Siri took over audio
  ///  * interruptionEnded  — the interruption is over (data: 'resume' when the
  ///                         system says we may resume automatically)
  ///  * focusLoss          — Android: audio focus lost (data: 'transient'
  ///                         or 'permanent')
  ///  * focusGain          — Android: audio focus returned
  ///  * routeChanged       — audio output route changed (data: description)
  ///  * serviceStopped     — user tapped "Stop" on the Android notification
  ///  * mediaServicesReset — iOS: media server crashed, audio must restart
  final String type;
  final String? data;
}

/// An audio route (Bluetooth intercom, wired headset, speaker, earpiece...).
class AudioRoute {
  const AudioRoute({
    required this.id,
    required this.name,
    required this.type,
    required this.selected,
  });

  final String id;
  final String name;

  /// bluetooth | wired | speaker | earpiece | builtin
  final String type;
  final bool selected;

  static AudioRoute fromMap(Map<Object?, Object?> map) {
    return AudioRoute(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      type: map['type'] as String? ?? 'unknown',
      selected: map['selected'] as bool? ?? false,
    );
  }

  String describeType() {
    switch (type) {
      case 'bluetooth':
        return 'Bluetooth';
      case 'wired':
        return 'Wired';
      case 'speaker':
        return 'Speaker';
      case 'earpiece':
        return 'Earpiece';
      case 'builtin':
        return 'Built-in';
      default:
        return type;
    }
  }
}

/// Thin wrapper around the custom `intercom.native` platform channel that
/// both Android (Kotlin) and iOS (Swift) implement.
class NativeBridge {
  static const MethodChannel _methods = MethodChannel('intercom.native');
  static const EventChannel _events = EventChannel('intercom.native/events');

  StreamSubscription<dynamic>? _subscription;
  void Function(NativeEvent event)? onEvent;

  /// Starts listening to native events. Safe to call multiple times.
  void start() {
    _subscription ??= _events
        .receiveBroadcastStream()
        .listen(_handleEvent, onError: (Object error) {
      AppLog.instance.w('native', 'event channel error: $error');
    });
  }

  void _handleEvent(dynamic raw) {
    if (raw is! Map) {
      return;
    }
    final type = raw['type'];
    if (type is! String) {
      return;
    }
    final data = raw['data'];
    AppLog.instance.d('native', 'event: $type ${data ?? ''}');
    onEvent?.call(NativeEvent(type, data is String ? data : null));
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    onEvent = null;
  }

  // -------------------------------------------------------------------
  // Foreground service (Android; no-op on iOS).
  // -------------------------------------------------------------------

  Future<void> startForegroundService({
    required String title,
    required String text,
  }) async {
    await _invoke('startService', <String, dynamic>{
      'title': title,
      'text': text,
    });
  }

  Future<void> updateForegroundService({required String text}) async {
    await _invoke('updateService', <String, dynamic>{'text': text});
  }

  Future<void> stopForegroundService() async {
    await _tryInvoke('stopService');
  }

  // -------------------------------------------------------------------
  // Audio.
  // -------------------------------------------------------------------

  /// Re-asserts audio routing after a phone call:
  /// Android: MODE_IN_COMMUNICATION + communication device + focus.
  /// iOS: re-activates the audio session.
  Future<void> recoverAudio() async {
    await _tryInvoke('recoverAudio');
  }

  Future<List<AudioRoute>> getAudioRoutes() async {
    try {
      final result = await _methods.invokeMethod('getAudioRoutes');
      if (result is List) {
        return result
            .whereType<Map>()
            .map((map) =>
                AudioRoute.fromMap(Map<Object?, Object?>.from(map)))
            .toList(growable: false);
      }
    } catch (error) {
      AppLog.instance.w('native', 'getAudioRoutes failed: $error');
    }
    return const <AudioRoute>[];
  }

  Future<bool> setAudioRoute(String id) async {
    try {
      final result = await _methods
          .invokeMethod('setAudioRoute', <String, dynamic>{'id': id});
      return result is bool ? result : false;
    } catch (error) {
      AppLog.instance.w('native', 'setAudioRoute failed: $error');
      return false;
    }
  }

  // -------------------------------------------------------------------
  // Miscellaneous.
  // -------------------------------------------------------------------

  Future<void> setKeepScreenOn(bool enabled) async {
    await _tryInvoke('setKeepScreenOn', <String, dynamic>{'enabled': enabled});
  }

  Future<void> openHotspotSettings() async {
    await _tryInvoke('openHotspotSettings');
  }

  /// Android only: asks the user to exempt the app from battery
  /// optimization. Returns true when the request was shown.
  Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final result = await _methods
          .invokeMethod('requestIgnoreBatteryOptimizations');
      return result is bool ? result : false;
    } catch (error) {
      AppLog.instance.w('native', 'battery exemption failed: $error');
      return false;
    }
  }

  Future<Map<String, String>> platformInfo() async {
    try {
      final result = await _methods.invokeMethod('platformInfo');
      if (result is Map) {
        return result.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (_) {
      // Ignore — not critical.
    }
    return const <String, String>{};
  }

  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) {
    return _methods.invokeMethod(method, args);
  }

  Future<dynamic> _tryInvoke(String method, [Map<String, dynamic>? args]) {
    return _invoke(method, args).catchError((Object error) {
      AppLog.instance.w('native', '$method failed: $error');
      return null;
    });
  }
}
