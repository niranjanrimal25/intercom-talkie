import 'dart:io';

/// Network helpers for the hotspot-based link.
class NetUtils {
  /// Returns all non-loopback IPv4 addresses of this device.
  static Future<List<InternetAddress>> localIpv4s() async {
    final result = <InternetAddress>[];
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          result.add(address);
        }
      }
    }
    return result;
  }

  /// Well-known gateway addresses used by phone hotspots.
  ///
  /// * `192.168.43.1` — classic Android hotspot
  /// * `192.168.49.1` and friends — newer Android hotspots
  /// * `172.20.10.1`  — iPhone Personal Hotspot
  /// * `192.168.137.1`— Windows Mobile Hotspot (for desktop testing)
  static const List<String> knownGateways = <String>[
    '192.168.43.1',
    '192.168.49.1',
    '172.20.10.1',
    '192.168.137.1',
  ];

  /// Builds an ordered list of plausible host addresses when this device is
  /// the hotspot *client*: for each local address `a.b.c.d` the gateway
  /// `a.b.c.1` is the usual hotspot host.
  static Future<List<String>> gatewayCandidates() async {
    final candidates = <String>[];
    for (final address in await localIpv4s()) {
      final parts = address.address.split('.');
      if (parts.length != 4) {
        continue;
      }
      final gateway = '${parts[0]}.${parts[1]}.${parts[2]}.1';
      if (!candidates.contains(gateway)) {
        candidates.add(gateway);
      }
    }
    for (final known in knownGateways) {
      if (!candidates.contains(known)) {
        candidates.add(known);
      }
    }
    return candidates;
  }

  /// True when the string looks like an IPv4 address.
  static bool looksLikeIpv4(String input) {
    final parts = input.split('.');
    if (parts.length != 4) {
      return false;
    }
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        return false;
      }
    }
    return true;
  }

  /// Short human-readable error text.
  static String describeError(Object error) {
    if (error is SocketException) {
      final osError = error.osError;
      if (osError != null) {
        return '${error.message} (errno ${osError.errorCode})';
      }
      return error.message;
    }
    return error.toString();
  }
}
