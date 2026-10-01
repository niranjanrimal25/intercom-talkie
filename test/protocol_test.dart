import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/core/protocol.dart';

void main() {
  group('SignalMessage', () {
    test('hello round-trips through JSON', () {
      final message = SignalMessage.hello(
        name: 'Pixel 7',
        role: 'client',
        code: '1234',
        sessionId: 'abcd',
      );
      final decoded = SignalMessage.decode(message.encode());
      expect(decoded.type, 'hello');
      expect(decoded['name'], 'Pixel 7');
      expect(decoded['role'], 'client');
      expect(decoded['code'], '1234');
      expect(decoded['sessionId'], 'abcd');
    });

    test('offer carries sdp', () {
      final message = SignalMessage.offer(sdp: 'v=0\r\noffer-body');
      final decoded = SignalMessage.decode(message.encode());
      expect(decoded.type, 'offer');
      expect(decoded['sdp'], 'v=0\r\noffer-body');
    });

    test('ice candidate round-trips with null fields', () {
      final message =
          SignalMessage.ice(candidate: null, sdpMid: null, sdpMLineIndex: 0);
      final decoded = SignalMessage.decode(message.encode());
      expect(decoded.type, 'ice');
      expect(decoded['candidate'], isNull);
      expect(decoded['sdpMid'], isNull);
      expect(decoded['sdpMLineIndex'], 0);
    });

    test('mute message', () {
      final decoded =
          SignalMessage.decode(SignalMessage.mute(muted: true).encode());
      expect(decoded['muted'], true);
    });

    test('rejects non-object JSON', () {
      expect(() => SignalMessage.decode('[1,2,3]'), throwsFormatException);
    });

    test('rejects missing type', () {
      expect(
        () => SignalMessage.decode(jsonEncode({'name': 'x'})),
        throwsFormatException,
      );
    });

    test('rejects non-JSON', () {
      expect(() => SignalMessage.decode('not json'), throwsFormatException);
    });
  });

  group('MessageFramer', () {
    test('frames a single message', () {
      final framer = MessageFramer();
      final bytes =
          utf8.encode('${SignalMessage.ping().encode()}\n');
      final messages = framer.push(bytes);
      expect(messages.length, 1);
      expect(messages.first.type, 'ping');
    });

    test('handles messages split across chunks', () {
      final framer = MessageFramer();
      final full =
          utf8.encode('${SignalMessage.pong().encode()}\n${SignalMessage.busy().encode()}\n');
      final first = framer.push(full.sublist(0, 5));
      expect(first, isEmpty);
      final second = framer.push(full.sublist(5, 20));
      expect(second.length, 1);
      final third = framer.push(full.sublist(20));
      expect(third.length, 1);
      expect(second.first.type, 'pong');
      expect(third.first.type, 'busy');
    });

    test('handles several messages in one chunk', () {
      final framer = MessageFramer();
      final payload = utf8.encode(
          '${SignalMessage.ping().encode()}\n${SignalMessage.ping().encode()}\n');
      final messages = framer.push(payload);
      expect(messages.length, 2);
    });

    test('skips malformed lines but keeps good ones', () {
      final framer = MessageFramer();
      final payload = utf8.encode('garbage\n${SignalMessage.ping().encode()}\n');
      final messages = framer.push(payload);
      expect(messages.length, 1);
      expect(messages.first.type, 'ping');
    });

    test('throws on oversized lines', () {
      final framer = MessageFramer();
      expect(
        () => framer.push(List<int>.filled(600 * 1024, 0x61)),
        throwsFormatException,
      );
    });

    test('ignores empty lines', () {
      final framer = MessageFramer();
      final messages =
          framer.push(utf8.encode('\n\n${SignalMessage.ping().encode()}\n'));
      expect(messages.length, 1);
    });
  });

  group('ProtocolCodec', () {
    test('frame terminates with newline', () {
      final framed = ProtocolCodec.frame(SignalMessage.ping());
      expect(framed.endsWith('\n'), isTrue);
      expect(
        ProtocolCodec.parseLine(framed.trim()).type,
        'ping',
      );
    });
  });
}
