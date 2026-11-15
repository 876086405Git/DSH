// 投稿 page: every step it can show, driven by the real workshop controllers
// over the state layer's own fakes (no network, no files).

import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/state/workshop_account_state.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart' show formatBytes;
import 'package:dsh_app/state/workshop_auth_state.dart';
import 'package:dsh_app/state/workshop_dependencies.dart';
import 'package:dsh_app/state/workshop_preferences.dart';
import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:dsh_app/state/workshop_publish_state.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_page.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_preview.dart';
import 'package:dsh_app/ui/workshop/workshop_publish_text.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../shell/golden_harness.dart' show goldenApp;
import '../../state/workshop_auth_test_support.dart';
import '../../state/workshop_publish_test_support.dart';
import '../../workshop/support.dart' show workshopCaps, workshopPng;

const _companion = WorkshopPublishSource(kind: 'companion', localId: 'companion');

/// The page's world: a signed-in GitHub account that has already agreed to
/// the disclosure, a workshop that takes uploads, one pet to send.
class _World {
  _World({WorkshopAccountState? account, this.recovery}) : account = account ?? authSignedIn();

  final events = <String>[];
  final WorkshopAccountState account;

  /// With a range, the phone's record can be let go, and that is how much
  /// goes. Without one the preferences cannot do it at all.
  final WorkshopPendingAbandonRange? recovery;
  late final PublishPreferences preferences = recovery == null
      ? PublishPreferences(events)
      : _RecoveryPreferences(events, recovery!);
  _RecoveryPreferences get journal => preferences as _RecoveryPreferences;

  /// What the system file picker hands back for a cover.
  Future<Uint8List?> Function()? pickCover;
  late final client = PublishClient(events);
  late final drafts = PublishDrafts(events);
  List<WorkshopPublishSource> sources = [publishSource];
  Map<String, WorkshopException> issues = {};
  WorkshopPublishController Function()? publisher;
  int ids = 0;

  /// [previews]: the pictures this workshop takes with a submission; null
  /// for a workshop from before there were any.
  void capabilities({bool uploads = true, bool companion = true, List<String>? previews}) =>
      client.value = WorkshopCapabilities.fromJson({
        ...workshopCaps(uploads: uploads, companion: companion, account: authAccount.toString()),
        if (previews != null)
          'preview': {
            'schema': 1,
            'format': 'png',
            'maxWidth': workshopPreviewSide,
            'maxHeight': workshopPreviewSide,
            'maxPixels': workshopPreviewPixels,
            'maxBytes': workshopPreviewBytes,
            'sources': previews,
          },
      });

  List<Override> get overrides => [
    workshopAccountProvider.overrideWith(() => AuthAccountController(account)),
    workshopClientProvider.overrideWith((ref) async => client),
    workshopPreferencesProvider.overrideWithValue(preferences),
    workshopPrepareDraftProvider.overrideWithValue(drafts.prepare),
    workshopRestoreDraftProvider.overrideWithValue(drafts.restore),
    workshopRequestIdProvider.overrideWithValue(() => (++ids).toRadixString(16).padLeft(32, '0')),
    workshopSourcesLoaderProvider.overrideWithValue(
      () async => WorkshopPublishSources(values: sources, issues: issues),
    ),
    workshopCoverPickerProvider.overrideWithValue(() async => pickCover == null ? null : await pickCover!()),
    if (publisher case final publisher?) workshopPublishProvider.overrideWith(publisher),
  ];
}

class _RecoverySnapshot implements WorkshopPendingRecoverySnapshot {
  const _RecoverySnapshot(this.scope, this.range);

  final String scope;
  @override
  final WorkshopPendingAbandonRange range;
}

/// The publish fake with the recovery seam scripted over it: which range it
/// offers, and what letting go removes.
class _RecoveryPreferences extends PublishPreferences implements WorkshopPendingRecoveryStore {
  _RecoveryPreferences(super.events, this.range);

  final WorkshopPendingAbandonRange range;
  final abandoned = <WorkshopPendingRecoverySnapshot>[];
  Future<void> Function()? abandoning;

  @override
  Future<WorkshopPendingRecoverySnapshot> pendingRecovery(String scope) async => _RecoverySnapshot(scope, range);

  @override
  Future<void> abandonPendingRecovery(WorkshopPendingRecoverySnapshot snapshot) async {
    if (abandoning != null) await abandoning!();
    abandoned.add(snapshot);
    if (range == WorkshopPendingAbandonRange.allLocalAccounts) {
      pending.clear();
    } else {
      pending.remove((snapshot as _RecoverySnapshot).scope);
    }
    reading = null;
    clearing = null;
  }
}

class _Opener extends StatelessWidget {
  const _Opener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkshopPublishPage())),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets a brief notice run out, so no timer outlives the test.
Future<void> _clearNotice(WidgetTester tester) => tester.pump(const Duration(seconds: 4));

Future<void> _open(WidgetTester tester, _World world, {Size size = const Size(390, 1800), double textScale = 1}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(goldenApp(home: const _Opener(), brightness: Brightness.light, overrides: world.overrides));
  await tester.tap(find.text('open'));
  await _settle(tester);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WorkshopPublishPage)));

/// Nothing on screen may be a stable code or an exception's own text.
void _expectWords(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final shown = text.data ?? text.textSpan?.toPlainText() ?? '';
    expect(shown, isNot(contains('workshop_')), reason: 'a code reached the screen: $shown');
    expect(shown, isNot(contains('Exception')), reason: 'an exception reached the screen: $shown');
  }
}

Finder _field(String name) => find.byKey(ValueKey('workshop-publish-$name'));

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// Picks the pet and fills in what its own defaults leave empty.
Future<void> _fillForm(WidgetTester tester) async {
  await _tapVisible(tester, find.text('Cat'));
  await tester.enterText(_field('title-zh'), '小猫');
  await tester.enterText(_field('id'), 'cat');
  await tester.enterText(_field('author'), 'Author');
  await tester.enterText(_field('source'), 'https://source.example/cat');
  await tester.pump();
  await _tapVisible(tester, find.text('CC0-1.0'));
}

/// From the sources list to the packed result with the rights box ticked.
Future<void> _toReview(WidgetTester tester) async {
  await _fillForm(tester);
  await tester.tap(find.text('下一步'));
  await _settle(tester);
  await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
}

/// Picks the companion and fills in everything: it has no defaults.
Future<void> _fillCompanion(WidgetTester tester) async {
  await _tapVisible(tester, find.text('现在的伙伴'));
  await tester.enterText(_field('title-zh'), '小伙伴');
  await tester.enterText(_field('title-en'), 'Buddy');
  await tester.enterText(_field('id'), 'buddy');
  await tester.enterText(_field('author'), 'Author');
  await tester.enterText(_field('source'), 'https://source.example/buddy');
  await tester.pump();
  await _tapVisible(tester, find.text('CC0-1.0'));
}

