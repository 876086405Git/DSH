// User API Key sign-in: the RSA half against OpenSSL (the library Discourse's
// Ruby uses), the authorize URL, the redirect, sign-out; and the HTTP client's
// headers, paths and error mapping.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_config.dart';
import 'package:dsh_app/forum/forum_crypto.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FakeBrowser;
import 'support.dart';

final _keys = ForumKeyPair.fromJson(fixture('rsa_key.json'))!;
const _payload =
    '{"key":"0123456789abcdef0123456789abcdef","nonce":"c0ffee00c0ffee00c0ffee00c0ffee00","push":false,"api":4}';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('RSA', () {
    test('decrypts what OpenSSL encrypted with OAEP and with PKCS#1 v1.5', () {
      // `openssl pkeyutl -encrypt -pkeyopt rsa_padding_mode:oaep|pkcs1` with
      // the fixture's public key, base64 with line breaks (like Ruby's
      // Base64.encode64).
      expect(utf8.decode(decryptForumPayload(fixtureText('rsa_oaep.b64'), _keys)), _payload);
      expect(utf8.decode(decryptForumPayload(fixtureText('rsa_pkcs1.b64'), _keys)), _payload);
    });

    test('the public key is a SubjectPublicKeyInfo PEM OpenSSL reads', () async {
      final pem = _keys.publicPem;
      expect(pem, startsWith('-----BEGIN PUBLIC KEY-----\n'));
      expect(pem.trim(), endsWith('-----END PUBLIC KEY-----'));
      expect(pem.split('\n').where((l) => !l.startsWith('-----') && l.isNotEmpty).every((l) => l.length <= 64), isTrue);
      final dir = await Directory.systemTemp.createTemp('forum-pem');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/pub.pem')..writeAsStringSync(pem);
      final ProcessResult result;
      try {
        result = await Process.run('openssl', ['pkey', '-pubin', '-in', file.path, '-noout', '-text']);
      } on ProcessException {
        markTestSkipped('no openssl on this machine');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect('${result.stdout}', contains('2048 bit'));
    });

    test('round trip with a fresh key; garbage and another key are refused', () {
      final fresh = generateForumKeyPairSync();
      expect(fresh.bits, 2048);
      final cipher = base64.encode(encryptForumPayload(utf8.encode(_payload), fresh));
      expect(utf8.decode(decryptForumPayload(cipher, fresh)), _payload);
      expect(() => decryptForumPayload(cipher, _keys), throwsFormatException);
      expect(() => decryptForumPayload('not base64!!', fresh), throwsFormatException);
      expect(ForumKeyPair.fromJson(fresh.toJson())!.modulus, fresh.modulus);
    });
  });

  group('sign-in', () {
    late MemorySecretStore store;
    late FakeBrowser browser;
    late FakeForumApi api;
    late List<(Uri, ForumCredentials?)> built;

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          forumSecretStoreProvider.overrideWithValue(store),
          forumKeyPairFactoryProvider.overrideWithValue(() async => _keys),
          accountBrowserProvider.overrideWithValue(browser),
          forumApiFactoryProvider.overrideWithValue((base, credentials) {
            built.add((base, credentials));
            return api;
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      store = MemorySecretStore();
      browser = FakeBrowser();
      api = FakeForumApi(signedIn: true, user: sampleUser);
      built = [];
    });

    Future<void> settled(ProviderContainer c) async {
      c.read(forumAuthProvider);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('opens the authorize page with the app parameters', () async {
      final c = container();
      await settled(c);
      expect(c.read(forumAuthProvider).phase, ForumAuthPhase.signedOut);
      expect(await c.read(forumAuthProvider.notifier).signIn(), isTrue);
      expect(c.read(forumAuthProvider).phase, ForumAuthPhase.waiting);
      final url = browser.opened.single;
      expect(url.toString(), startsWith('$forumDefaultBaseUrl/user-api-key/new?'));
      final q = url.queryParameters;
      expect(q['application_name'], 'dsh-go');
      expect(q['scopes'], 'read,write,notifications,session_info');
      expect(q['auth_redirect'], 'dshgo://forum/auth');
      expect(q['padding'], 'oaep');
      expect(q['public_key'], _keys.publicPem);
      expect(q['nonce'], hasLength(32));
      expect(q['client_id'], hasLength(32));
      // The pending nonce survives the app being killed.
      final pending = jsonDecode((await store.read('pending'))!) as Map;
      expect(pending['nonce'], q['nonce']);
    });

    test('the redirect signs in: key stored, user fetched', () async {
      final c = container();
      await settled(c);
      await c.read(forumAuthProvider.notifier).signIn();
      final nonce = browser.opened.single.queryParameters['nonce'];
      final payload = jsonEncode({'key': 'user-api-key-1', 'nonce': nonce, 'push': false, 'api': 4});
      // Ruby's Base64.encode64 breaks lines every 60 characters.
      final b64 = base64.encode(encryptForumPayload(utf8.encode(payload), _keys));
      final wrapped = [for (var i = 0; i < b64.length; i += 60) b64.substring(i, (i + 60).clamp(0, b64.length))]
          .join('\n');
      final ok = await c
          .read(forumAuthProvider.notifier)
          .handleRedirect(Uri.parse('dshgo://forum/auth?payload=${Uri.encodeQueryComponent('$wrapped\n')}'));
      expect(ok, isTrue);
      await settled(c);
      final state = c.read(forumAuthProvider);
      expect(state.signedIn, isTrue);
      expect(state.credentials!.key, 'user-api-key-1');
      expect(state.user?.username, 'chimney');
      expect(await store.read('pending'), isNull);
      final saved = jsonDecode((await store.read('session:$forumDefaultBaseUrl'))!) as Map;
      expect(saved['key'], 'user-api-key-1');
      expect(built.last.$2?.key, 'user-api-key-1');

      // A new container (app restart) restores the session.
      final again = container();
      await settled(again);
      expect(again.read(forumAuthProvider).signedIn, isTrue);
    });

    test('a wrong nonce or a foreign payload is refused', () async {
      final c = container();
      await settled(c);
      await c.read(forumAuthProvider.notifier).signIn();
      final payload = jsonEncode({'key': 'k', 'nonce': 'someone-else', 'api': 4});
      final b64 = base64.encode(encryptForumPayload(utf8.encode(payload), _keys));
      final notifier = c.read(forumAuthProvider.notifier);
      expect(
        await notifier.handleRedirect(Uri.parse('dshgo://forum/auth?payload=${Uri.encodeQueryComponent(b64)}')),
        isFalse,
      );
      expect(c.read(forumAuthProvider).signedIn, isFalse);
      expect(c.read(forumAuthProvider).error, '登录没有完成，请重试');
      expect(await notifier.handleRedirect(Uri.parse('dshgo://forum/auth')), isFalse);
    });

    test('sign-out revokes the key and forgets it; a dead key signs out', () async {
      await store.write('session:$forumDefaultBaseUrl', jsonEncode({'key': 'k1', 'client': 'c1'}));
      final c = container();
      await settled(c);
      expect(c.read(forumAuthProvider).signedIn, isTrue);
      await c.read(forumAuthProvider.notifier).signOut();
      expect(api.calls, contains('revoke'));
      expect(c.read(forumAuthProvider).signedIn, isFalse);
      expect(await store.read('session:$forumDefaultBaseUrl'), isNull);

      await store.write('session:$forumDefaultBaseUrl', jsonEncode({'key': 'k2', 'client': 'c1'}));
      api.user = null; // currentUser → forbidden, as with a revoked key
      final d = container();
      await settled(d);
      expect(d.read(forumAuthProvider).signedIn, isFalse);
      expect(d.read(forumAuthProvider).error, '登录已失效，请重新登录');
    });

    for (final (os, made) in [('android', 1), ('ohos', 2)]) {
      test('on $os a rebuild ${made == 1 ? 'keeps the pair it holds' : 'reads the pair again'}', () async {
        var pairs = 0;
        final c = ProviderContainer(
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            forumSecretStoreProvider.overrideWithValue(store),
            forumKeyPairFactoryProvider.overrideWithValue(() async {
              pairs++;
              return _keys;
            }),
            accountBrowserProvider.overrideWithValue(browser),
            forumApiFactoryProvider.overrideWithValue((base, credentials) => api),
          ],
        );
        addTearDown(c.dispose);
        await settled(c);
        await c.read(forumAuthProvider.notifier).authorizeUrl();
        expect(pairs, 1);
        // What a failed read of the store looks like from here: the saved pair is gone.
        await store.delete('rsa');
        c.invalidate(forumAuthProvider);
        await settled(c);
        await c.read(forumAuthProvider.notifier).authorizeUrl();
        expect(pairs, made);
      });
    }

    test('a custom forum address keeps its own session', () async {
      SharedPreferences.setMockInitialValues({'forum.baseUrl': 'https://bbs.example.com'});
      final c = container();
      await settled(c);
      expect(c.read(forumBaseUrlProvider), 'https://bbs.example.com');
      await c.read(forumAuthProvider.notifier).signIn();
      expect(browser.opened.single.host, 'bbs.example.com');
      expect(await c.read(forumBaseUrlProvider.notifier).set('not a url'), isFalse);
      expect(await c.read(forumBaseUrlProvider.notifier).set(''), isTrue);
      expect(c.read(forumBaseUrlProvider), forumDefaultBaseUrl);
    });

    test('normalizes typed addresses', () {
      expect(normalizeForumBaseUrl('forum.example.com/'), 'https://forum.example.com');
      expect(normalizeForumBaseUrl('http://10.0.0.2:4200'), 'http://10.0.0.2:4200');
      expect(normalizeForumBaseUrl('https://example.com/bbs/'), 'https://example.com/bbs');
      expect(normalizeForumBaseUrl('ftp://example.com'), isNull);
      expect(normalizeForumBaseUrl(''), isNull);
    });
  });

  group('HTTP client', () {
    test('signed requests carry the key headers; paths per feed', () async {
      final seen = <http.BaseRequest>[];
      final client = DiscourseClient(
        baseUrl: Uri.parse('https://forum.test'),
        credentials: const ForumCredentials(key: 'KEY', clientId: 'CID'),
        client: MockClient((request) async {
          seen.add(request);
          return http.Response.bytes(utf8.encode(fixtureText('meta_latest.json')), 200);
        }),
      );
      await client.topics(const ForumFeed.latest(), page: 2);
      await client.topics(const ForumFeed.top());
      await client.topics(ForumFeed.category(sampleCategories[1]));
      expect(seen.map((r) => r.url.toString()), [
        'https://forum.test/latest.json?page=2',
        'https://forum.test/top.json?period=monthly',
        'https://forum.test/c/plugins/2/l/latest.json',
      ]);
      expect(seen.first.headers['User-Api-Key'], 'KEY');
      expect(seen.first.headers['User-Api-Client-Id'], 'CID');
      expect(seen.first.headers['Accept'], 'application/json');
    });

    test('anonymous requests carry no key; post ids go as post_ids[]', () async {
      late Uri url;
      late Map<String, String> headers;
      final client = DiscourseClient(
        baseUrl: Uri.parse('https://forum.test'),
        client: MockClient((request) async {
          url = request.url;
          headers = request.headers;
          return http.Response.bytes(utf8.encode(fixtureText('meta_posts_322376.json')), 200);
        }),
      );
      final posts = await client.posts(322376, [11, 12]);
      expect(posts, hasLength(20));
      expect(url.queryParametersAll['post_ids[]'], ['11', '12']);
      expect(headers.containsKey('User-Api-Key'), isFalse);
    });

    test('writes: form fields, like, bookmark, upload, revoke', () async {
      final seen = <http.BaseRequest>[];
      final bodies = <String>[];
      final client = DiscourseClient(
        baseUrl: Uri.parse('https://forum.test'),
        credentials: const ForumCredentials(key: 'KEY', clientId: 'CID'),
        client: MockClient((request) async {
          seen.add(request);
          bodies.add(request.body);
          final path = request.url.path;
          if (path == '/posts.json') {
            return http.Response('{"id":9,"post_number":2,"topic_id":5,"cooked":"<p>hi</p>"}', 200);
          }
          if (path == '/bookmarks.json') return http.Response('{"success":"OK","id":77}', 200);
          if (path == '/uploads.json') {
            return http.Response('{"short_url":"upload://x.png","url":"/u/x.png","original_filename":"x.png"}', 200);
          }
          return http.Response('{"success":"OK"}', 200);
        }),
      );
      final reply = await client.reply(topicId: 5, raw: '你好', replyToPostNumber: 1);
      expect(reply.post!.postNumber, 2);
      expect(Uri.splitQueryString(bodies.last), {'topic_id': '5', 'raw': '你好', 'reply_to_post_number': '1'});
      await client.createTopic(title: '标题', raw: '正文', categoryId: 2);
      expect(Uri.splitQueryString(bodies.last), {'title': '标题', 'raw': '正文', 'category': '2', 'archetype': 'regular'});
      await client.like(9);
      expect(seen.last.method, 'POST');
      expect(Uri.splitQueryString(bodies.last)['post_action_type_id'], '2');
      await client.unlike(9);
      expect(
        '${seen.last.method} ${seen.last.url}',
        'DELETE https://forum.test/post_actions/9.json?post_action_type_id=2',
      );
      expect(await client.bookmark(9), 77);
      await client.removeBookmark(77);
      expect(seen.last.url.path, '/bookmarks/77.json');
      final upload = await client.upload([1, 2, 3], 'x.png');
      expect(upload.shortUrl, 'upload://x.png');
      expect(seen.last.headers['content-type'], startsWith('multipart/form-data'));
      await client.revokeKey();
      expect('${seen.last.method} ${seen.last.url.path}', 'POST /user-api-key/revoke');
      await client.markNotificationsRead();
      expect('${seen.last.method} ${seen.last.url.path}', 'PUT /notifications/mark-read.json');
    });

    test('errors: Discourse messages kept, statuses mapped', () async {
      var status = 422;
      var body = '{"errors":["标题太短（最少 6 个字）"],"error_type":"invalid_parameters"}';
      final client = DiscourseClient(
        baseUrl: Uri.parse('https://forum.test'),
        client: MockClient((_) async => http.Response.bytes(utf8.encode(body), status)),
      );
      Future<ForumException> fail() async {
        try {
          await client.createTopic(title: 'x', raw: 'y');
        } on ForumException catch (e) {
          return e;
        }
        throw StateError('no error');
      }

      expect((await fail()).message, '标题太短（最少 6 个字）');
      status = 429;
      body = '{"errors":["You’ve performed this action too many times."],"error_type":"rate_limit"}';
      expect((await fail()).kind, ForumErrorKind.rateLimited);
      expect((await fail()).message, '操作太频繁，稍后再试');
      status = 403;
      body = '{"errors":["您需要登录才能执行此操作。"],"error_type":"not_logged_in"}';
      expect((await fail()).kind, ForumErrorKind.forbidden);
      status = 502;
      body = '<html>bad gateway</html>';
      expect((await fail()).message, '论坛暂时出了问题');
      final offline = DiscourseClient(
        baseUrl: Uri.parse('https://forum.test'),
        client: MockClient((_) async => throw http.ClientException('no route')),
      );
      expect(() => offline.site(), throwsA(isA<ForumException>().having((e) => e.message, 'message', '没能连上论坛')));
    });
  });
}
