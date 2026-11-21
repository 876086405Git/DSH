// Where usage statistics go and how: one JSON POST, no cookies, no
// redirects, ten seconds at most. And the native facts the body carries
// (MethodChannel `dsh/usage`, usage/UsagePlugin.kt).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../state/app_info.dart';
import 'usage_ledger.dart';

/// `--dart-define=DSH_USAGE_ENDPOINT=https://…` points a build elsewhere
/// (HTTPS, or plain HTTP on loopback for a test server). It also turns the
/// statistics on in a debug or profile build.
const _endpointOverride = String.fromEnvironment('DSH_USAGE_ENDPOINT');

/// The share host's endpoint (services/share-worker), contracts v1 to v3.
final defaultUsageEndpoint = Uri.parse('https://go.dshtui.com/api/usage/v1');

/// [defaultUsageEndpoint], or the build's override when it is usable.
Uri get usageEndpoint => usageEndpointFrom(_endpointOverride) ?? defaultUsageEndpoint;

Uri? get usageV4Endpoint {
  final endpoint = usageEndpoint;
  return endpoint.path.endsWith('/v1')
      ? endpoint.replace(path: '${endpoint.path.substring(0, endpoint.path.length - 1)}4')
      : null;
}

/// [text] as an endpoint: HTTPS, or HTTP to loopback. Null otherwise.
Uri? usageEndpointFrom(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final loopback = uri.host == 'localhost' || uri.host == '127.0.0.1';
  return uri.scheme == 'https' || (uri.scheme == 'http' && loopback) ? uri : null;
}

/// Whether this build counts and reports at all: release builds, and builds
/// pointed at a test endpoint. Debug runs and tests stay out of the numbers
/// (tests switch it on where they check it).
abstract final class UsageBuild {
  static bool active = kReleaseMode || usageEndpointFrom(_endpointOverride) != null;
}

/// One POST; a seam so tests never touch the network.
abstract interface class UsageHttp {
  /// The response status; throws on a network failure or after [timeout].
  Future<int> post(Uri url, String json, {Duration timeout});
}

class IoUsageHttp implements UsageHttp {
  const IoUsageHttp();

  @override
  Future<int> post(Uri url, String json, {Duration timeout = const Duration(seconds: 10)}) async {
    // A client per send: no connection, cookie or credential outlives it.
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 1)
      ..userAgent = 'dsh-go';
    try {
      return await () async {
        final request = await client.postUrl(url);
        request.followRedirects = false;
        request.persistentConnection = false;
        final body = utf8.encode(json);
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }
}

/// The phone's facts for the body. Without the native side (tests, other
/// platforms) the version from [AppInfo] and nothing else.
class UsageDeviceChannel {
  const UsageDeviceChannel([this.channel = const MethodChannel('dsh/usage')]);

  final MethodChannel channel;

  Future<UsageDevice> read() async {
    final fallback = AppInfo.version.split('+').first;
    try {
      final map = await channel.invokeMapMethod<String, Object?>('device') ?? const {};
      String text(String key) => map[key] is String ? map[key]! as String : '';
      int number(String key) => map[key] is num ? (map[key]! as num).toInt() : 0;
      final app = text('versionName');
      return UsageDevice(
        app: app.isEmpty ? fallback : app,
        build: number('versionCode'),
        sdk: number('sdk'),
        abi: text('abi'),
        maker: usageMaker(text('maker')),
        model: text('model').isEmpty ? '' : usageMaker(text('model')),
        rom: text('rom').isEmpty ? '' : usageMaker(text('rom')),
      );
    } on MissingPluginException {
      return UsageDevice(app: fallback);
    } on PlatformException {
      return UsageDevice(app: fallback);
    }
  }
}
