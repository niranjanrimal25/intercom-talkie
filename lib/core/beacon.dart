import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'net_utils.dart';

/// A host discovered through the UDP beacon.
class DiscoveredHost {
  DiscoveredHost({required this.name, required this.address, required this.port});

  final String name;
  final String address;
  final int port;

  @override
  String toString() => 'DiscoveredHost($name @ $address:$port)';
}

/// Broadcasts a small JSON beacon over UDP so a joining phone can find the
/// hotspot host without any manual IP entry.
///
/// Beacons are sent to the limited broadcast address and to the directed
/// broadcast address of every local interface.
class BeaconBroadcaster {
  static const String typeField = 'beacon';

  RawDatagramSocket? _socket;
  Timer? _timer;
  bool _running = false;

  Future<void> start({
    required String hostName,
    required int tcpPort,
    Duration interval = const Duration(milliseconds: 1200),
  }) async {
    if (_running) {
      return;
    }
    _running = true;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    final payload = utf8.encode(jsonEncode(<String, dynamic>{
      't': typeField,
      'v': 1,
      'name': hostName,
      'port': tcpPort,
    }));

    Future<void> sendOnce() async {
      if (!_running) {
        return;
      }
      final targets = <String>{'255.255.255.255'};
      for (final address in await NetUtils.localIpv4s()) {
        final parts = address.address.split('.');
        if (parts.length == 4) {
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      for (final target in targets) {
        try {
          _socket?.send(payload, InternetAddress(target), BeaconDefaults.udpPort);
        } catch (_) {
          // Some interfaces refuse broadcast; not fatal.
        }
      }
    }

    await sendOnce();
    _timer = Timer.periodic(interval, (_) async {
      await sendOnce();
    });
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
  }

  bool get isRunning => _running;
}

/// Listens for [BeaconBroadcaster] beacons.
class BeaconListener {
  RawDatagramSocket? _socket;

  Future<void> start() async {
    if (_socket != null) {
      return;
    }
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      BeaconDefaults.udpPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
  }

  /// Waits up to [timeout] for the first valid beacon.
  Future<DiscoveredHost?> waitForBeacon({required Duration timeout}) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('BeaconListener.start() must be called first');
    }
    final completer = Completer<DiscoveredHost?>();
    late final StreamSubscription<RawSocketEvent> subscription;
    Timer? timeoutTimer;

    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      final host = parseBeacon(datagram.data);
      if (host != null && !completer.isCompleted) {
        timeoutTimer?.cancel();
        completer.complete(DiscoveredHost(
          name: host.name,
          address: datagram.address.address,
          port: host.port,
        ));
      }
    });

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    final result = await completer.future;
    await subscription.cancel();
    timeoutTimer?.cancel();
    return result;
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }
}

/// Parses a beacon datagram. Exposed for tests.
DiscoveredHost? parseBeacon(List<int> data) {
  try {
    final decoded = jsonDecode(utf8.decode(data));
    if (decoded is! Map) {
      return null;
    }
    if (decoded['t'] != BeaconBroadcaster.typeField) {
      return null;
    }
    final name = decoded['name'];
    final port = decoded['port'];
    if (name is! String || port is! int) {
      return null;
    }
    return DiscoveredHost(name: name, address: '', port: port);
  } catch (_) {
    return null;
  }
}

class BeaconDefaults {
  static const int udpPort = 45679;
  static const int tcpPort = 45678;
}
