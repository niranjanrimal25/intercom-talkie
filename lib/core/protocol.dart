import 'dart:convert';

/// Wire protocol shared by the signaling server (hotspot host) and client.
///
/// All messages are single-line JSON objects terminated by `\n`.
/// Every object carries a `t` field with the message type.
class SignalMessage {
  SignalMessage(this.type, [Map<String, dynamic>? fields])
      : fields = fields ?? <String, dynamic>{};

  /// Message type, stored as `t` on the wire.
  final String type;

  /// Remaining payload fields (without `t`).
  final Map<String, dynamic> fields;

  dynamic operator [](String key) => fields[key];

  Map<String, dynamic> toMap() {
    return <String, dynamic>{'t': type, ...fields};
  }

  String encode() => jsonEncode(toMap());

  static SignalMessage decode(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map) {
      throw const FormatException('signal message is not an object');
    }
    final map = Map<String, dynamic>.from(decoded);
    final type = map.remove('t');
    if (type is! String || type.isEmpty) {
      throw const FormatException('signal message missing type');
    }
    return SignalMessage(type, map);
  }

  // ---------------------------------------------------------------------
  // Typed constructors.
  // ---------------------------------------------------------------------

  factory SignalMessage.hello({
    required String name,
    required String role,
    required String code,
    required String sessionId,
  }) {
    return SignalMessage('hello', <String, dynamic>{
      'name': name,
      'role': role,
      'code': code,
      'sessionId': sessionId,
    });
  }

  factory SignalMessage.welcome({required String name}) {
    return SignalMessage('welcome', <String, dynamic>{'name': name});
  }

  factory SignalMessage.busy() => SignalMessage('busy');

  factory SignalMessage.error(String reason) =>
      SignalMessage('error', <String, dynamic>{'reason': reason});

  factory SignalMessage.offer({required String sdp}) =>
      SignalMessage('offer', <String, dynamic>{'sdp': sdp});

  factory SignalMessage.answer({required String sdp}) =>
      SignalMessage('answer', <String, dynamic>{'sdp': sdp});

  factory SignalMessage.ice({
    required String? candidate,
    required String? sdpMid,
    required int? sdpMLineIndex,
  }) {
    return SignalMessage('ice', <String, dynamic>{
      'candidate': candidate,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  factory SignalMessage.ping() => SignalMessage('ping');

  factory SignalMessage.pong() => SignalMessage('pong');

  /// Tells the peer whether our microphone is currently open.
  factory SignalMessage.mute({required bool muted}) =>
      SignalMessage('mute', <String, dynamic>{'muted': muted});

  factory SignalMessage.bye({String reason = 'user'}) =>
      SignalMessage('bye', <String, dynamic>{'reason': reason});
}

/// Encodes/decodes the newline-framed message stream.
class ProtocolCodec {
  static const int maxLineLength = 512 * 1024;

  static String frame(SignalMessage message) => '${message.encode()}\n';

  static List<int> frameBytes(SignalMessage message) =>
      utf8.encode(frame(message));

  static SignalMessage parseLine(String line) => SignalMessage.decode(line);
}

/// Accumulates byte chunks from a socket and extracts complete lines.
class MessageFramer {
  final List<int> _buffer = <int>[];
  int _scanFrom = 0;

  /// Feeds [data] and returns all fully received messages, in order.
  ///
  /// Malformed lines are skipped (never thrown) so one bad packet cannot
  /// take down the link. Oversized lines abort the connection by throwing
  /// [FormatException].
  List<SignalMessage> push(List<int> data) {
    _buffer.addAll(data);
    final messages = <SignalMessage>[];
    while (true) {
      final newlineIndex = _indexOfNewline(_scanFrom);
      if (newlineIndex < 0) {
        _scanFrom = _buffer.length;
        if (_buffer.length > ProtocolCodec.maxLineLength) {
          throw const FormatException('signaling line too long');
        }
        break;
      }
      final line = utf8.decode(_buffer.sublist(0, newlineIndex),
          allowMalformed: true);
      _buffer.removeRange(0, newlineIndex + 1);
      _scanFrom = 0;
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        messages.add(ProtocolCodec.parseLine(trimmed));
      } on FormatException {
        // Skip malformed lines; log upstream if needed.
      } catch (_) {
        // Bad JSON payload — ignore.
      }
    }
    return messages;
  }

  int _indexOfNewline(int from) {
    for (var i = from; i < _buffer.length; i++) {
      if (_buffer[i] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  void reset() {
    _buffer.clear();
    _scanFrom = 0;
  }
}
