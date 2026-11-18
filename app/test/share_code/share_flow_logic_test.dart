import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/restore_point.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_import.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine.dart';

const _integrity = 'sha512-41Cifkg6e8TylSpdtTpeLVMqvSBEVzTttHvERD741+pnZ8ANv0004MRL43QKPDlK9cGvNp6NZWZUBlbGXYxxng==';

HostConnection _host(DshClient client, {bool local = true, String label = '本机'}) => HostConnection(
  client: client,
  label: label,
  isLocal: local,
  kind: local ? HostKind.local : HostKind.ssh,
  hostId: local ? null : 'mac',
);

FakeEngine _sourceEngine() {
  final e = FakeEngine()
    ..addSettings('subagent', base: {'maxDepth': 1}, user: {'maxDepth': 3})
    ..addSettings(
      'web-search-deepseek',
      base: {'model': 'flash'},
      user: {'apiKeyEnv': 'MY_KEY', 'apiKey': 'sk-abcdefabcdef1234567890'},
    )
    ..addSettings('ui-settings-account', user: {'step': 3})
    ..addSettings('ui-theme', base: {'preference': 'system'})
    ..addBundle(
      'dsh-notes',
      version: '1.4.2',
      source: 'dsh-notes@^1.4.0',
      title: '读书笔记',
      rows: [
        {'rowId': 'preset-writer', 'moduleName': agentPresetModule},
        {'rowId': 'notes', 'moduleName': 'dsh-notes'},
      ],
    )
    ..addBundle('dsh-writer', version: '2.0.0', source: 'github:acme/dsh-writer#v2.0.0')
    ..addBundle('my-local', version: '0.0.1', source: '/root/plugins/my-local')
    ..addBundle(
      '@deepseek-ai/dsh-experimental-session-titles-bundle',
      official: true,
      optional: true,
      enabled: true,
      installed: false,
    )
    ..addBundle(
      '@deepseek-ai/dsh-experimental-terminal-bundle',
      official: true,
      optional: true,
      enabled: false,
      installed: false,
    )
    ..addBundle('@deepseek-ai/dsh-base', installed: false);
  e.presets.add({'id': 'writer', 'name': '写作'});
  return e;
}

