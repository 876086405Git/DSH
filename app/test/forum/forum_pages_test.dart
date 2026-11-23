// The forum pages with a fake API: browsing, paging, likes, replies, the
// composer's attachments, share-code cards and the app links.

import 'dart:async';

import 'package:dsh_app/forum/discourse_client.dart';
import 'package:dsh_app/forum/forum_models.dart';
import 'package:dsh_app/forum/forum_share.dart';
import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/ui/forum/forum_composer_sheet.dart';
import 'package:dsh_app/ui/forum/forum_home_page.dart';
import 'package:dsh_app/ui/forum/forum_link_host.dart';
import 'package:dsh_app/ui/forum/forum_topic_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../providers/support.dart' show settle;
import '../shell/golden_harness.dart';
import 'support.dart';

Future<void> pumpPage(WidgetTester tester, Widget home, List<Override> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides));
  await settle(tester);
}

/// Answers `Clipboard.getData` with [text].
void mockClipboard(WidgetTester tester, String? text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') return text == null ? null : {'text': text};
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

void main() {
  group('home', () {
    testWidgets('lists topics; capsules switch the feed; the end of the list loads more', (tester) async {
      final more = sampleTopic(200, '第二页的话题', posts: 3);
      final api = FakeForumApi(
        feeds: {
          const ForumFeed.latest(): [
            sampleTopicPage(more: true),
            ForumTopicListPage(topics: [more]),
          ],
          ForumFeed.category(sampleCategories[1]): [
            ForumTopicListPage(topics: [sampleTopic(300, '只在插件分类里')]),
          ],
        },
      );
      await pumpPage(tester, const ForumHomePage(), forumOverrides(api));
      expect(find.text('分享一个联网搜索插件，装上就能查实时资料'), findsOneWidget);
      expect(find.text('12 回复'), findsOneWidget);

      await tester.fling(find.byType(CustomScrollView), const Offset(0, -2000), 3000);
      await settle(tester);
      expect(api.calls, contains('topics:latest:1'));
      await tester.fling(find.byType(CustomScrollView), const Offset(0, -2000), 3000);
      await settle(tester);
      expect(find.text('第二页的话题'), findsOneWidget);

      await tester.fling(find.byType(CustomScrollView), const Offset(0, 4000), 3000);
      await settle(tester);
      await tester.tap(find.text('插件').first);
      await settle(tester);
      expect(api.calls, contains('topics:category2:0'));
      expect(find.text('只在插件分类里'), findsOneWidget);
      // 「未分类」-like categories and read-only ones still show as capsules;
      // only the uncategorized one is hidden (parsing test).
      expect(find.text('公告'), findsWidgets);
    });

    testWidgets('signed out: 发帖 asks to sign in, 登录 opens the browser flow', (tester) async {
      late FakeForumAuth auth;
      await pumpPage(
        tester,
        const ForumHomePage(),
        forumOverrides(FakeForumApi(), authController: () => auth = FakeForumAuth(signedOutAuth)),
      );
      expect(find.byTooltip('通知'), findsNothing);
      await tester.tap(find.text('发帖'));
      await settle(tester);
      expect(find.text('登录论坛'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '登录'));
      await settle(tester);
      expect(auth.signIns, 1);
      expect(find.text('在浏览器里完成登录'), findsOneWidget);
    });

    testWidgets('a forum that is down shows one line and a retry', (tester) async {
      final api = FakeForumApi()..failWith = const ForumException(ForumErrorKind.network);
      await pumpPage(tester, const ForumHomePage(), forumOverrides(api));
      expect(find.text('没能连上论坛'), findsOneWidget);
      api.failWith = null;
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(find.text('分享一个联网搜索插件，装上就能查实时资料'), findsOneWidget);
    });

    testWidgets('a new topic opens after posting', (tester) async {
      final api = FakeForumApi(signedIn: true, topicDetails: {101: sampleTopicDetail(), 777: sampleTopicDetail()});
      await pumpPage(tester, const ForumHomePage(), forumOverrides(api, auth: signedInAuth));
      await tester.tap(find.text('发帖'));
      await settle(tester);
      await tester.tap(find.text('发布'));
      await settle(tester);
      expect(find.text('先写标题'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), '省电配置');
      await tester.tap(find.text('发布'));
      await settle(tester);
      expect(find.text('选一个分类'), findsOneWidget);
      await tester.tap(find.text('配置分享').last);
      await tester.tap(find.text('发布'));
      await settle(tester);
      expect(find.text('写点内容再发'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), '一晚上只掉 3% 电');
      await tester.tap(find.text('发布'));
      await settle(tester);
      expect(api.created.single, {'title': '省电配置', 'raw': '一晚上只掉 3% 电', 'category': 3});
      expect(api.calls, contains('topic:777'));
    });
  });

  group('topic', () {
    testWidgets('likes at once, bookmarks, and a reply appears at the end', (tester) async {
      final api = FakeForumApi(signedIn: true);
      await pumpPage(tester, const ForumTopicPage(topicId: 101), forumOverrides(api, auth: signedInAuth));
      expect(find.text('分享一个联网搜索插件，装上就能查实时资料'), findsWidgets);
      expect(find.text('ModSearch 联网搜索'), findsOneWidget);

      await tester.tap(find.byTooltip('点赞').first);
      await settle(tester);
      expect(api.calls, contains('like:1001'));
      expect(find.text('13'), findsOneWidget);

      await tester.tap(find.byTooltip('书签').first);
      await settle(tester);
      expect(api.calls, contains('bookmark:1001'));
      expect(find.text('已加入书签'), findsOneWidget);

      await tester.tap(find.text('写回复…'));
      await settle(tester);
      expect(find.text('回复'), findsWidgets);
      await tester.enterText(find.byType(TextField), '感谢分享，已经装上了');
      await tester.tap(find.text('发送'));
      await settle(tester);
      expect(api.calls, contains('reply:101:-'));
      await tester.fling(find.byType(CustomScrollView), const Offset(0, -3000), 3000);
      await settle(tester);
      expect(find.text('感谢分享，已经装上了'), findsOneWidget);
    });

    testWidgets('more posts load as you scroll', (tester) async {
      final first = sampleTopicDetail().posts;
      final extra = [for (var i = 0; i < 3; i++) samplePost(2000 + i, 10 + i, '<p>后面的第 ${i + 1} 条</p>')];
      final api = FakeForumApi(
        topicDetails: {
          101: sampleTopicDetail(stream: [for (final p in first) p.id, for (final p in extra) p.id], posts: first),
        },
        morePosts: {for (final p in extra) p.id: p},
      );
      await pumpPage(tester, const ForumTopicPage(topicId: 101), forumOverrides(api));
      await tester.fling(find.byType(CustomScrollView), const Offset(0, -3000), 3000);
      await settle(tester);
      expect(api.calls, contains('posts:101:2000,2001,2002'));
      await tester.fling(find.byType(CustomScrollView), const Offset(0, -3000), 3000);
      await settle(tester);
      expect(find.text('后面的第 3 条'), findsOneWidget);
    });

    testWidgets('signed out: liking asks to sign in; 安装 hands the share link on', (tester) async {
      ShareLink? installed;
      await pumpPage(tester, const ForumTopicPage(topicId: 101), [
        ...forumOverrides(FakeForumApi()),
        forumShareInstallerProvider.overrideWithValue((link) async {
          installed = link;
          return true;
        }),
      ]);
      expect(find.text('登录后回复'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '安装'));
      await settle(tester);
      expect(installed?.code, samplePluginLink().code);
      await tester.tap(find.byTooltip('点赞').first);
      await settle(tester);
      expect(find.text('登录论坛'), findsOneWidget);
    });
  });

  group('composer', () {
    Future<void> openReply(WidgetTester tester, FakeForumApi api, {List<Override> extra = const []}) async {
      await pumpPage(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showForumComposer(context, const ForumReplyTarget(topicId: 101, topicTitle: '话题')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        [...forumOverrides(api, auth: signedInAuth), ...extra],
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    String body(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('附上分享码 takes the share link from the clipboard', (tester) async {
      final link = samplePluginLink();
      mockClipboard(tester, '来自 dsh-go 的分享：${link.webLink} 点开就能装');
      await openReply(tester, FakeForumApi(signedIn: true));
      await tester.enterText(find.byType(TextField), '推荐这个');
      await tester.tap(find.text('附上分享码'));
      await settle(tester);
      expect(body(tester), '推荐这个\n[插件：ModSearch 联网搜索](${link.webLink})\n');
    });

    testWidgets('without a share link on the clipboard it says where to get one', (tester) async {
      mockClipboard(tester, 'just some text');
      await openReply(tester, FakeForumApi(signedIn: true));
      await tester.tap(find.text('附上分享码'));
      await settle(tester);
      expect(find.text('先在分享里复制分享码'), findsOneWidget);
    });

    testWidgets('a picked image uploads and goes in as upload://', (tester) async {
      final api = FakeForumApi(signedIn: true);
      await openReply(
        tester,
        api,
        extra: [
          forumImagePickerProvider.overrideWithValue(() async => (bytes: [1, 2, 3, 4], name: 'shot.png')),
        ],
      );
      await tester.tap(find.byTooltip('图片'));
      await settle(tester);
      expect(api.calls, contains('upload:shot.png:4'));
      expect(body(tester), '![shot|640x480](upload://abc123.png)\n');
    });

    testWidgets('the forum refusing a post shows its own words; the draft survives', (tester) async {
      final api = FakeForumApi(signedIn: true)..failWith = const ForumException(ForumErrorKind.rejected, '正文太短');
      await openReply(tester, api);
      await tester.enterText(find.byType(TextField), '嗯');
      await tester.tap(find.text('发送'));
      await settle(tester);
      expect(find.text('正文太短'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(body(tester), '嗯');
    });

    testWidgets('closed while sending: a landed post clears its draft, not a newer one', (tester) async {
      final api = _HeldReplyApi();
      await openReply(tester, api);
      Future<void> sendAndClose(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.tap(find.text('发送'));
        await tester.pump();
        await tester.tap(find.byTooltip('关闭'));
        await settle(tester);
      }

      await sendAndClose('第一条');
      await tester.tap(find.text('open'));
      await settle(tester);
      await sendAndClose('第二条');
      api.held[0].complete();
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(body(tester), '第二条');
      await tester.tap(find.byTooltip('关闭'));
      await settle(tester);
      api.held[1].complete();
      await settle(tester);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(body(tester), isEmpty);
    });
  });

  group('links', () {
    test('dshgo://forum paths', () {
      expect(forumRouteFor(Uri.parse('dshgo://forum')), isNotNull);
      expect(forumRouteFor(Uri.parse('dshgo://forum/t/101/3')), isNotNull);
      expect(forumRouteFor(Uri.parse('dshgo://forum/t/some-slug/101')), isNotNull);
      expect(forumRouteFor(Uri.parse('dshgo://forum/u/someone')), isNull);
      expect(forumRouteFor(Uri.parse('dshgo://forum/t/x')), isNull);
    });

    testWidgets('ForumLinkHost takes the sign-in redirect and topic links', (tester) async {
      final links = StreamController<Uri>.broadcast();
      addTearDown(links.close);
      final router = LinkRouter(links.stream, grace: const Duration(milliseconds: 100));
      addTearDown(router.dispose);
      late _RecordingAuth auth;
      await pumpPage(tester, const Scaffold(body: Stack(children: [LinkHost(), ForumLinkHost()])), [
        ...forumOverrides(FakeForumApi(), authController: () => auth = _RecordingAuth()),
        linkRouterProvider.overrideWithValue(router),
      ]);
      links.add(Uri.parse('dshgo://forum/auth?payload=abc'));
      await settle(tester);
      expect(auth.redirects.single.queryParameters['payload'], 'abc');
      expect(find.text('已登录论坛'), findsOneWidget);

      links.add(Uri.parse('dshgo://forum/t/101'));
      await settle(tester);
      expect(find.byType(ForumTopicPage), findsOneWidget);
    });
  });
}

/// Holds each reply until its entry in [held] completes.
class _HeldReplyApi extends FakeForumApi {
  _HeldReplyApi() : super(signedIn: true);

  final held = <Completer<void>>[];

  @override
  Future<ForumPostResult> reply({required int topicId, required String raw, int? replyToPostNumber}) async {
    await (held..add(Completer())).last.future;
    return super.reply(topicId: topicId, raw: raw, replyToPostNumber: replyToPostNumber);
  }
}

class _RecordingAuth extends FakeForumAuth {
  _RecordingAuth() : super(signedOutAuth);

  final redirects = <Uri>[];

  @override
  Future<bool> handleRedirect(Uri uri) async {
    redirects.add(uri);
    state = signedInAuth;
    return true;
  }
}
