import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_talkie/core/protocol.dart';
import 'package:intercom_talkie/core/signaling.dart';

/// Finds a free TCP port on loopback.
Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// Connects a client to [port] while [server] accepts it.
Future<(SignalConnection, SignalConnection)> connectPair(
    SignalingServer server, int port) async {
  final accepted = Completer<SignalConnection>();
  unawaited(() async {
    try {
      accepted.complete(await server.acceptClient());
    } catch (error) {
      accepted.completeError(error);
    }
  }());
  final client = await SignalingClient.connect('127.0.0.1', port: port);
  final serverSide = await accepted.future;
  return (client, serverSide);
}

void main() {
  test('server accepts a client and exchanges messages', () async {
    final port = await freePort();
    final server = await SignalingServer.bind(port: port);

    final (client, serverSide) = await connectPair(server, port);

    final serverGot = Completer<void>();
    serverSide.onMessage = (message) {
      if (message.type == 'hello') {
        serverGot.complete();
      }
    };
    client.send(SignalMessage.hello(
      name: 'client',
      role: 'client',
      code: '',
      sessionId: 's1',
    ));
    await serverGot.future.timeout(const Duration(seconds: 5));

    final clientGot = Completer<void>();
    client.onMessage = (message) {
      if (message.type == 'welcome') {
        clientGot.complete();
      }
    };
    serverSide.send(SignalMessage.welcome(name: 'host'));
    await clientGot.future.timeout(const Duration(seconds: 5));

    client.close();
    serverSide.close();
    await server.close();
  });

  test('ping/pong keeps working over the framed link', () async {
    final port = await freePort();
    final server = await SignalingServer.bind(port: port);
    final (client, serverSide) = await connectPair(server, port);

    final ponged = Completer<void>();
    client.onMessage = (message) {
      if (message.type == 'pong') {
        ponged.complete();
      }
    };
    serverSide.onMessage = (message) {
      if (message.type == 'ping') {
        serverSide.send(SignalMessage.pong());
      }
    };
    client.send(SignalMessage.ping());
    await ponged.future.timeout(const Duration(seconds: 5));

    client.close();
    serverSide.close();
    await server.close();
  });

  test('second client is rejected with busy while first is active', () async {
    final port = await freePort();
    final server = await SignalingServer.bind(port: port);
    final (first, firstServerSide) = await connectPair(server, port);

    final second = await SignalingClient.connect('127.0.0.1', port: port);
    final gotBusy = Completer<void>();
    final gotClosed = Completer<void>();
    second.onMessage = (message) {
      if (message.type == 'busy') {
        gotBusy.complete();
      }
    };
    second.onClosed = () => gotClosed.complete();

    await gotBusy.future.timeout(const Duration(seconds: 5));
    await gotClosed.future.timeout(const Duration(seconds: 5));

    first.close();
    firstServerSide.close();
    await server.close();
  });

  test('releaseActive allows the next client after the first leaves',
      () async {
    final port = await freePort();
    final server = await SignalingServer.bind(port: port);

    final (first, firstServerSide) = await connectPair(server, port);
    first.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.releaseActive();

    final (second, secondServerSide) = await connectPair(server, port);
    expect(second.isClosed, isFalse);

    second.close();
    secondServerSide.close();
    firstServerSide.close();
    await server.close();
  });

  test('onClosed fires when the remote end goes away', () async {
    final port = await freePort();
    final server = await SignalingServer.bind(port: port);
    final (client, serverSide) = await connectPair(server, port);
    final closed = Completer<void>();
    serverSide.onClosed = () => closed.complete();

    client.close();
    await closed.future.timeout(const Duration(seconds: 5));
    await server.close();
  });

  test('client connect fails on a closed port', () async {
    final port = await freePort(); // nothing listening here
    await expectLater(
      SignalingClient.connect(
        '127.0.0.1',
        port: port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(anything),
    );
  });

  test('tryCandidates returns null when nothing listens', () async {
    final port = await freePort();
    final connection = await SignalingClient.tryCandidates(
      ['127.0.0.1'],
      port: port,
      perHostTimeout: const Duration(milliseconds: 500),
    );
    expect(connection, isNull);
  });
}