void main() {
  group('export', () {
    late GuestFs fs;
    setUp(() {
      fs = tempGuest();
      writeGuest(fs, '/root/.dsh/skills/outline/SKILL.md', '---\nname: outline\ndescription: 列提纲\n---\n先列提纲。');
      writeGuest(fs, '/root/.dsh/skills/outline/scripts/count.sh', 'wc -l "\$1"');
      writeGuest(fs, '/root/.dsh/skills/quick.md', '---\nname: quick\ndescription: "快速回答"\n---\n简短。');
      writeGuest(fs, '/root/.dsh/skills/.system/hidden/SKILL.md', 'x');
      writeGuest(fs, '/root/.dsh/AGENTS.md', '<!-- dsh-app:managed -->\n托管内容');
      writeGuest(fs, '/root/.agents/AGENTS.md', '# 我的习惯\n回答用中文。\n');
    });
    tearDown(() => fs.root.parent.deleteSync(recursive: true));

    test('lists what can travel, with sizes, and builds the share from the ticks', () async {
      final client = DshClient.withCarrier(_sourceEngine());
      final source = await loadProfileExport(client, hostLabel: '本机', isLocal: true, fs: fs);

      expect(source.section(ExportSection.settings).map((i) => i.id), [
        'settings:subagent',
        'settings:web-search-deepseek',
      ]);
      expect(source.settings['web-search-deepseek'], {'apiKeyEnv': 'MY_KEY'});
      final plugins = {for (final i in source.section(ExportSection.plugins)) i.id: i};
      expect(plugins.keys, [
        'plugin:dsh-notes',
        'plugin:dsh-writer',
        'plugin:my-local',
        'plugin:@deepseek-ai/dsh-experimental-session-titles-bundle',
      ]);
      expect(plugins['plugin:dsh-notes']!.subtitle, 'npm · 1.4.2 · 含预设「写作」');
      expect(plugins['plugin:dsh-writer']!.subtitle, 'GitHub · acme/dsh-writer');
      expect(plugins['plugin:my-local']!.available, isFalse);
      expect(source.section(ExportSection.skills).map((i) => i.title), ['outline', 'quick']);
      expect(source.section(ExportSection.skills).first.subtitle, '列提纲');
      expect(source.section(ExportSection.agentsMd).single.defaultOn, isFalse);
      expect(source.items.every((i) => !i.available || i.bytes > 0), isTrue);

      final selected = source.defaultSelection;
      expect(selected.contains('agents-md'), isFalse);
      expect(selected.contains('plugin:my-local'), isFalse);
      final share = source.build({...selected, 'agents-md'}, now: DateTime.utc(2026, 10, 24));
      expect(share.plugins.map((p) => p.spec), ['dsh-notes@1.4.2', 'github:acme/dsh-writer#v2.0.0', null]);
      expect(share.presets.single.id, 'writer');
      expect(
        share.skills.firstWhere((s) => s.name == 'outline').files.keys,
        unorderedEquals(['SKILL.md', 'scripts/count.sh']),
      );
      expect(share.agentsMd, contains('回答用中文'));

      final back = decodeShareCode(encodeShareCode(share)) as ProfileShare;
      expect(back.toJson(), share.toJson());

      // Without a plugin, its preset doesn't travel either.
      expect(source.build(selected.difference({'plugin:dsh-notes'})).presets, isEmpty);
    });

    test('a remote engine offers no files', () async {
      final client = DshClient.withCarrier(_sourceEngine());
      final source = await loadProfileExport(client, hostLabel: 'Mac · SSH', isLocal: false, fs: fs);
      expect(source.section(ExportSection.skills), isEmpty);
      expect(source.section(ExportSection.agentsMd), isEmpty);
    });

    test('npm integrity is added when the registry answers', () async {
      final net = FakeShareNet()..npm['dsh-notes@1.4.2'] = const NpmFacts(integrity: _integrity, publisher: 'acme');
      final share = await withProfileNpmFacts(
        net,
        const ProfileShare(
          plugins: [
            SharedPlugin(name: 'dsh-notes', source: PluginSourceKind.npm, spec: 'dsh-notes@1.4.2', version: '1.4.2'),
          ],
        ),
      );
      expect(share.plugins.single.integrity, _integrity);
      expect(share.plugins.single.author, 'acme');
    });
  });

  group('import', () {
    late GuestFs fs;
    late FakeEngine engine;
    late DshClient client;
    late FakeShareNet net;

    ProfileShare profile({String integrity = _integrity}) => ProfileShare(
      settings: const {
        'subagent': {'maxDepth': 3},
        'ui-theme': {'preference': 'system'},
        'cot-translation': {'target': 'zh'},
      },
      plugins: [
        SharedPlugin(
          name: 'dsh-notes',
          source: PluginSourceKind.npm,
          spec: 'dsh-notes@1.4.2',
          version: '1.4.2',
          integrity: integrity,
          title: '读书笔记',
        ),
        const SharedPlugin(name: 'dsh-writer', source: PluginSourceKind.github, spec: 'github:acme/dsh-writer#v2.0.0'),
        const SharedPlugin(
          name: '@deepseek-ai/dsh-experimental-session-titles-bundle',
          source: PluginSourceKind.official,
          title: '对话标题',
        ),
      ],
      presets: const [
        SharedPreset(id: 'writer', name: '写作', bundle: 'dsh-notes'),
        SharedPreset(id: 'standard', bundle: 'dsh-notes'),
      ],
      skills: const [
        SharedSkill(name: 'outline', files: {'SKILL.md': '新的提纲技能'}),
        SharedSkill(name: 'quick', files: {'SKILL.md': '简短'}),
      ],
      agentsMd: '回答用中文。',
    );

    setUp(() {
      fs = tempGuest();
      writeGuest(fs, '/root/.dsh/skills/outline/SKILL.md', '旧的提纲技能');
      writeGuest(
        fs,
        '/root/.dsh/profiles/web/package.json',
        jsonEncode({
          'dependencies': {'dsh-notes': '1.2.0'},
          'dsh': {
            'profile': {
              'bundles': ['@deepseek-ai/dsh-web-app', 'dsh-notes'],
            },
          },
        }),
      );
      writeGuest(
        fs,
        '/root/.dsh/profiles/web/node_modules/dsh-notes/package.json',
        '{"name":"dsh-notes","version":"1.2.0"}',
      );
      writeGuest(fs, '/root/.dsh/profiles/web/cordis.patch.yml', 'subagent:\n  maxDepth: 2\n');
      engine = FakeEngine()
        ..addSettings('subagent', base: {'maxDepth': 1})
        ..addSettings('ui-theme', base: {'preference': 'system'})
        ..addBundle('dsh-notes', version: '1.2.0', source: 'dsh-notes@1.2.0')
        ..addBundle(
          '@deepseek-ai/dsh-experimental-session-titles-bundle',
          official: true,
          optional: true,
          enabled: false,
          installed: false,
        );
      engine.presets.add({'id': 'standard'});
      client = DshClient.withCarrier(engine);
      net = FakeShareNet()
        ..npm['dsh-notes@1.4.2'] = const NpmFacts(integrity: _integrity, publisher: 'acme', unpackedSize: 9615);
    });
    tearDown(() => fs.root.parent.deleteSync(recursive: true));

    test('the diff: upgrades, installs, switches, presets, settings, files', () async {
      final plan = await planImport(profile(), ImportTarget(_host(client), isActive: true), net: net, fs: fs);
      final byId = {for (final c in plan.changes) c.id: c};

      final notes = byId['plugin:dsh-notes']!;
      expect(notes.kind, ChangeKind.upgrade);
      expect(notes.detail, '1.2.0 → 1.4.2');
      expect(notes.integrity, IntegrityStatus.verified);
      expect(notes.facts?.publisher, 'acme');
      expect(byId['plugin:dsh-writer']!.kind, ChangeKind.install);
      expect(byId['plugin:dsh-writer']!.integrity, IntegrityStatus.unverifiable);
      expect(byId['plugin:@deepseek-ai/dsh-experimental-session-titles-bundle']!.kind, ChangeKind.enable);

      expect(byId['preset:writer']!.follows, 'plugin:dsh-notes');
      expect(byId.containsKey('preset:standard'), isFalse, reason: 'already there');

      expect(byId['settings:subagent']!.detail, 'maxDepth 1 → 3');
      expect(byId['settings:subagent']!.kind, ChangeKind.change);
      expect(byId.containsKey('settings:ui-theme'), isFalse, reason: 'already the same');
      expect(byId['settings:cot-translation']!.detail, startsWith('装好插件后应用'));

      expect(byId['skill:outline']!.kind, ChangeKind.change);
      expect(byId['skill:outline']!.defaultOn, isFalse);
      expect(byId['skill:quick']!.kind, ChangeKind.add);
      expect(byId['skill:quick']!.defaultOn, isFalse);
      expect(plan.defaultSelection, isNot(contains('agents-md')));
      expect(byId['agents-md']!.kind, ChangeKind.add);

      expect(plan.defaultSelection, isNot(contains('skill:outline')));
      expect(plan.defaultSelection, isNot(contains('preset:writer')), reason: 'presets follow their plugin');
    });

    test('an engine that refuses market installs blocks the plugin rows and says so', () async {
      final plan = await planImport(
        profile(),
        ImportTarget(_host(client), isActive: true, installRefused: true),
        net: net,
        fs: fs,
      );
      expect(plan.changes.firstWhere((c) => c.id == 'plugin:dsh-writer').blocked, '这个引擎不能安装市场插件');
    });

    test('a changed package or a host that cannot install blocks the plugin rows', () async {
      final mismatch = await planImport(
        profile(integrity: 'sha512-AAAA'),
        ImportTarget(_host(client), isActive: true),
        net: net,
        fs: fs,
      );
      expect(mismatch.changes.firstWhere((c) => c.id == 'plugin:dsh-notes').blocked, '与分享时的版本不一致');
      expect(mismatch.changes.firstWhere((c) => c.id == 'plugin:dsh-notes').integrity, IntegrityStatus.mismatch);

      final relay = DshClient.withCarrier(FakeEngine(allowInstall: false)..addSettings('subagent'));
      final plan = await planImport(
        profile(),
        ImportTarget(_host(relay, local: false, label: 'Mac · 远程'), isActive: true),
        net: net,
        fs: fs,
      );
      expect(plan.changes.firstWhere((c) => c.id == 'plugin:dsh-writer').blocked, '这台主机不能从这里安装插件');
      expect(plan.changes.firstWhere((c) => c.id == 'skill:quick').blocked, '只能导入到本机');
      expect(plan.changes.firstWhere((c) => c.id == 'agents-md').toggleable, isFalse);

      final safe = await planImport(
        profile(),
        ImportTarget(_host(client), isActive: true, safeMode: true),
        net: net,
        fs: fs,
      );
      expect(safe.changes.firstWhere((c) => c.id == 'plugin:dsh-writer').blocked, '安全模式下不能安装插件');
    });

    test('applies in order, pins a restore point first, backs up replaced files', () async {
      final plan = await planImport(profile(), ImportTarget(_host(client), isActive: false), net: net, fs: fs);
      final steps = <String>[];
      final result = await applyImport(
        plan,
        {...plan.defaultSelection, 'skill:outline', 'skill:quick', 'agents-md'},
        runner: DirectPluginRunner(client, isLocal: true),
        fs: fs,
        onStep: (id, s) {
          if (s.state == ImportStepState.done) steps.add(id);
        },
        now: () => DateTime(2026, 10, 24, 15, 30, 12),
      );
      expect(result.failed, 0);
      expect(result.restorePoint, isTrue);
      // The upgrade replaced a loaded bundle: restart to apply, though `applied`.
      expect(result.needsRestart, isTrue);
      expect(result.statuses['plugin:dsh-notes']!.message, '重启后生效');
      expect(result.statuses['plugin:dsh-writer']!.message, isNull);
      expect(steps, [
        'plugin:dsh-notes',
        'plugin:dsh-writer',
        'plugin:@deepseek-ai/dsh-experimental-session-titles-bundle',
        'preset:writer',
        'settings:subagent',
        'skill:outline',
        'skill:quick',
        'agents-md',
      ]);
      expect(engine.argsOf('pluginManager/removeBundle').single['name'], 'dsh-notes');
      expect(engine.argsOf('pluginManager/installBundle').map((a) => a['spec']), [
        'dsh-notes@1.4.2',
        'github:acme/dsh-writer#v2.0.0',
      ]);
      expect(engine.argsOf('pluginManager/setBundleEnabled').single['enabled'], isTrue);
      expect(engine.settings['subagent']!['user'], {'maxDepth': 3});
      // cot-translation never appeared on this host: skipped, not failed.
      expect(result.statuses['settings:cot-translation']?.state, ImportStepState.skipped);

      expect(fs.readSkill('outline'), {'SKILL.md': '新的提纲技能'});
      expect(
        fs.file('/root/.dsh/backups/share-import-20261024-153012/skills/outline/SKILL.md').readAsStringSync(),
        '旧的提纲技能',
      );
      expect(fs.file(GuestFs.importedAgentsMd).readAsStringSync(), '回答用中文。');

      final lkg = jsonDecode(RestorePoint(fs).lkgFile.readAsStringSync()) as Map<String, Object?>;
      expect(lkg['bundles'], ['@deepseek-ai/dsh-web-app', 'dsh-notes']);
      expect(lkg['deps'], ['dsh-notes']);
      expect(lkg['versions'], {'dsh-notes': '1.2.0'});
      expect(lkg['patch'], 'subagent:\n  maxDepth: 2\n');
      expect(lkg['at'], DateTime(2026, 10, 24, 15, 30, 12).millisecondsSinceEpoch);
    });

    test('a failed install is reported and its presets are skipped', () async {
      engine.failInstall['dsh-notes@1.4.2'] = 'network';
      final plan = await planImport(profile(), ImportTarget(_host(client), isActive: false), net: net, fs: fs);
      final result = await applyImport(
        plan,
        plan.defaultSelection,
        runner: DirectPluginRunner(client, isLocal: true),
        fs: fs,
      );
      expect(result.statuses['plugin:dsh-notes']!.state, ImportStepState.failed);
      expect(result.statuses['plugin:dsh-notes']!.message, isNotEmpty);
      expect(result.statuses['preset:writer']!.state, ImportStepState.skipped);
      expect(result.statuses['plugin:dsh-writer']!.state, ImportStepState.done);
    });

    test('a single plugin share is a one-row plan without a restore point', () async {
      final plan = await planImport(
        PluginShare(profile().plugins.first),
        ImportTarget(_host(client), isActive: false),
        net: net,
        fs: fs,
      );
      expect(plan.changes.single.kind, ChangeKind.upgrade);
      final result = await applyImport(
        plan,
        plan.defaultSelection,
        runner: DirectPluginRunner(client, isLocal: true),
        fs: fs,
      );
      expect(result.restorePoint, isFalse);
      expect(RestorePoint(fs).lkgFile.existsSync(), isFalse);
    });
  });

  test('gist links fetch the code and check it', () async {
    final net = FakeShareNet();
    const share = PluginShare(SharedPlugin(name: 'x', source: PluginSourceKind.npm, spec: 'x@1.0.0', version: '1.0.0'));
    final code = encodeShareCode(share);
    final id = await net.createGist(
      token: 'good',
      fileName: 'x.dshgo',
      content: encodeShareFile(share, code: code),
    );
    final sum = code.split('.').last;
    expect(await resolveShareLink(ShareLink.gist(id, sum), net), isA<PluginShare>());
    expect(() => resolveShareLink(ShareLink.gist(id, 'AAAAAAAA'), net), throwsA(isA<ShareDecodeException>()));
    await expectLater(() => net.createGist(token: 'bad', fileName: 'x', content: ''), throwsA(isA<GistException>()));
  });

  test('restore point needs a profile', () async {
    final fs = tempGuest();
    addTearDown(() => fs.root.parent.deleteSync(recursive: true));
    expect(await RestorePoint(fs).pinCurrentProfile(), isFalse);
    expect(File(RestorePoint(fs).lkgFile.path).existsSync(), isFalse);
  });
}
