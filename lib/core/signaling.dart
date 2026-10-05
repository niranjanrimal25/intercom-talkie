import 'dart:async';
import 'dart:io';

import 'app_log.dart';
import 'beacon.dart';
import 'protocol.dart';

/// A framed, message-oriented wrapper around a connected TCP socket used for
/// WebRTC signaling.
class SignalConnection {
  SignalConnection._(this._socket, this.label);

  final Socket _socket;
  final String label;
  final MessageFramer _framer = MessageFramer();
  final List<void Function()> _closeListeners = <void Function()>[];

  void Function(SignalMessage message)? onMessage;
  void Function()? onClosed;

  bool _closed = false;
  bool _everUsed = false;

  bool get isClosed => _closed;

  /// True once at least one message was exchanged (used by the server to
  /// decide whether a socket that goes away silently was a real peer).
  bool get everUsed => _everUsed;

  static SignalConnection wrap(Socket socket, {String label = 'link'}) {
    final connection = SignalConnection._(socket, label);
    socket.listen(
      (data) => connection._handleData(data),
      onError: (Object error) {
        AppLog.instance.w('signaling', '$label stream error: $error');
        connection._handleClose();
      },
      onDone: connection._handleClose,
      cancelOnError: true,
    );
    return connection;
  }

  void _handleData(List<int> data) {
    List<SignalMessage> messages;
    try {
      messages = _framer.push(data);
    } on FormatException {
      AppLog.instance.w('signaling', '$label framing error, closing');
      close();
      return;
    }
    for (final message in messages) {
      _everUsed = true;
      onMessage?.call(message);
    }
  }

  void _handleClose() {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final listener in List.of(_closeListeners)) {
      listener();
    }
    onClosed?.call();
  }

  /// Sends one message. Safe to call after close (drops silently).
  void send(SignalMessage message) {
    if (_closed) {
      return;
    }
    try {
      _socket.add(ProtocolCodec.frameBytes(message));
      _everUsed = true;
    } catch (error) {
      AppLog.instance.w('signaling', '$label send failed: $error');
      close();
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      // Graceful close flushes any pending writes (e.g. a final `bye`)
      // before the FIN, unlike destroy().
      _socket.close();
    } catch (_) {
      try {
        _socket.destroy();
      } catch (_) {
        // Ignore.
      }
    }
    for (final listener in List.of(_closeListeners)) {
      listener();
    }
    onClosed?.call();
  }
}

/// TCP signaling server (used by the hotspot host device).
///
/// Accepts exactly one active connection at a time. Connections that arrive
/// while a peer is being served are politely rejected with a `busy` message.
class SignalingServer {
  SignalingServer._(this._serverSocket, this.port);

  final ServerSocket _serverSocket;
  final int port;
  final List<SignalConnection> _pending = <SignalConnection>[];
  final List<Completer<SignalConnection>> _waiters =
      <Completer<SignalConnection>>[];

  SignalConnection? _active;
  bool _closed = false;

  static Future<SignalingServer> bind({int port = BeaconDefaults.tcpPort}) async {
    final serverSocket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );
    final server = SignalingServer._(serverSocket, port);
    serverSocket.listen(
      server._handleAccept,
      onError: (Object error) {
        AppLog.instance.e('signaling', 'server error: $error');
      },
      onDone: () {
        AppLog.instance.w('signaling', 'server socket done');
      },
      cancelOnError: false,
    );
    return server;
  }

  void _handleAccept(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final connection =
        SignalConnection.wrap(socket, label: 'client@${socket.remoteAddress.address}');

    final active = _active;
    if (active != null && !active.isClosed) {
      // A peer is currently being served — reject the newcomer.
      connection.send(SignalMessage.busy());
      connection.close();
      return;
    }

    if (_waiters.isNotEmpty) {
      _active = connection;
      final waiter = _waiters.removeAt(0);
      waiter.complete(connection);
    } else {
      _pending.add(connection);
      // Park the socket; it will be handed over on the next acceptClient().
    }
  }

  /// Resolves with the next client connection.
  ///
  /// If no client is currently queued, waits for one. The server marks the
  /// returned connection as active; while it stays open, further arrivals are
  /// rejected with `busy`.
  Future<SignalConnection> acceptClient() {
    if (_closed) {
      return Future.error(StateError('server is closed'));
    }
    if (_pending.isNotEmpty) {
      final connection = _pending.removeAt(0);
      _active = connection;
      return Future.value(connection);
    }
    final completer = Completer<SignalConnection>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Releases the active slot so the next client can be accepted
  /// immediately. Called by the engine when the current peer disappears.
  void releaseActive() {
    _active = null;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final connection in List.of(_pending)) {
      connection.close();
    }
    _pending.clear();
    for (final waiter in List.of(_waiters)) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('server closed'));
      }
    }
    _waiters.clear();
    _active?.close();
    _active = null;
    await _serverSocket.close();
  }

  bool get isClosed => _closed;
}

/// TCP signaling client (used by the phone joining the hotspot).
class SignalingClient {
  /// Connects to [host]:[port]. Throws on failure or timeout.
  static Future<SignalConnection> connect(
    String host, {
    int port = BeaconDefaults.tcpPort,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: timeout,
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SignalConnection.wrap(socket, label: 'host@$host');
  }

  /// Tries to connect to [candidates] in order with a short timeout each.
  /// Returns the first successful connection, or `null`.
  static Future<SignalConnection?> tryCandidates(
    List<String> candidates, {
    int port = BeaconDefaults.tcpPort,
    Duration perHostTimeout = const Duration(milliseconds: 700),
  }) async {
    for (final host in candidates) {
      try {
        final connection = await connect(
          host,
          port: port,
          timeout: perHostTimeout,
        );
        return connection;
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }
}
