import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dsh_remote/dsh_remote.dart' as remote;

enum RemoteNetworkRoute { local, remote, unknown }

RemoteNetworkRoute remoteNetworkRoute(List<ConnectivityResult> interfaces) {
  if (interfaces.contains(ConnectivityResult.wifi) || interfaces.contains(ConnectivityResult.ethernet)) {
    return RemoteNetworkRoute.local;
  }
  if (interfaces.contains(ConnectivityResult.mobile)) {
    return RemoteNetworkRoute.remote;
  }
  return RemoteNetworkRoute.unknown;
}

/// Interface hints only; ICE validates actual reachability and the selected path.
List<remote.RemoteTransportMode> transportsForRemoteRoute(RemoteNetworkRoute route) =>
    route == RemoteNetworkRoute.remote
    ? const [remote.RemoteTransportMode.p2p, remote.RemoteTransportMode.turn, remote.RemoteTransportMode.relay]
    : remote.RemoteTransportMode.values;

Future<RemoteNetworkRoute> resolveRemoteNetworkRoute() async {
  try {
    return remoteNetworkRoute(await Connectivity().checkConnectivity().timeout(const Duration(seconds: 2)));
  } catch (_) {
    return RemoteNetworkRoute.unknown;
  }
}
