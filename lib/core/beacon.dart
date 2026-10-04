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
/// Two mechanisms run in parallel:
///
/// 1. **Beacon broadcast** — sent to the limited broadcast address and to the
///    directed broadcast address of every local interface, every [interval].
/// 2. **Probe responder** — listens on [BeaconDefaults.udpPort] for `whois`
///    probes from clients and replies with a *unicast* beacon directly to the
///    prober. This reaches clients even when the access point filters
///    broadcast frames, and it deterministically triggers the iOS "Local
///    Network" permission prompt (an outgoing send is what makes iOS show
///    it — merely listening never does).
class BeaconBroadcaster {
  static const String typeField = 'beacon';
  static const String probeField = 'whois';

  RawDatagramSocket? _socket;
  RawDatagramSocket? _responderSocket;
  StreamSubscription<RawSocketEvent>? _responderSub;
  Timer? _timer;
  bool _running = false;
  List<int> _payload = const [];

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

    _payload = utf8.encode(jsonEncode(<String, dynamic>{
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
          _socket?.send(_payload, InternetAddress(target), BeaconDefaults.udpPort);
        } catch (_) {
          // Some interfaces refuse broadcast; not fatal.
        }
      }
    }

    await sendOnce();
    _timer = Timer.periodic(interval, (_) async {
      await sendOnce();
    });

    // Best-effort probe responder. Binding can fail (e.g. another socket in
    // the same process already owns the port); broadcasts still work then.
    unawaited(_startResponder());
  }

  Future<void> _startResponder() async {
    try {
      final responder = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        BeaconDefaults.udpPort,
        reuseAddress: true,
      );
      if (!_running) {
        responder.close();
        return;
      }
      _responderSocket = responder;
      _responderSub = responder.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = responder.receive();
        if (datagram == null) {
          return;
        }
        if (!_isProbe(datagram.data)) {
          return;
        }
        try {
          // Unicast reply straight back to the prober — survives
          // broadcast-filtering access points.
          responder.send(_payload, datagram.address, datagram.port);
        } catch (_) {
          // Reply is best effort.
        }
      });
    } catch (_) {
      // Port already in use in this process — broadcast beacons still flow.
    }
  }

  static bool _isProbe(List<int> data) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      return decoded is Map && decoded['t'] == probeField;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _responderSub?.cancel();
    _responderSub = null;
    _responderSocket?.close();
    _responderSocket = null;
    _socket?.close();
    _socket = null;
    _payload = const [];
  }

  bool get isRunning => _running;
}

/// Listens for [BeaconBroadcaster] beacons.
///
/// While waiting, the listener also actively sends `whois` probes so the host
/// can answer with a unicast beacon. The probes double as the trigger for
/// iOS's Local Network permission prompt.
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
  ///
  /// Sends [whois] probes at the start and periodically while waiting; the
  /// host replies unicast, which reaches us even behind broadcast-filtering
  /// access points.
  Future<DiscoveredHost?> waitForBeacon({required Duration timeout}) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('BeaconListener.start() must be called first');
    }
    final completer = Completer<DiscoveredHost?>();
    late final StreamSubscription<RawSocketEvent> subscription;
    Timer? timeoutTimer;
    final probeTimers = <Timer>[];

    Future<void> sendProbe() async {
      final probe = utf8.encode(jsonEncode(<String, dynamic>{
        't': BeaconBroadcaster.probeField,
        'v': 1,
      }));
      final targets = <String>{'255.255.255.255'};
      for (final address in await NetUtils.localIpv4s()) {
        final parts = address.address.split('.');
        if (parts.length == 4) {
          targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
      for (final target in targets) {
        try {
          socket.send(probe, InternetAddress(target), BeaconDefaults.udpPort);
        } catch (_) {
          // Best effort.
        }
      }
    }

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
        for (final timer in probeTimers) {
          timer.cancel();
        }
        completer.complete(DiscoveredHost(
          name: host.name,
          address: datagram.address.address,
          port: host.port,
        ));
      }
    });

    // Probe immediately and twice more while waiting.
    unawaited(sendProbe());
    probeTimers.add(Timer(const Duration(seconds: 1), () => unawaited(sendProbe())));
    probeTimers.add(Timer(const Duration(seconds: 2), () => unawaited(sendProbe())));

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        for (final timer in probeTimers) {
          timer.cancel();
        }
        completer.complete(null);
      }
    });

    final result = await completer.future;
    await subscription.cancel();
    timeoutTimer?.cancel();
    for (final timer in probeTimers) {
      timer.cancel();
    }
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
