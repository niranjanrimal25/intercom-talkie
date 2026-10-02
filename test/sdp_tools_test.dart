import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/core/sdp_tools.dart';

const offerSdp = 'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111 103\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=rtpmap:111 opus/48000/2\r\n'
    'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
    'a=rtpmap:103 ISAC/16000\r\n'
    'a=sendrecv\r\n';

void main() {
  group('SdpTools.tuneOpus', () {
    test('adds bitrate and DTX to an existing fmtp line', () {
      final tuned = SdpTools.tuneOpus(offerSdp,
          maxAverageBitrateBps: 24000, enableDtx: true);
      final fmtpLine =
          tuned.split('\r\n').firstWhere((l) => l.startsWith('a=fmtp:111'));
      expect(fmtpLine, contains('maxaveragebitrate=24000'));
      expect(fmtpLine, contains('usedtx=1'));
      expect(fmtpLine, contains('stereo=0'));
      // Existing params are preserved.
      expect(fmtpLine, contains('minptime=10'));
      expect(fmtpLine, contains('useinbandfec=1'));
      // Sanity: the rest of the SDP is untouched.
      expect(tuned, contains('a=rtpmap:111 opus/48000/2'));
      expect(tuned, contains('m=audio 9 UDP/TLS/RTP/SAVPF 111 103'));
    });

    test('creates an fmtp line when missing', () {
      final noFmtp = 'v=0\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n';
      final tuned =
          SdpTools.tuneOpus(noFmtp, maxAverageBitrateBps: 30000, enableDtx: false);
      expect(tuned, contains('a=fmtp:111 '));
      expect(tuned, contains('maxaveragebitrate=30000'));
      expect(tuned, isNot(contains('usedtx')));
      expect(tuned, contains('stereo=0'));
      // fmtp inserted right after the rtpmap line.
      final lines = tuned.split('\r\n');
      final rtpmapIndex =
          lines.indexWhere((l) => l.startsWith('a=rtpmap:111 '));
      expect(lines[rtpmapIndex + 1].startsWith('a=fmtp:111 '), isTrue);
    });

    test('overwrites previous bitrate values', () {
      final existing = 'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
          'a=rtpmap:111 opus/48000/2\r\n'
          'a=fmtp:111 maxaveragebitrate=64000;usedtx=0;stereo=1\r\n';
      final tuned = SdpTools.tuneOpus(existing,
          maxAverageBitrateBps: 16000, enableDtx: true, stereo: false);
      expect(tuned, contains('maxaveragebitrate=16000'));
      expect(tuned, isNot(contains('maxaveragebitrate=64000')));
      expect(tuned, contains('usedtx=1'));
      expect(tuned, isNot(contains('usedtx=0')));
      expect(tuned, contains('stereo=0'));
      expect(tuned, isNot(contains('stereo=1')));
    });

    test('leaves non-opus SDP unchanged', () {
      const noOpus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\n'
          'a=rtpmap:0 PCMU/8000\r\n';
      expect(
        SdpTools.tuneOpus(noOpus, maxAverageBitrateBps: 24000),
        noOpus,
      );
    });

    test('clamps bitrate into the valid range', () {
      final tuned = SdpTools.tuneOpus(offerSdp, maxAverageBitrateBps: 999999);
      expect(tuned, contains('maxaveragebitrate=510000'));
      final tunedLow =
          SdpTools.tuneOpus(offerSdp, maxAverageBitrateBps: 1);
      expect(tunedLow, contains('maxaveragebitrate=1000'));
    });

    test('handles LF-only SDP', () {
      final lfSdp = offerSdp.replaceAll('\r\n', '\n');
      final tuned = SdpTools.tuneOpus(lfSdp, maxAverageBitrateBps: 24000);
      expect(tuned, contains('maxaveragebitrate=24000'));
      expect(tuned.contains('\r\n'), isFalse);
    });

    test('opusPayloadTypes finds the payload type', () {
      expect(SdpTools.opusPayloadTypes(offerSdp), ['111']);
    });
  });
}
