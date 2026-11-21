// Regression for the local checkpoint corpus reader in session search: it must
// use asynchronous File IO (await stat/readAsString), so the search page never
// blocks the UI isolate on a burst of synchronous stat/read calls.
// Real File I/O needs test() here; a testWidgets body would need runAsync.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart' show FakePluginCarrier;
import 'support.dart';

/// Counts the asynchronous IO the production reader performs.
class _IoCounts {
  int stats = 0;
  int reads = 0;
}

/// A [File] that only exposes the asynchronous API. The synchronous methods
/// fail loudly, so an implementation that still calls statSync/readAsStringSync
/// reads no checkpoint and cannot pass this test.
class _AsyncOnlyFile implements File {
  _AsyncOnlyFile(this._inner, this._counts);

  final File _inner;
  final _IoCounts _counts;

  @override
  String get path => _inner.path;

  @override
  Future<FileStat> stat() {
    _counts.stats++;
    return _inner.stat();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    _counts.reads++;
    return _inner.readAsString(encoding: encoding);
  }

  @override
  FileStat statSync() => throw UnsupportedError('the search page must not stat files synchronously');

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      throw UnsupportedError('the search page must not read files synchronously');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [GuestFs] whose files are [_AsyncOnlyFile]s.
class _FixtureGuestFs extends GuestFs {
  _FixtureGuestFs(super.root);

  final counts = _IoCounts();

  @override
  File file(String guestPath) => _AsyncOnlyFile(super.file(guestPath), counts);
}

class _LocalHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

/// A session_projcache document with one turn per prompt in record.rows.
String _checkpointJson(String pendingPrompt) => jsonEncode({
  'version': 7,
  'record': {
    'identity': {'formatVersion': 4},
    'rows': {
      'turnOutline': {
        'ver': 2,
        'seq': 20,
        'val': {
          'turns': [
            {'turn': 1, 'seq': 4, 'prompt': '第一问', 'response': '第一答'},
            {'turn': 2, 'seq': 14, 'prompt': pendingPrompt, 'response': '第二答'},
          ],
          'draft': '',
        },
      },
    },
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('local checkpoint corpus reads files asynchronously and re-reads changed files', () async {
    final root = await Directory.systemTemp.createTemp('dsh_search_ckpt_');
    addTearDown(() => root.delete(recursive: true));
    // GuestFs joins this onto its root again: the guest path starts with /root/.dsh.
    final checkpointDir = Directory('${root.path}/root/.dsh/storages/session_projcache/sessions');
    await checkpointDir.create(recursive: true);
    final checkpoint = File('${checkpointDir.path}/s1.json');
    await checkpoint.writeAsString(_checkpointJson('磁盘里的排队问题'));
    final guestFs = _FixtureGuestFs(root);

    final client = DshClient.withCarrier(FakePluginCarrier()..handlers['session/search'] = (_) => throw searchDisabled);
    addTearDown(client.close);

    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        activeHostProvider.overrideWith(_LocalHost.new),
        activeConnectionProvider.overrideWithValue(
          AsyncValue<HostConnection?>.data(HostConnection(client: client, isLocal: true)),
        ),
        sessionsProvider.overrideWith(() => SearchSessions([searchSession('s1', null, DateTime(2026, 10, 20))])),
        guestFsProvider.overrideWith((ref) async => guestFs),
      ],
    );
    addTearDown(container.dispose);
    // The corpus reader needs the settled session list; let its provider finish.
    await container.read(sessionsProvider.future);

    final backend = container.read(sessionContentSearchProvider);
    expect(backend, isNotNull);

    final first = await backend!.search('磁盘里的排队');
    expect(first.items.map((hit) => hit.sessionId), ['s1']);
    expect(first.items.single.snippet, contains('磁盘里的排队'));
    expect(guestFs.counts.stats, 1);
    expect(guestFs.counts.reads, 1);

    // The unchanged file is answered from the stat cache: stat again, no read.
    final second = await backend.search('磁盘里的排队');
    expect(second.items.map((hit) => hit.sessionId), ['s1']);
    expect(guestFs.counts.stats, 2);
    expect(guestFs.counts.reads, 1);

    // A size change invalidates the cached entry: the new text becomes searchable.
    await checkpoint.writeAsString(_checkpointJson('更新后的排队问题，比上一次更长的内容'));
    final third = await backend.search('更新后的排队');
    expect(third.items.map((hit) => hit.sessionId), ['s1']);
    expect(third.items.single.snippet, contains('更新后的排队'));
    expect(guestFs.counts.stats, 3);
    expect(guestFs.counts.reads, 2);
  });
}
