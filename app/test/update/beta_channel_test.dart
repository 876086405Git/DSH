// Builds with a channel token include go.dshtui.com/beta in their checks
// and download from it with the token; the token never goes anywhere else.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/checker.dart';
import 'package:dsh_app/update/downloader.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _token = 'dshc_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG';
const _auth = 'Bearer $_token';
const _feed = 'https://go.dshtui.com/beta/update.json';
const _api = 'https://api.github.com/repos/ccch1mneyyy/dsh-go/releases/latest';
const _apk = 'dsh-go-1.2.0-arm64.apk';
const _betaApk = 'https://go.dshtui.com/beta/1.2.0/$_apk';
const _githubApk = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_apk';
const _dlFeed = 'https://dl.dshtui.com/update.json';
const _githubFeed = 'https://github.com/ccch1mneyyy/dsh-go/releases/latest/download/update.json';

final _bytes = utf8.encode('PK pretend this is the 1.2.0 beta for arm64');

/// What scripts/publish-release.sh puts at beta/update.json.
String _manifest({List<int>? apk}) => jsonEncode({
  'schema': 1,
  'version': '1.2.0+10261200',
  'tag': 'v1.2.0',
  'notes': '### 中文\n\n- 内测\n\n### English\n\n- Beta',
  'notesByLocale': {'zh': '- 内测', 'en': '- Beta'},
  'page': 'https://go.dshtui.com/beta',
  'assets': {
    'arm64': {
      'name': _apk,
      'size': (apk ?? _bytes).length,
      'sha256': sha256.convert(apk ?? _bytes).toString(),
      'url': _betaApk,
    },
  },
});

/// A route that answers only with the token, like the Worker.
Route _guarded(Route inner) => (url, headers) {
  if (headers['authorization'] != _auth) return textResponse('Unauthorized', status: 401);
  return inner(url, headers);
};

/// Every request that carried the token went to the channel.
void _expectTokenOnlyOnChannel(FakeHttp http) {
  for (final (url, headers) in http.requests) {
    final carries = headers.values.any((v) => v.contains(_token));
    expect(carries, url.host == 'go.dshtui.com' && url.path.startsWith('/beta/'), reason: '$url');
  }
}

