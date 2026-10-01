import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/core/beacon.dart';
import 'package:intercom_talkie/core/net_utils.dart';

void main() {
  group('NetUtils.looksLikeIpv4', () {
    test('accepts valid addresses', () {
      expect(NetUtils.looksLikeIpv4('192.168.43.1'), isTrue);
      expect(NetUtils.looksLikeIpv4('172.20.10.1'), isTrue);
      expect(NetUtils.looksLikeIpv4('0.0.0.0'), isTrue);
    });

    test('rejects garbage', () {
      expect(NetUtils.looksLikeIpv4('hello'), isFalse);
      expect(NetUtils.looksLikeIpv4('192.168.43'), isFalse);
      expect(NetUtils.looksLikeIpv4('192.168.43.256'), isFalse);
      expect(NetUtils.looksLikeIpv4('192.168.43.1.5'), isFalse);
      expect(NetUtils.looksLikeIpv4(''), isFalse);
      expect(NetUtils.looksLikeIpv4('::1'), isFalse);
    });
  });

  group('Beacon parsing', () {
    test('parses a valid beacon', () {
      final beacon = parseBeacon(
        '{"t":"beacon","v":1,"name":"iPhone of Ram","port":45678}'
            .codeUnits,
      );
      expect(beacon, isNotNull);
      expect(beacon!.name, 'iPhone of Ram');
      expect(beacon.port, 45678);
    });

    test('rejects non-beacon datagrams', () {
      expect(parseBeacon('{"t":"hello"}'.codeUnits), isNull);
      expect(parseBeacon('not json'.codeUnits), isNull);
      expect(parseBeacon('{"t":"beacon","name":123}'.codeUnits), isNull);
      expect(parseBeacon('{"t":"beacon","port":"x","name":"a"}'.codeUnits),
          isNull);
    });

    test('defaults are distinct', () {
      expect(BeaconDefaults.tcpPort, isNot(BeaconDefaults.udpPort));
    });
  });

  group('NetUtils.gatewayCandidates', () {
    test('contains known hotspot gateways', () async {
      final candidates = await NetUtils.gatewayCandidates();
      for (final known in NetUtils.knownGateways) {
        expect(candidates, contains(known));
      }
      // No duplicates.
      expect(candidates.toSet().length, candidates.length);
    });
  });
}
