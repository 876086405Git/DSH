import 'dart:convert';
import 'dart:io';

import 'release.dart';
import 'update_config.dart';
import 'update_http.dart';

/// Why no endpoint could say what the latest release is. All of them read
/// "暂时检查不了更新" to the person; the kind is for logs and tests.
enum CheckFailure {
  /// No connection, DNS, timeout, TLS.
  network,

  /// GitHub API rate limit (403/429 with the limit spent).
  rateLimited,

  /// 404 everywhere: no release yet, or the repository is private.
  noRelease,

  /// Answered, but not with a usable release.
  badResponse,
}

sealed class CheckResult {
  const CheckResult();
}

final class CheckFound extends CheckResult {
  const CheckFound(this.release, this.endpoint);

  final ReleaseInfo release;

  /// The endpoint that reported the selected release.
  final UpdateEndpoint endpoint;
}

final class CheckFailed extends CheckResult {
  const CheckFailed(this.failure, {this.attempts = const []});

  final CheckFailure failure;

  /// Endpoint id → what went wrong, in order.
  final List<(String, CheckFailure)> attempts;
}

/// Finds the newest release reported by the available metadata endpoints.
class UpdateChecker {
  const UpdateChecker({required this.http, required this.sources, this.userAgent});

  final UpdateHttp http;
  final UpdateSources sources;

  /// Sent to the beta channel only ([updaterUserAgent]); the other sources
  /// get the plain [updaterAgent].
  final String? userAgent;

  static const _timeout = Duration(seconds: 12);

  Future<CheckResult> check({String? preferred}) async {
    final endpoints = sources.metadataEndpoints(preferred: preferred);
    final attempts = <(String, CheckFailure)>[];
    CheckFound? latest;

    void collect(UpdateEndpoint endpoint, Object outcome) {
      switch (outcome) {
        case ReleaseInfo release:
          if (latest == null || release.version.isNewerThan(latest!.release.version)) {
            latest = CheckFound(release, endpoint);
          }
        case CheckFailure failure:
          attempts.add((endpoint.id, failure));
      }
    }

    // Compare official manifests in parallel. A stale but reachable source
    // must not hide a newer release from another official source.
    final official = endpoints.where((e) => e.kind == EndpointKind.manifest && !e.isAccelerator).toList();
    final results = await Future.wait(official.map(_try));
    for (var i = 0; i < official.length; i++) {
      collect(official[i], results[i]);
    }
    // The API and the direct GitHub manifest point to the same release. Only
    // spend API quota when GitHub's manifest was unavailable.
    final githubAnswered = official.indexWhere((e) => e.mirrorId == UpdateMirror.github.id);
    if (githubAnswered < 0 || results[githubAnswered] is! ReleaseInfo) {
      for (final endpoint in endpoints.where((e) => e.kind == EndpointKind.githubApi)) {
        collect(endpoint, await _try(endpoint));
      }
    }
    // Unofficial mirrors keep checks working when all official routes fail,
    // but cannot override a release established by an official source.
    if (latest == null) {
      final mirrors = endpoints.where((e) => e.isAccelerator).toList();
      final results = await Future.wait(mirrors.map(_try));
      for (var i = 0; i < mirrors.length; i++) {
        collect(mirrors[i], results[i]);
      }
    }
    return latest ?? CheckFailed(_summarize(attempts.map((a) => a.$2)), attempts: attempts);
  }

  /// Rate limiting wins (it tells the person "later" for sure); 404 only
  /// when every endpoint said so; otherwise network unless something answered
  /// with garbage.
  static CheckFailure _summarize(Iterable<CheckFailure> failures) {
    final all = failures.toSet();
    if (all.contains(CheckFailure.rateLimited)) return CheckFailure.rateLimited;
    if (all.length == 1 && all.single == CheckFailure.noRelease) return CheckFailure.noRelease;
    if (all.contains(CheckFailure.badResponse)) return CheckFailure.badResponse;
    if (all.isEmpty) return CheckFailure.noRelease;
    return CheckFailure.network;
  }

  Future<Object> _try(UpdateEndpoint endpoint) async {
    final UpdateHttpResponse response;
    try {
      response = await http.get(
        endpoint.url,
        headers: {
          ...endpoint.kind == EndpointKind.githubApi
              ? const {'accept': 'application/vnd.github+json', 'x-github-api-version': '2022-11-28'}
              : const {'accept': 'application/json'},
          'cache-control': 'no-cache',
          ...endpoint.headers,
          if (userAgent case final agent? when endpoint.id == UpdateChannel.endpointId) 'user-agent': agent,
        },
        timeout: _timeout,
      );
    } on Object {
      // SocketException, TimeoutException, HandshakeException, HttpException…
      return CheckFailure.network;
    }
    if (response.status != HttpStatus.ok) {
      await response.discard();
      return switch (response.status) {
        403 ||
        429 when response.headers['x-ratelimit-remaining'] == '0' || response.status == 429 => CheckFailure.rateLimited,
        404 => CheckFailure.noRelease,
        >= 500 => CheckFailure.network,
        _ => CheckFailure.badResponse,
      };
    }
    final String body;
    try {
      body = await response.text(timeout: _timeout);
    } on Object {
      return CheckFailure.network;
    }
    try {
      final json = jsonDecode(body);
      return switch (endpoint.kind) {
        EndpointKind.githubApi => parseGithubRelease(json),
        EndpointKind.manifest => parseUpdateManifest(json, base: endpoint.url),
      };
    } on Object {
      // FormatException, or a TypeError from a field of the wrong type. Some
      // mirrors answer 200 with an HTML error page.
      return CheckFailure.badResponse;
    }
  }
}
