import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

String frame(String type, Map<String, Object?> payload) => jsonEncode({
  'v': 1,
  'id': 'test-$type',
  'type': type,
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  'payload': payload,
});

void main() {
  for (final closeBeforeHandshake in [true, false]) {
    test(
      'real relay ${closeBeforeHandshake ? 'closed before' : 'live during'} secure establishment owns all errors',
      () async {
        final clientKey = X25519KeyPair.generate();
        final hostKey = X25519KeyPair.generate();
        final peer = NoiseIkSession(
          role: NoiseRole.responder,
          localPrivateKey: hostKey.privateKeyBase64Url,
          localPublicKey: hostKey.publicKeyBase64Url,
          remotePublicKey: clientKey.publicKeyBase64Url,
          prologue: createNoisePrologue('connection-304', 'host', 'phone'),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedSocket = Completer<WebSocket>();
        final errorReceived = Completer<void>();
        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(request);
          acceptedSocket.complete(socket);
          socket.listen((raw) {
            final input = jsonDecode(raw as String) as Map<String, dynamic>;
            if (input['type'] == 'hello') {
              socket.add(
                frame('hello.ack', {
                  'protocol': 1,
                  'serverVersion': 'test',
                  'connectionSessionId': 'cs304',
                  'heartbeatIntervalMs': 25000,
                  'maxControlFrameBytes': 65536,
                  'maxRelayFrameBytes': 262144,
                  'capabilities': ['transport.relay'],
                }),
              );
            } else if (input['type'] == 'connect.request') {
              socket.add(frame('connect.accepted', {'connectionId': 'connection-304'}));
            } else if (input['type'] == 'secure.handshake') {
              final payload = input['payload'] as Map<String, dynamic>;
              peer.readHandshake(base64Url.decode(base64Url.normalize(payload['data'] as String)));
              socket.add(
                frame('secure.handshake', {
                  'connectionId': 'connection-304',
                  'sourceDeviceId': 'host',
                  'targetDeviceId': 'phone',
                  'step': 2,
                  'data': base64Url.encode(peer.writeHandshake()).replaceAll('=', ''),
                }),
              );
            }
          });
        });
        RelayTransport? transport;
        SecureChannel? channel;
        try {
          transport = await RelayTransport.connect(
            url: Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/connect'),
            deviceId: 'phone',
            accessToken: 'test-token',
            hostDeviceId: 'host',
            tracer: (direction, message) {
              if (direction == 'in' && message['type'] == 'error') errorReceived.complete();
            },
          );
          if (closeBeforeHandshake) {
            (await acceptedSocket.future).add(
              frame('error', {
                'connectionId': 'connection-304',
                'code': 'CONNECTION_REPLACED',
                'message': 'Connection replaced',
                'retryable': false,
              }),
            );
            // Tracer runs inside the real frame handler; this continuation runs
            // after that handler has stored the terminal reason, with no fake state.
            await errorReceived.future;
          }
          final establishing = SecureChannel.establish(
            transport: transport,
            clientDeviceId: 'phone',
            clientPrivateKey: clientKey.privateKeyBase64Url,
            clientPublicKey: clientKey.publicKeyBase64Url,
            hostDeviceId: 'host',
            hostIdentityKey: hostKey.publicKeyBase64Url,
          );
          if (closeBeforeHandshake) {
            await expectLater(
              establishing,
              throwsA(
                isA<SecureChannelException>()
                    .having((error) => error.code, 'code', 'CONNECTION_REPLACED')
                    .having((error) => error.retryable, 'retryable', false),
              ),
            );
          } else {
            channel = await establishing;
            expect(channel.isClosed, isFalse);
            expect(peer.complete, isTrue);
            await channel.close();
            expect(channel.isClosed, isTrue);
          }
        } finally {
          await channel?.close();
          await transport?.close();
          if (acceptedSocket.isCompleted) await (await acceptedSocket.future).close();
          await server.close(force: true);
          peer.destroy();
          clientKey.destroy();
          hostKey.destroy();
        }
      },
    );
  }
}