/// A submission sent with no answer: the unfinished step, result unknown.
Future<void> _toUnknown(WidgetTester tester, _World world) async {
  world.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
  await _toReview(tester);
  await tester.tap(find.widgetWithText(FilledButton, '投稿'));
  await _settle(tester);
}

const _bothPreviews = ['pet-idle', 'companion-preview'];
final _previewSwitch = find.byKey(const ValueKey('workshop-publish-preview-switch'));
final _letGo = find.widgetWithText(TextButton, '放下这条记录');
final _letGoDialog = find.byType(AlertDialog);

WorkshopPublishState _publish(WidgetTester tester) => _container(tester).read(workshopPublishProvider);

/// After a record was let go, nothing may say the submission was cancelled
/// or failed: only the phone's record went.
void _expectNoCancelClaim(WidgetTester tester) {
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final shown = text.data ?? text.textSpan?.toPlainText() ?? '';
    for (final claim in ['取消', '失败', '撤回', '作废']) {
      expect(shown, isNot(contains(claim)), reason: 'reads as a cancelled submission: $shown');
    }
  }
}

void main() {
  group('gates', () {
    testWidgets('uploads off: says so, and asks for nothing', (tester) async {
      final world = _World(account: authSignedOut)..capabilities(uploads: false);
      await _open(tester, world);

      expect(find.text('工坊暂时不接收投稿'), findsOneWidget);
      expect(find.text('用 GitHub 登录'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      _expectWords(tester);
    });

    testWidgets('signed out: one line why, and the GitHub sign-in sheet', (tester) async {
      final world = _World(account: authSignedOut);
      await _open(tester, world);

      expect(find.text('先登录 GitHub 账号'), findsOneWidget);
      expect(find.text('工坊靠 GitHub 账号确认投稿的人是谁。'), findsOneWidget);
      expect(world.preferences.reads, 0);

      await tester.tap(find.text('用 GitHub 登录'));
      await _settle(tester);
      // The device-flow sheet shows the code to type on GitHub.
      expect(find.text('TEST-CODE'), findsOneWidget);
    });

    testWidgets('the workshop cannot be reached: the reason in words and a retry', (tester) async {
      final world = _World();
      world.client.readCapabilities = () async => throw const WorkshopException('workshop_network');
      await _open(tester, world);

      expect(find.text('暂时打不开工坊'), findsOneWidget);
      expect(find.text('网络不通，稍后再试。'), findsOneWidget);
      _expectWords(tester);

      world.client.readCapabilities = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('no account profile yet: nothing is read or started', (tester) async {
      final world = _World(account: authSignedIn(userId: null));
      await _open(tester, world);

      expect(find.text('还没读到 GitHub 账号资料'), findsOneWidget);
      expect(world.preferences.reads, 0);
      expect(find.text('选一个要投稿的'), findsNothing);
    });
  });

  group('credential disclosure', () {
    testWidgets('shows both addresses before anything is read or sent', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      expect(find.text('让工坊核对你的 GitHub 身份'), findsOneWidget);
      expect(find.textContaining('GitHub 登录凭据'), findsOneWidget);
      expect(find.text(authWorker.host), findsOneWidget);
      expect(find.text(authAccount.host), findsOneWidget);
      expect(find.text('同意并继续'), findsOneWidget);
      expect(find.text('暂不'), findsOneWidget);
      expect(world.preferences.reads, 0);
      expect(world.preferences.writes, 0);
      expect(world.events, isEmpty);
      _expectWords(tester);
    });

    testWidgets('agreeing saves the pair and only then looks for an unfinished submission', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      await tester.tap(find.text('同意并继续'));
      await _settle(tester);

      expect(world.preferences.writes, 1);
      expect(world.preferences.accepted, {world.preferences.pair(authWorker, authAccount)});
      expect(world.events, ['read-pending']);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('「暂不」 leaves the page and agrees to nothing', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      await tester.tap(find.text('暂不'));
      await _settle(tester);

      expect(find.byType(WorkshopPublishPage), findsNothing);
      expect(world.preferences.writes, 0);
    });

    testWidgets('a stale confirmation is not taken: the offer is shown again', (tester) async {
      final world = _World()..preferences.accepted.clear();
      await _open(tester, world);

      // The sources are being read again while the old offer is still up.
      final gate = Completer<WorkshopCapabilities>();
      world.client.readCapabilities = () => gate.future;
      final refresh = _container(tester).read(workshopAccessProvider.notifier).refresh();
      await tester.pump();
      await tester.tap(find.text('同意并继续'));
      await tester.pump();

      expect(world.preferences.writes, 0);
      expect(find.text('地址刚刚有变化，请按现在显示的重新确认。'), findsOneWidget);
      expect(find.text('同意并继续'), findsOneWidget);
      _expectWords(tester);

      gate.complete(world.client.value);
      await refresh;
      await _settle(tester);
      expect(find.text('地址刚刚有变化，请按现在显示的重新确认。'), findsNothing);
      await tester.tap(find.text('同意并继续'));
      await _settle(tester);
      expect(world.preferences.writes, 1);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('a consent that could not be saved is said to be for now only', (tester) async {
      final world = _World()..preferences.accepted.clear();
      world.preferences.writeDisclosure = (_, _) async => throw StateError('disk');
      await _open(tester, world);

      await tester.tap(find.text('同意并继续'));
      await _settle(tester);

      expect(find.text('这次同意已经生效，但没能记在本机，下次可能再问一遍。'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      _expectWords(tester);
    });
  });

  group('unfinished submission check', () {
    testWidgets('a record that cannot be read blocks a new submission', (tester) async {
      final world = _World();
      world.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
      await _open(tester, world);

      expect(find.text('没能读出上一次投稿的记录'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsNothing);
      expect(world.preferences.reads, 1, reason: 'asked once, not on every build');
      _expectWords(tester);

      world.preferences.reading = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(world.preferences.reads, 2);
      expect(find.text('选一个要投稿的'), findsOneWidget);
    });

    testWidgets('one left from before is shown instead of the form, and continues as the same request', (tester) async {
      final world = _World();
      world.client.creating = (_) async => throw const WorkshopException('workshop_network');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      final first = world.client.creates.single.requestId;

      // The app is opened again: same phone record, new controllers.
      await tester.pumpWidget(const SizedBox.shrink());
      world.client.creating = null;
      await _open(tester, world);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.text('小猫'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsNothing);
      expect(find.text('下一步'), findsNothing);
      expect(world.client.creates, hasLength(1), reason: 'restoring sends nothing');

      await tester.tap(find.widgetWithText(FilledButton, '继续投稿'));
      await _settle(tester);
      expect(world.client.creates, hasLength(2));
      expect(world.client.creates.last.requestId, first);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });
  });

  group('source and form', () {
    testWidgets('lists what can be sent, and why something cannot', (tester) async {
      final world = _World()
        ..capabilities(companion: false)
        ..sources = [publishSource, _companion];
      await _open(tester, world);

      expect(find.text('Cat'), findsOneWidget);
      expect(find.text('像素宠物'), findsOneWidget);
      expect(find.text('现在的伙伴'), findsOneWidget);
      expect(find.text('伙伴类作品暂时关闭了。'), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.text('现在的伙伴'));
      await _settle(tester);
      expect(find.text('下一步'), findsNothing, reason: 'a source the workshop will not take is not picked');
    });

    testWidgets('no companion on the phone is a quiet line, not an error', (tester) async {
      final world = _World()..issues = {'companion': const WorkshopException('workshop_companion_unavailable')};
      await _open(tester, world);

      expect(find.text('本机还没有伙伴，先到伙伴小屋请一位。'), findsOneWidget);
      _expectWords(tester);
    });

    testWidgets('a refused pick is said and nothing changes', (tester) async {
      final world = _World()..publisher = _RefusingPublisher.new;
      await _open(tester, world);

      await tester.tap(find.text('Cat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      expect(find.text('下一步'), findsNothing);
      await _clearNotice(tester);
    });

    testWidgets('field problems are words under the field, and nothing is packed', (tester) async {
      final world = _World();
      await _open(tester, world);
      await tester.tap(find.text('Cat'));
      await _settle(tester);

      // The pet's own name is filled in; the rest is the person's to give.
      expect(tester.widget<TextField>(_field('title-en')).controller!.text, 'Cat');
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');
      await tester.enterText(_field('title-zh'), '');
      await tester.enterText(_field('id'), 'My Cat');
      await tester.enterText(_field('version'), 'one');
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      // Left empty is filled in (the other name, the account, 作者授权); only
      // what was typed wrong is said.
      expect(find.text('名称不能为空，最多 120 个字'), findsNothing);
      expect(find.text('只能用小写字母、数字和短横线，最多 40 个字符'), findsOneWidget);
      expect(find.text('写成 1.0.0 这样的版本号'), findsOneWidget);
      expect(find.text('作者不能为空，最多 256 个字'), findsNothing);
      expect(find.text('选一个许可'), findsNothing);
      expect(find.text('填一个以 https:// 开头的链接'), findsNothing);
      expect(world.events, ['read-pending']);
      expect(tester.widget<TextField>(_field('version')).controller!.text, 'one', reason: 'what was typed stays');
      _expectWords(tester);

      // Mending a field takes its line away.
      await tester.enterText(_field('version'), '1.2.0');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('写成 1.0.0 这样的版本号'), findsNothing);
    });

    testWidgets('a line break typed or pasted into the description becomes a space', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.enterText(_field('description'), '一只猫\n会打哈欠');
      await tester.pump();
      expect(tester.widget<TextField>(_field('description')).controller!.text, '一只猫 会打哈欠');

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.events, contains('prepare'));
      _expectWords(tester);
    });

    testWidgets('leaving with unsent edits asks first', (tester) async {
      final world = _World();
      await _open(tester, world);
      await tester.tap(find.text('Cat'));
      await _settle(tester);
      await tester.enterText(_field('author'), 'Someone');
      await tester.pump();

      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsOneWidget);

      await tester.tap(find.byTooltip('返回'));
      await _settle(tester);
      await tester.tap(find.text('放弃'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsNothing);
    });

    testWidgets('a packing failure stays on the form, in words', (tester) async {
      final world = _World();
      world.drafts.beforeReturn = (_) async => throw const WorkshopException('workshop_storage');
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(find.text('没能读写手机上的文件。'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      expect(world.client.creates, isEmpty);
      _expectWords(tester);
    });
  });

  group('submit', () {
    testWidgets('the packed result is shown, and 「投稿」 needs the rights tick', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(world.events, ['read-pending', 'prepare']);
      expect(find.text('小猫'), findsOneWidget);
      expect(find.text('包里的文件'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('我确认自己有权分享这份内容'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      expect(find.text('先确认你有权分享这份内容'), findsOneWidget);
      expect(world.client.creates, isEmpty);
      _expectWords(tester);

      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      expect(find.text('先确认你有权分享这份内容'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(world.client.creates.single.rights, isTrue);
      expect(world.client.uploads, hasLength(1));
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.text('回到我的投稿'));
      await _settle(tester);
      expect(find.byType(WorkshopPublishPage), findsNothing);

      // Coming back is for sending something else, not for reading it again.
      await tester.tap(find.text('open'));
      await _settle(tester);
      expect(find.text('已交给工坊，等待审核'), findsNothing);
      expect(find.text('选一个要投稿的'), findsOneWidget);
      expect(world.client.creates, hasLength(1));
    });

    testWidgets('「修改资料」 goes back to the form with what was accepted', (tester) async {
      final world = _World();
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      await _tapVisible(tester, find.text('修改资料'));
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小猫');
      expect(tester.widget<TextField>(_field('author')).controller!.text, 'Author');

      // Unchanged: the pack is still good, nothing is packed twice.
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.drafts.preparations, 1);
      expect(find.text('包里的文件'), findsOneWidget);

      // Changed: the old pack is not what would be sent.
      await _tapVisible(tester, find.text('修改资料'));
      await tester.enterText(_field('version'), '1.1.0');
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.drafts.preparations, 2);
      expect(find.text('1.1.0'), findsOneWidget);
    });

    testWidgets('a refused rights tick is said and the box stays as it was', (tester) async {
      final world = _World()..publisher = _RefusingTick.new;
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      await tester.ensureVisible(find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(_container(tester).read(workshopPublishProvider).input.rightsConfirmed, isFalse);
      await _clearNotice(tester);
    });

    testWidgets('progress follows the bytes; all bytes sent is still not done', (tester) async {
      final world = _World();
      final answer = Completer<WorkshopSubmission>();
      late PublishUploadCall upload;
      world.client.uploading = (call) {
        upload = call;
        return answer.future;
      };
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await tester.pump();
      await tester.pump();

      upload.progress!(1, 4);
      await tester.pump();
      expect(find.text('正在上传'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.25);
      expect(find.text('已交给工坊，等待审核'), findsNothing);

      upload.progress!(4, 4);
      await tester.pump();
      expect(find.text('已经传完，等工坊确认…'), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
      expect(find.text('已交给工坊，等待审核'), findsNothing);
      expect(find.byType(FilledButton), findsNothing, reason: 'nothing to press while it is being sent');

      answer.complete(publishResult(upload.draft.metadata, id: upload.draft.id, status: WorkshopSubmissionStatus.pending));
      await _settle(tester);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('an unknown result is called unknown and only the same request can be asked again', (tester) async {
      final world = _World();
      world.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '查看结果'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '投稿'), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget, reason: 'asking again is the only thing offered');
      expect(find.text('下一步'), findsNothing);
      expect(find.text('更换'), findsNothing);
      expect(find.text('重试'), findsNothing);
      _expectWords(tester);

      await tester.tap(find.widgetWithText(FilledButton, '查看结果'));
      await _settle(tester);
      expect(world.client.creates, hasLength(2));
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(world.ids, 1, reason: 'no second request id was ever made');
      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '重新查询'), findsOneWidget);

      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.pending);
      await tester.tap(find.widgetWithText(FilledButton, '重新查询'));
      await _settle(tester);
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(world.client.uploads, isEmpty, reason: 'it had arrived: nothing is uploaded twice');
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('refused before it was sent: the reason, a locked submission, and one way on', (tester) async {
      final world = _World()..sources = [publishSource, _companion];
      world.client.creating = (_) async => throw const WorkshopException('workshop_companion_disabled');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.text('伙伴类作品暂时关闭了。'), findsOneWidget);
      expect(find.textContaining('暂时不能修改'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '继续投稿'), findsOneWidget);
      expect(find.text('更换'), findsNothing);
      expect(find.text('修改资料'), findsNothing);
      expect(find.text('选一个要投稿的'), findsNothing);
      _expectWords(tester);

      world.client.creating = null;
      await tester.tap(find.widgetWithText(FilledButton, '继续投稿'));
      await _settle(tester);
      expect(world.client.creates.last.requestId, world.client.creates.first.requestId);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    testWidgets('known not to have been sent: 「回去修改」 returns to the form with what was typed', (tester) async {
      final world = _World();
      world.client.creating = (_) async =>
          throw const WorkshopException('workshop_upload_disabled', mutationNotSent: true);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      expect(find.textContaining('这次还没有发出去'), findsOneWidget);
      expect(find.textContaining('暂时不能修改'), findsNothing);
      expect(find.widgetWithText(FilledButton, '继续投稿'), findsOneWidget);
      _expectWords(tester);

      await _tapVisible(tester, find.text('回去修改'));
      final publish = _container(tester).read(workshopPublishProvider);
      expect(publish.hasPending, isFalse);
      expect(world.client.creates, hasLength(1));
      expect(world.client.uploads, isEmpty);
      // The form again, with the details as they were typed.
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');
      expect(find.text('有一份投稿还没结束'), findsNothing);
    });

    testWidgets('a rejected one can be sent again, with the tick taken back', (tester) async {
      final world = _World();
      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.rejected);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('这份投稿没有通过审核'), findsOneWidget);
      expect(find.text('回到我的投稿'), findsNothing);

      await tester.tap(find.text('重新投稿'));
      await _settle(tester);
      expect(world.events.last, 'retire');
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat', reason: 'the details are kept');
      expect(_container(tester).read(workshopPublishProvider).input.rightsConfirmed, isFalse);
    });

    testWidgets('letting go of the old request failed: 「重试」 tries that step again, and sends nothing', (tester) async {
      final world = _World();
      world.client.creating = (call) async =>
          publishResult(call.metadata, status: WorkshopSubmissionStatus.rejected);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      world.preferences.retiring = (_, _) async => throw const WorkshopException('workshop_preferences');
      await tester.tap(find.text('重新投稿'));
      await _settle(tester);
      // Still the result, with the record already cleared: what failed is
      // the step after it.
      expect(find.text('这份投稿没有通过审核'), findsOneWidget);
      expect(_container(tester).read(workshopPublishProvider).hasPending, isFalse);
      expect(_container(tester).read(workshopPublishProvider).preferenceError, isNotNull);
      _expectWords(tester);
      await _clearNotice(tester);

      final creates = world.client.creates.length;
      world.preferences.retiring = null;
      await _tapVisible(tester, find.text('重试'));
      expect(world.events.last, 'retire');
      expect(world.client.creates, hasLength(creates));
      expect(_container(tester).read(workshopPublishProvider).preferenceError, isNull);
      expect(find.text('下一步'), findsOneWidget);
    });

    testWidgets('a confirmed result stays a result when the phone record could not be cleared', (tester) async {
      final world = _World();
      world.preferences.clearing = (_, _) async => throw StateError('disk');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsOneWidget);
      _expectWords(tester);

      world.preferences.clearing = null;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      expect(world.client.creates, hasLength(1), reason: 'clearing the record sends nothing');
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsNothing);
    });
  });

  group('preview picture', () {
    testWidgets('a pet goes with its idle frame by default, and says so before sending', (tester) async {
      final world = _World()..capabilities(previews: _bothPreviews);
      await _open(tester, world);
      await _fillForm(tester);

      expect(find.text('预览图'), findsOneWidget);
      expect(find.text('在工坊里显示预览图'), findsOneWidget);
      expect(find.text('用待机动画的第一帧'), findsOneWidget);
      expect(tester.widget<Switch>(_previewSwitch).value, isTrue);
      expect(_publish(tester).source?.previewSource, 'pet-idle');
      expect(find.text('封面（选填）'), findsNothing);

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(find.text('待机动画第一帧'), findsOneWidget);
      expect(find.text('不带预览图'), findsNothing);
      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(world.client.creates.single.metadata.previewSource, 'pet-idle');
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      _expectWords(tester);
    });

    testWidgets('turning the switch off sends no preview and keeps what was typed', (tester) async {
      final world = _World()..capabilities(previews: _bothPreviews);
      await _open(tester, world);
      await _fillForm(tester);

      await _tapVisible(tester, _previewSwitch);
      expect(tester.widget<Switch>(_previewSwitch).value, isFalse);
      expect(_publish(tester).source?.preview, isNull);
      // Nothing of this was handed to the state layer yet: it is the form's.
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小猫');
      expect(tester.widget<TextField>(_field('author')).controller!.text, 'Author');
      expect(tester.widget<TextField>(_field('source')).controller!.text, 'https://source.example/cat');

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(find.text('不带预览图'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(world.client.creates.single.metadata.previewSource, isNull);
      expect(world.client.creates.single.metadata.toJson().containsKey('previewSource'), isFalse);
    });

    testWidgets('a change after packing drops the pack and takes the rights tick back', (tester) async {
      final world = _World()..capabilities(previews: _bothPreviews);
      await _open(tester, world);
      await _toReview(tester);
      expect(_publish(tester).input.rightsConfirmed, isTrue);

      await _tapVisible(tester, find.text('修改资料'));
      await _tapVisible(tester, _previewSwitch);
      expect(_publish(tester).preparedMetadata, isNull);
      expect(_publish(tester).input.rightsConfirmed, isFalse);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(world.drafts.preparations, 2);
      expect(find.text('不带预览图'), findsOneWidget);
    });

    testWidgets('a workshop that takes no pictures shows no group and sets nothing', (tester) async {
      final world = _World()..sources = [publishSource, _companion];
      await _open(tester, world);
      await _fillForm(tester);

      expect(find.text('预览图'), findsNothing);
      expect(_previewSwitch, findsNothing);
      expect(_publish(tester).source?.preview, isNull);
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(find.text('不带预览图'), findsOneWidget);
      expect(_publish(tester).preparedMetadata?.previewSource, isNull);
    });

    testWidgets('each kind gets its group only when the workshop takes that picture', (tester) async {
      final world = _World()
        ..capabilities(previews: ['pet-idle'])
        ..sources = [publishSource, _companion];
      await _open(tester, world);
      await _tapVisible(tester, find.text('现在的伙伴'));

      expect(find.text('封面（选填）'), findsNothing);
      expect(find.text('选一张封面'), findsNothing);
      expect(find.text('预览图'), findsNothing);
      expect(_publish(tester).source?.preview, isNull);
    });

    testWidgets('a companion cover: the thumbnail, its size, and the packed result carries it', (tester) async {
      final png = workshopPng(32, 16);
      final world = _World()
        ..capabilities(previews: _bothPreviews)
        ..sources = [_companion]
        ..pickCover = () async => png;
      await _open(tester, world);
      await _fillCompanion(tester);

      expect(find.text('封面（选填）'), findsOneWidget);
      expect(find.text('PNG，每边不超过 512 像素，不超过 2 MB。不选就显示名字的第一个字。'), findsOneWidget);
      expect(find.text('预览图'), findsNothing);
      expect(_publish(tester).source?.preview, isNull, reason: 'a companion starts without a cover');

      await _tapVisible(tester, find.text('选一张封面'));
      expect(find.text('32×16 · ${formatBytes(png.length)}'), findsOneWidget);
      expect(tester.getSize(find.byType(WorkshopCoverThumb)), const Size(64, 64));
      expect(find.text('换一张'), findsOneWidget);
      expect(find.text('移除'), findsOneWidget);
      expect(find.text('选一张封面'), findsNothing);
      expect(find.textContaining('不选就显示'), findsNothing);
      expect(_publish(tester).source?.previewSource, 'companion-preview');
      // The form's own text is not touched by the picture.
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'buddy');
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小伙伴');

      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(_publish(tester).preparedMetadata?.previewSource, 'companion-preview');
      expect(find.text('预览图'), findsOneWidget);
      expect(tester.getSize(find.byType(WorkshopCoverThumb)), const Size(40, 40));
      expect(find.text('不带预览图'), findsNothing);
      _expectWords(tester);
    });

    for (final (name, pick, words) in <(String, Future<Uint8List?> Function(), String)>[
      ('an empty file', () async => Uint8List(0), '这张图是空的或超过 2 MB，换一张试试。'),
      (
        'a file over the limit, refused before it is read',
        () async => throw const WorkshopException('workshop_preview_size'),
        '这张图是空的或超过 2 MB，换一张试试。',
      ),
      ('not a PNG', () async => Uint8List.fromList([1, 2, 3, 4]), '这不是一张完整的 PNG 图片，换一张试试。'),
      ('a PNG wider than 512', () async => workshopPng(600, 8), '这张图太大了，每边最多 512 像素。缩小后再选。'),
      ('a file that cannot be read', () async => throw StateError('gone'), '没能读出这张图，换一张试试。'),
    ]) {
      testWidgets('a cover that is $name is refused in words, and nothing is set', (tester) async {
        final world = _World()
          ..capabilities(previews: _bothPreviews)
          ..sources = [_companion]
          ..pickCover = pick;
        await _open(tester, world);
        await _tapVisible(tester, find.text('现在的伙伴'));
        await _tapVisible(tester, find.text('选一张封面'));

        expect(find.text(words), findsOneWidget);
        expect(find.textContaining('不选就显示'), findsNothing, reason: 'the reason takes the helper line');
        expect(find.text('选一张封面'), findsOneWidget);
        expect(find.byType(WorkshopCoverThumb), findsNothing);
        expect(_publish(tester).source?.preview, isNull);
        _expectWords(tester);
      });
    }

    testWidgets('closing the picker changes nothing', (tester) async {
      final world = _World()
        ..capabilities(previews: _bothPreviews)
        ..sources = [_companion];
      await _open(tester, world);
      await _tapVisible(tester, find.text('现在的伙伴'));
      await _tapVisible(tester, find.text('选一张封面'));

      expect(find.text('选一张封面'), findsOneWidget);
      expect(find.textContaining('不选就显示'), findsOneWidget);
      expect(_publish(tester).source?.preview, isNull);
    });

    testWidgets('「换一张」 keeps the old cover when the new one is refused; 「移除」 clears it', (tester) async {
      final png = workshopPng(32, 16);
      final world = _World()
        ..capabilities(previews: _bothPreviews)
        ..sources = [_companion]
        ..pickCover = () async => png;
      await _open(tester, world);
      await _tapVisible(tester, find.text('现在的伙伴'));
      await _tapVisible(tester, find.text('选一张封面'));
      final first = _publish(tester).source!.preview;

      world.pickCover = () async => Uint8List.fromList([9, 9, 9]);
      await _tapVisible(tester, find.text('换一张'));
      expect(find.text('这不是一张完整的 PNG 图片，换一张试试。'), findsOneWidget);
      expect(_publish(tester).source?.preview, same(first));
      expect(find.byType(WorkshopCoverThumb), findsOneWidget);

      final other = workshopPng(8, 8);
      world.pickCover = () async => other;
      await _tapVisible(tester, find.text('换一张'));
      expect(find.text('8×8 · ${formatBytes(other.length)}'), findsOneWidget);
      expect(find.text('这不是一张完整的 PNG 图片，换一张试试。'), findsNothing);
      expect(_publish(tester).source?.preview, isNot(same(first)));

      await _tapVisible(tester, find.text('移除'));
      expect(_publish(tester).source?.preview, isNull);
      expect(find.byType(WorkshopCoverThumb), findsNothing);
      expect(find.text('选一张封面'), findsOneWidget);
      expect(find.textContaining('不选就显示'), findsOneWidget);
    });

    testWidgets('another source starts with no cover', (tester) async {
      final world = _World()
        ..capabilities(previews: _bothPreviews)
        ..sources = [publishSource, _companion]
        ..pickCover = () async => workshopPng(32, 16);
      await _open(tester, world);
      await _tapVisible(tester, find.text('现在的伙伴'));
      await _tapVisible(tester, find.text('选一张封面'));
      expect(find.byType(WorkshopCoverThumb), findsOneWidget);

      // To the pet and back: nothing typed, so nothing to confirm.
      await _tapVisible(tester, find.text('更换'));
      await _tapVisible(tester, find.text('Cat'));
      expect(_publish(tester).source?.previewSource, 'pet-idle');
      await _tapVisible(tester, find.text('更换'));
      await _tapVisible(tester, find.text('现在的伙伴').last);

      expect(_publish(tester).source?.kind, 'companion');
      expect(_publish(tester).source?.preview, isNull);
      expect(find.byType(WorkshopCoverThumb), findsNothing);
      expect(find.text('选一张封面'), findsOneWidget);
    });

    testWidgets('a refused preview change is a notice, and nothing else moves', (tester) async {
      final world = _World()
        ..capabilities(previews: _bothPreviews)
        ..publisher = _RefusingPreview.new;
      await _open(tester, world);
      await tester.tap(find.text('Cat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The default was refused: said once, and the form is there without it.
      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      expect(_publish(tester).source?.preview, isNull);
      await _clearNotice(tester);
      await _settle(tester);
      expect(find.text('上一步还没结束，稍等。'), findsNothing);
      // Still offered, because the workshop takes it.
      expect(tester.widget<Switch>(_previewSwitch).value, isFalse);

      await tester.enterText(_field('author'), 'Someone');
      await tester.ensureVisible(_previewSwitch);
      await tester.tap(_previewSwitch);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('上一步还没结束，稍等。'), findsOneWidget);
      expect(tester.widget<Switch>(_previewSwitch).value, isFalse);
      expect(tester.widget<TextField>(_field('author')).controller!.text, 'Someone');
      _expectWords(tester);
      await _clearNotice(tester);
    });

    testWidgets('a pet too large for a preview: the reason and the way on, in words', (tester) async {
      final world = _World()..capabilities(previews: _bothPreviews);
      world.drafts.beforeReturn = (_) async {
        if (world.drafts.preparations == 1) throw const WorkshopException('workshop_preview_dimensions');
      };
      await _open(tester, world);
      await _fillForm(tester);
      await tester.tap(find.text('下一步'));
      await _settle(tester);

      expect(find.text('这只宠物的画面超过 512 像素，做不了预览图。关掉预览图可以照常投稿。'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      _expectWords(tester);

      await _tapVisible(tester, _previewSwitch);
      expect(find.textContaining('做不了预览图'), findsNothing);
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(find.text('不带预览图'), findsOneWidget);
    });

    testWidgets('a workshop that stopped taking previews: said in words, and the preview stays removable', (
      tester,
    ) async {
      final world = _World()..capabilities(previews: _bothPreviews);
      world.client.creating = (_) async =>
          throw const WorkshopException('workshop_preview_unsupported', mutationNotSent: true);
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('这个工坊现在不收预览图。去掉预览图可以照常投稿。'), findsOneWidget);
      _expectWords(tester);

      // The workshop's answer, read again, no longer lists any picture.
      world.capabilities();
      await _container(tester).read(workshopAccessProvider.notifier).refresh();
      await _settle(tester);
      await _tapVisible(tester, find.text('回去修改'));
      expect(tester.widget<Switch>(_previewSwitch).value, isTrue, reason: 'what is set can still be taken off');

      await _tapVisible(tester, _previewSwitch);
      expect(_previewSwitch, findsNothing, reason: 'and is not offered again');
      world.client.creating = null;
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      expect(world.client.creates.last.metadata.previewSource, isNull);
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
    });

    test('every preview failure has its own sentence', () {
      final l10n = lookupL10n(AppLocale.zhCN);
      final sentences = {
        for (final code in [
          'workshop_preview_dimensions',
          'workshop_preview_conflict',
          'workshop_preview_missing',
          'workshop_preview_unsupported',
          'workshop_preview_size',
          'workshop_preview_png',
        ])
          code: workshopPublishErrorText(l10n, WorkshopException(code)),
      };
      expect(sentences.values.toSet(), hasLength(sentences.length));
      for (final sentence in sentences.values) {
        expect(sentence, isNot(l10n.workshopErrorGeneric));
        expect(sentence, isNot(contains('workshop_')));
      }
      expect(sentences['workshop_preview_conflict'], contains('移除封面'));
      expect(sentences['workshop_preview_dimensions'], contains('关掉预览图'));
    });

    for (final kind in ['pet', 'companion']) {
      testWidgets('the $kind group fits 360dp at 1.3×', (tester) async {
        var pick = 0;
        final world = _World()
          ..capabilities(previews: _bothPreviews)
          ..sources = [publishSource, _companion]
          ..pickCover = () async => pick++ == 0 ? workshopPng(512, 512) : workshopPng(513, 1);
        await _open(tester, world, size: const Size(360, 740), textScale: 1.3);
        if (kind == 'pet') {
          await _tapVisible(tester, find.text('Cat'));
          expect(_previewSwitch, findsOneWidget);
          await _tapVisible(tester, _previewSwitch);
        } else {
          await _tapVisible(tester, find.text('现在的伙伴'));
          expect(find.text('选一张封面'), findsOneWidget);
          await _tapVisible(tester, find.text('选一张封面'));
          expect(find.byType(WorkshopCoverThumb), findsOneWidget);
          // The cover with a refusal under it is the tallest this group gets.
          await _tapVisible(tester, find.text('换一张'));
          expect(find.textContaining('每边最多 512 像素'), findsOneWidget);
          await _tapVisible(tester, find.text('移除'));
          await _tapVisible(tester, find.text('选一张封面'));
        }
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('letting go of the local record', () {
    testWidgets('not offered where the state layer does not allow it', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      await _open(tester, world);
      expect(_letGo, findsNothing, reason: 'sources');
      await _fillForm(tester);
      expect(_letGo, findsNothing, reason: 'form');
      await tester.tap(find.text('下一步'));
      await _settle(tester);
      expect(_letGo, findsNothing, reason: 'packed result');
      await _tapVisible(tester, find.byKey(const ValueKey('workshop-publish-rights')));
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      // A result whose record was cleared has nothing left to let go.
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      expect(_publish(tester).canRequestPendingAbandonment, isFalse);
      expect(_letGo, findsNothing);
    });

    testWidgets('a check that failed for another reason offers only 「重试」', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      world.preferences.reading = (_) async => throw const WorkshopException('workshop_storage');
      await _open(tester, world);

      expect(find.text('没能读出上一次投稿的记录'), findsOneWidget);
      expect(_publish(tester).canRequestPendingAbandonment, isFalse);
      expect(find.text('重试'), findsOneWidget);
      expect(_letGo, findsNothing);
    });

    testWidgets('offered on the failed check, quietly under 「重试」', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.allLocalAccounts);
      world.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
      await _open(tester, world);

      expect(find.text('没能读出上一次投稿的记录'), findsOneWidget);
      expect(_publish(tester).canRequestPendingAbandonment, isTrue);
      expect(_letGo, findsOneWidget);
      expect(find.widgetWithText(FilledButton, '放下这条记录'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '重试'), findsOneWidget, reason: 'retrying stays the button');
      expect(tester.getTopLeft(_letGo).dy, greaterThan(tester.getBottomLeft(find.text('重试')).dy));
      expect(world.journal.abandoned, isEmpty);
      _expectWords(tester);
    });

    testWidgets('offered on an unfinished submission, beside the primary button', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      await _open(tester, world);
      await _toUnknown(tester, world);

      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(_letGo, findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '查看结果'), findsOneWidget);
    });

    testWidgets('offered on a result whose record could not be cleared', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      world.preferences.clearing = (_, _) async => throw StateError('disk');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);

      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsOneWidget);
      expect(_letGo, findsOneWidget);
      expect(find.widgetWithText(FilledButton, '放下这条记录'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('this account only: the dialog names both addresses, and 「取消」 changes nothing', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      await _open(tester, world);
      await _toUnknown(tester, world);
      final creates = world.client.creates.length;

      await _tapVisible(tester, _letGo);
      expect(_letGoDialog, findsOneWidget);
      Finder said(String part) => find.descendant(of: _letGoDialog, matching: find.textContaining(part));
      expect(find.text('放下本机的这条记录？'), findsOneWidget);
      expect(said('这个 GitHub 账号'), findsOneWidget);
      expect(said(authWorker.host), findsOneWidget);
      expect(said('只删除这台手机上'), findsOneWidget);
      expect(said('所有账号'), findsNothing);
      expect(said('工坊不会收到取消'), findsOneWidget);
      expect(said('我的投稿'), findsOneWidget);
      expect(said('会多出一份'), findsOneWidget);
      expect(find.descendant(of: _letGoDialog, matching: find.widgetWithText(TextButton, '取消')), findsOneWidget);
      expect(find.descendant(of: _letGoDialog, matching: find.widgetWithText(FilledButton, '放下记录')), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await _settle(tester);
      expect(_letGoDialog, findsNothing);
      expect(world.journal.abandoned, isEmpty);
      expect(world.preferences.pending, hasLength(1));
      expect(_publish(tester).hasPending, isTrue);
      expect(world.client.creates, hasLength(creates));
      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(find.text('已放下本机的记录'), findsNothing);
      // Asking again is a new offer, and a new question.
      await _tapVisible(tester, _letGo);
      expect(_letGoDialog, findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await _settle(tester);
    });

    testWidgets('every account: the dialog says the whole phone\'s records go', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.allLocalAccounts);
      world.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
      await _open(tester, world);

      await _tapVisible(tester, _letGo);
      Finder said(String part) => find.descendant(of: _letGoDialog, matching: find.textContaining(part));
      expect(said('整体读不出来'), findsOneWidget);
      expect(said('所有账号'), findsOneWidget);
      expect(said('只删除这台手机上'), findsNothing);
      expect(said('这个 GitHub 账号'), findsOneWidget);
      expect(said(authWorker.host), findsOneWidget);
      expect(said('工坊不会收到取消'), findsOneWidget);
      expect(said('会多出一份'), findsOneWidget);
      _expectWords(tester);

      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);
      expect(world.journal.abandoned.single.range, WorkshopPendingAbandonRange.allLocalAccounts);
      expect(find.text('已放下本机的记录'), findsOneWidget);
      // The check is done with: a new submission can start.
      expect(find.text('选一个要投稿的'), findsOneWidget);
      expect(find.text('没能读出上一次投稿的记录'), findsNothing);
      _expectNoCancelClaim(tester);
      await _clearNotice(tester);
    });

    testWidgets('result unknown: the same offer goes back, and the form returns with the tick taken back', (
      tester,
    ) async {
      late _RecordingPublisher publisher;
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount)
        ..publisher = () => publisher = _RecordingPublisher();
      await _open(tester, world);
      await _toUnknown(tester, world);
      final creates = world.client.creates.length;

      await _tapVisible(tester, _letGo);
      final offer = _publish(tester).abandonOffer;
      expect(offer, isNotNull);
      expect(publisher.confirmed, isEmpty, reason: 'nothing is removed before the person agrees');
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);

      expect(publisher.confirmed.single, same(offer));
      expect(world.journal.abandoned, hasLength(1));
      expect(world.preferences.pending, isEmpty);
      expect(world.client.creates, hasLength(creates), reason: 'nothing is sent to the workshop');
      expect(find.text('已放下本机的记录'), findsOneWidget);
      _expectNoCancelClaim(tester);
      _expectWords(tester);
      // Editable again, with what was typed and without the rights tick.
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.widget<TextField>(_field('id')).controller!.text, 'cat');
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小猫');
      expect(_publish(tester).hasPending, isFalse);
      expect(_publish(tester).input.rightsConfirmed, isFalse);
      expect(_letGo, findsNothing);
      await _clearNotice(tester);
    });

    testWidgets('result known: the result stays, and only the blocked record is repaired', (tester) async {
      late _RecordingPublisher publisher;
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount)
        ..publisher = () => publisher = _RecordingPublisher();
      world.preferences.clearing = (_, _) async => throw StateError('disk');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      final result = _publish(tester).result;
      final creates = world.client.creates.length;

      await _tapVisible(tester, _letGo);
      Finder said(String part) => find.descendant(of: _letGoDialog, matching: find.textContaining(part));
      expect(said('工坊不会收到取消'), findsOneWidget);
      expect(said('结果不变'), findsOneWidget);
      expect(said('重新投稿'), findsNothing, reason: 'the workshop has it: nothing needs sending again');
      final offer = _publish(tester).abandonOffer;
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);

      expect(publisher.confirmed.single, same(offer));
      expect(_publish(tester).result, same(result));
      expect(_publish(tester).hasPending, isFalse);
      expect(world.client.creates, hasLength(creates));
      expect(find.text('已交给工坊，等待审核'), findsOneWidget);
      expect(find.text('结果已经确认，但本机的投稿记录没能清掉。'), findsNothing);
      expect(find.text('已放下本机的记录'), findsOneWidget);
      expect(_letGo, findsNothing);
      _expectNoCancelClaim(tester);
      await _clearNotice(tester);
    });

    testWidgets('a record left from an earlier visit: let go, then its details go to the next form', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      world.client.creating = (_) async => throw const WorkshopException('workshop_network');
      await _open(tester, world);
      await _toReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, '投稿'));
      await _settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await _open(tester, world);
      expect(find.text('有一份投稿还没结束'), findsOneWidget);
      final creates = world.client.creates.length;

      await _tapVisible(tester, _letGo);
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);
      await _clearNotice(tester);

      expect(world.client.creates, hasLength(creates));
      expect(find.text('选一个要投稿的'), findsOneWidget);
      await _tapVisible(tester, find.text('Cat'));
      expect(tester.widget<TextField>(_field('title-zh')).controller!.text, '小猫');
      expect(tester.widget<TextField>(_field('source')).controller!.text, 'https://source.example/cat');
    });

    testWidgets('a confirmation that went stale is said in words, and can be asked again', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      await _open(tester, world);
      await _toUnknown(tester, world);
      world.journal.abandoning = () async => throw const WorkshopException('workshop_confirmation_stale');

      await _tapVisible(tester, _letGo);
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);

      expect(find.text('记录刚刚有变化，再点一次重新确认。'), findsOneWidget);
      expect(find.text('已放下本机的记录'), findsNothing);
      expect(find.text('不确定有没有交上去'), findsOneWidget);
      expect(_publish(tester).hasPending, isTrue);
      expect(world.journal.abandoned, isEmpty);
      _expectWords(tester);

      world.journal.abandoning = null;
      await _tapVisible(tester, _letGo);
      expect(_letGoDialog, findsOneWidget);
      expect(find.text('记录刚刚有变化，再点一次重新确认。'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);
      expect(world.journal.abandoned, hasLength(1));
      expect(find.text('已放下本机的记录'), findsOneWidget);
      await _clearNotice(tester);
    });

    testWidgets('a record that could not be removed, or cannot be here, is said in words', (tester) async {
      final world = _World(recovery: WorkshopPendingAbandonRange.currentAccount);
      await _open(tester, world);
      await _toUnknown(tester, world);
      world.journal.abandoning = () async => throw StateError('disk');
      await _tapVisible(tester, _letGo);
      await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
      await _settle(tester);

      expect(find.text('没能保存本机的记录，这一步没有继续。'), findsOneWidget);
      expect(find.text('已放下本机的记录'), findsNothing);
      expect(_publish(tester).hasPending, isTrue);
      _expectWords(tester);

      // Preferences without the recovery seam: asked for, and refused.
      await tester.pumpWidget(const SizedBox.shrink());
      final plain = _World();
      plain.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
      await _open(tester, plain);
      await _tapVisible(tester, _letGo);
      expect(_letGoDialog, findsNothing);
      expect(find.text('这个版本没法在这里放下记录。'), findsOneWidget);
      expect(find.text('没能读出上一次投稿的记录'), findsOneWidget);
      _expectWords(tester);
    });

    for (final (name, range, prepare)
        in <(String, WorkshopPendingAbandonRange, Future<void> Function(WidgetTester, _World))>[
      ('the failed check', WorkshopPendingAbandonRange.allLocalAccounts, (tester, world) async {}),
      ('an unknown result', WorkshopPendingAbandonRange.currentAccount, (tester, world) => _toUnknown(tester, world)),
      ('a result with its record kept', WorkshopPendingAbandonRange.currentAccount, (tester, world) async {
        world.preferences.clearing = (_, _) async => throw StateError('disk');
        await _toReview(tester);
        await tester.tap(find.widgetWithText(FilledButton, '投稿'));
        await _settle(tester);
      }),
    ]) {
      testWidgets('$name with its dialog and its refusal fits 360dp at 1.3×', (tester) async {
        final world = _World(recovery: range);
        if (name == 'the failed check') {
          world.preferences.reading = (_) async => throw const WorkshopException('workshop_preferences');
        }
        await _open(tester, world, size: const Size(360, 740), textScale: 1.3);
        await prepare(tester, world);
        world.journal.abandoning = () async => throw const WorkshopException('workshop_confirmation_stale');

        await _tapVisible(tester, _letGo);
        expect(_letGoDialog, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(FilledButton, '放下记录'));
        await _settle(tester);
        expect(find.text('记录刚刚有变化，再点一次重新确认。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('narrow screen, large type', () {
    for (final (name, prepare) in <(String, Future<void> Function(WidgetTester, _World))>[
      ('disclosure', (tester, world) async {}),
      ('form with every error', (tester, world) async {
        await _tapVisible(tester, find.text('Cat'));
        await tester.enterText(_field('title-zh'), '');
        await tester.tap(find.text('下一步'));
        await _settle(tester);
      }),
      ('packed result', (tester, world) async {
        await _fillForm(tester);
        await tester.tap(find.text('下一步'));
        await _settle(tester);
      }),
      ('unknown result', (tester, world) async {
        world.client.creating = (_) async => throw const WorkshopException('workshop_timeout', resultUnknown: true);
        await _toReview(tester);
        await tester.tap(find.widgetWithText(FilledButton, '投稿'));
        await _settle(tester);
      }),
    ]) {
      testWidgets('$name fits 360dp at 1.3×', (tester) async {
        final world = _World();
        if (name == 'disclosure') world.preferences.accepted.clear();
        await _open(tester, world, size: const Size(360, 740), textScale: 1.3);
        await prepare(tester, world);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

/// A publisher that is busy with something else: picks are not accepted.
class _RefusingPublisher extends WorkshopPublishController {
  @override
  bool selectSource(WorkshopPublishSource source) {
    state = state.copyWith(error: const WorkshopException('workshop_busy'));
    return false;
  }
}

/// A publisher that takes the source but not a change of its picture.
class _RefusingPreview extends WorkshopPublishController {
  @override
  bool setPreview(WorkshopPreviewInput? preview) {
    state = state.copyWith(error: const WorkshopException('workshop_busy'));
    return false;
  }
}

/// The real publisher, noting which offer each confirmation was given.
class _RecordingPublisher extends WorkshopPublishController {
  final confirmed = <WorkshopPendingAbandonOffer>[];

  @override
  Future<void> confirmPendingAbandonment(WorkshopPendingAbandonOffer offered) {
    confirmed.add(offered);
    return super.confirmPendingAbandonment(offered);
  }
}

/// A publisher that takes the form but not a change of the rights tick.
class _RefusingTick extends WorkshopPublishController {
  @override
  bool setInput(WorkshopPublicationInput input) {
    if (input.rightsConfirmed) {
      state = state.copyWith(error: const WorkshopException('workshop_busy'));
      return false;
    }
    return super.setInput(input);
  }
}