void main() {
  final sources = buildUpdateSources(channelToken: _token);

  group('channel', () {
    test('needs a token and an HTTPS origin', () {
      expect(UpdateChannel.tryCreate(token: ''), isNull);
      expect(UpdateChannel.tryCreate(token: '  '), isNull);
      expect(UpdateChannel.tryCreate(token: _token, origin: 'http://go.dshtui.com'), isNull);
      expect(UpdateChannel.tryCreate(token: _token, origin: 'https://go.dshtui.com/beta'), isNull);
      expect(
        UpdateChannel.tryCreate(token: _token, origin: 'http://127.0.0.1:8787')!.manifest.toString(),
        'http://127.0.0.1:8787/beta/update.json',
      );
      final channel = UpdateChannel.tryCreate(token: ' $_token\n', origin: 'https://go.dshtui.com/')!;
      expect(channel.manifest.toString(), _feed);
      expect(channel.headers, {'authorization': _auth});
      expect(channel.toString(), isNot(contains(_token)));
    });

    test('covers its own files only', () {
      final channel = sources.channel!;
      expect(channel.covers(Uri.parse(_betaApk)), isTrue);
      expect(channel.covers(Uri.parse(_feed)), isTrue);
      for (final other in [
        'http://go.dshtui.com/beta/1.2.0/$_apk',
        'https://go.dshtui.com:8443/beta/1.2.0/$_apk',
        'https://evil.example/beta/1.2.0/$_apk',
        'https://go.dshtui.com.evil.example/beta/x.apk',
        'https://go.dshtui.com/download/1.2.0/$_apk',
        'https://go.dshtui.com/beta',
        _githubApk,
      ]) {
        expect(channel.covers(Uri.parse(other)), isFalse, reason: other);
      }
    });

    test('metadata: the channel first, with its token, whatever worked last', () {
      for (final preferred in [null, 'api', 'manifest:ghfast', 'beta']) {
        final endpoints = sources.metadataEndpoints(preferred: preferred);
        expect(endpoints.first.id, 'beta');
        expect(endpoints.first.url.toString(), _feed);
        expect(endpoints.first.headers, {'authorization': _auth});
        expect(endpoints.skip(1).every((e) => e.headers.isEmpty), isTrue);
      }
      expect(sources.metadataEndpoints(preferred: 'manifest:ghfast').map((e) => e.id).take(3), [
        'beta',
        'feed',
        'manifest:github',
      ]);
      expect(sources.metadataEndpoints().first.toString(), isNot(contains(_token)));
    });

    test('downloads: the token on the channel URL, never on GitHub or accelerators', () {
      final urls = sources.downloadUrls([Uri.parse(_betaApk), Uri.parse(_githubApk)]);
      expect(urls.map((u) => u.url.toString()), [
        _betaApk,
        'https://dl.dshtui.com/download/1.2.0/$_apk',
        _githubApk,
        'https://ghfast.top/$_githubApk',
        'https://gh-proxy.com/$_githubApk',
      ]);
      expect(urls.first.headers, {'authorization': _auth});
      expect(urls.first.label, 'go.dshtui.com');
      expect(urls.skip(1).every((u) => u.headers.isEmpty), isTrue);
    });
  });

  group('checking', () {
    test('the beta and release feeds agree: use the channel with its token', () async {
      final http = FakeHttp({
        _feed: _guarded((_, _) => textResponse(_manifest())),
        _dlFeed: (_, _) => textResponse(fixture('update.json')),
        _githubFeed: (_, _) => textResponse(fixture('update.json')),
      });
      final result = await UpdateChecker(http: http, sources: sources).check(preferred: 'api');
      expect(http.urls, [_feed, _dlFeed, _githubFeed]);
      _expectTokenOnlyOnChannel(http);
      final found = result as CheckFound;
      expect(found.endpoint.id, 'beta');
      expect(found.endpoint.mirrorId, isNull);
      expect(found.release.version.toString(), '1.2.0+10261200');
      expect(found.release.apks[ApkFlavor.arm64]!.url.toString(), _betaApk);
      expect(found.release.pageUrl.toString(), 'https://go.dshtui.com/beta');
    });

    test('a newer public release wins over an older reachable beta channel', () async {
      final http = FakeHttp({
        _feed: _guarded((_, _) => textResponse(_manifest())),
        _githubFeed: (_, _) => textResponse(fixture('update.json').replaceAll('1.2.0', '1.4.0')),
      });
      final result = await UpdateChecker(http: http, sources: sources).check();
      expect((result as CheckFound).release.version.toString(), '1.4.0+7');
      expect(result.endpoint.id, 'manifest:github');
      _expectTokenOnlyOnChannel(http);
    });

    test('the channel refuses (token revoked) or is down: the public sources answer, without the token', () async {
      for (final route in <Route?>[(_, _) => textResponse('Unauthorized', status: 401), null]) {
        var http = FakeHttp({_feed: ?route, _dlFeed: (_, _) => textResponse(fixture('update.json'))});
        var result = await UpdateChecker(http: http, sources: sources).check();
        expect(http.urls, [_feed, _dlFeed, _githubFeed, _api]);
        expect((result as CheckFound).endpoint.id, 'feed');
        _expectTokenOnlyOnChannel(http);

        http = FakeHttp({_feed: ?route, _api: (_, _) => textResponse(fixture('github_release.json'))});
        result = await UpdateChecker(http: http, sources: sources).check();
        expect(http.urls.first, _feed);
        expect(http.urls.last, _api);
        expect((result as CheckFound).endpoint.id, 'api');
        _expectTokenOnlyOnChannel(http);
      }
    });
  });

  group('downloading', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('dsh_beta_download'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('from the channel with the token, resuming with it too', () async {
      var calls = 0;
      final full = fileRoute(_bytes);
      final dropping = fileRoute(_bytes, dropAfter: 12);
      final http = FakeHttp({
        _betaApk: _guarded((url, headers) => calls++ == 0 ? dropping(url, headers) : full(url, headers)),
      });
      final outcome = await ApkDownloader(http: http, directory: dir).download(
        fileName: _apk,
        sha256: sha256.convert(_bytes).toString(),
        urls: sources.downloadUrls([Uri.parse(_betaApk), Uri.parse(_githubApk)]),
        expectedSize: _bytes.length,
      );
      expect(outcome, isA<DownloadDone>());
      expect(await (outcome as DownloadDone).file.readAsBytes(), _bytes);
      expect(http.requests.length, 2);
      expect(http.requests.last.$2['range'], 'bytes=12-');
      expect(http.requests.every((r) => r.$2['authorization'] == _auth), isTrue);
    });

    test('channel refuses: GitHub and accelerators, without the token', () async {
      final http = FakeHttp({
        _betaApk: (_, _) => textResponse('Unauthorized', status: 401),
        _githubApk: fileRoute(_bytes),
      });
      final outcome = await ApkDownloader(http: http, directory: dir).download(
        fileName: _apk,
        sha256: sha256.convert(_bytes).toString(),
        urls: sources.downloadUrls([Uri.parse(_betaApk), Uri.parse(_githubApk)]),
      );
      expect((outcome as DownloadDone).from!.url.toString(), _githubApk);
      _expectTokenOnlyOnChannel(http);
    });

    test('SHA256SUMS from the channel carries the token', () async {
      const sums = 'https://go.dshtui.com/beta/1.2.0/SHA256SUMS';
      final hex = sha256.convert(_bytes).toString();
      final http = FakeHttp({sums: _guarded((_, _) => textResponse('$hex  $_apk\n'))});
      expect(await fetchSha256FromSums(http, sources.downloadUrls([Uri.parse(sums)]), _apk), hex);
    });
  });

  group('in the app', () {
    late Directory dir;
    late FakeHttp http;
    late FakeInstaller installer;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('dsh_beta_state');
      http = FakeHttp({_feed: _guarded((_, _) => textResponse(_manifest())), _betaApk: _guarded(fileRoute(_bytes))});
      installer = FakeInstaller();
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => dir.deleteSync(recursive: true));

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          updateHttpProvider.overrideWithValue(http),
          updateInstallerProvider.overrideWithValue(installer),
          updateSourcesProvider.overrideWithValue(sources),
          updateClockProvider.overrideWithValue(() => DateTime(2026, 11, 2, 9)),
          updateFlavorNameProvider.overrideWithValue('arm64'),
          updateDirectoryProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('check → offer → download with the token → install', () async {
      final c = container();
      final controller = c.read(appUpdateProvider.notifier);
      await controller.ready;
      expect(await controller.autoCheckIfDue(), isTrue);
      expect(c.read(appUpdateProvider).latest!.version.name, '1.2.0');
      await controller.startDownload();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(c.read(appUpdateProvider).source, 'go.dshtui.com');
      await controller.install();
      expect(installer.calls, containsAllInOrder(['inspect', 'install']));
      expect(http.urls, [_feed, _dlFeed, _githubFeed, _api, _betaApk]);
      _expectTokenOnlyOnChannel(http);
    });

    test('an offer remembered from yesterday still downloads from the channel', () async {
      final first = container();
      final controller = first.read(appUpdateProvider.notifier);
      await controller.ready;
      await controller.check();

      http.requests.clear();
      final second = container();
      final again = second.read(appUpdateProvider.notifier);
      await again.ready;
      expect(second.read(appUpdateProvider).hasUpdate, isTrue);
      await again.startDownload();
      expect(second.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(http.urls, [_betaApk]);
      _expectTokenOnlyOnChannel(http);
    });
  });
}
