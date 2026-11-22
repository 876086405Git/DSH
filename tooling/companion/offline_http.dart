import 'dart:io';

/// The selected offline suites may use local fixture servers, never a model
/// endpoint or DNS name. MockClient does not open an HttpClient connection.
/// This is a Dart HTTP boundary for those suites, not an OS network sandbox.
class CompanionOfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final address = InternetAddress.tryParse(uri.host);
      if (proxyHost != null ||
          proxyPort != null ||
          address == null ||
          (address.address != '127.0.0.1' && address.address != '::1')) {
        return Future<ConnectionTask<Socket>>.error(
          SocketException(
            'offline companion replay refused HTTP host: ${uri.host}',
          ),
        );
      }
      return Socket.startConnect(address, uri.port);
    };
    return client;
  }
}
