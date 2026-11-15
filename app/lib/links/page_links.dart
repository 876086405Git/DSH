// `dshgo://open/<page>` opens one of the app's pages and
// does nothing else. The bundled guide (docs/guide, the dsh-go-guide skill)
// links to pages this way, so a reply can say 「在这里打开」. A reply's
// Markdown link reaches the router through [openReplyPageLink]
// (ui/chat/render/markdown_body.dart); a link from outside the app arrives
// through [LinkHost] like any other.
//
// Pages only, from a fixed list: the settings index's pages and rows (a row
// opens its page) and a few 全部功能 pages; nothing that switches the
// conversation or the host, opens a sheet, runs an action, or needs an open
// conversation. An unknown page gets the router's 「无法打开这个链接」; one this
// OS doesn't have yet says that instead.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/android_features.dart';
import '../ui/companion/companion_page.dart';
import '../ui/features/feature_catalog.dart';
import '../ui/settings/index/settings_pages.dart';
import 'app_links.dart';

/// The host of page links: `dshgo://open/<page>`.
const pageLinkHost = 'open';

/// 全部功能 pages a link may open that aren't settings, by their
/// [FeatureItem.id]: each is a native page that needs no open conversation.
/// Settings pages and rows answer through the settings index
/// ([SettingsIndex.linkIds]).
const catalogPageLinks = <String>{'schedules', 'cordis', 'agent-team', 'forum', 'community', 'ds-bot', 'workspaces'};

/// 伙伴小屋: the home-screen widget opens it (android companion/CompanionWidget.kt).
const companionPageLink = 'companion';

/// 酒馆 (role play): main.dart registers its page ([registerPageLink]).
const tavernPageLink = 'tavern';

/// Pages the entry point adds, by id: pages under ui/ that this file may not
/// import itself (docs/architecture.md, 目录).
final _registeredPages = <String, Widget Function()>{};

/// Lets a link open [page] as [id]; main.dart calls it at startup, as it
/// registers the licences.
void registerPageLink(String id, Widget Function() page) => _registeredPages[id] = page;

/// Every page a link may name.
Set<String> get pageLinkIds => {
  ...SettingsIndex.linkIds,
  ...catalogPageLinks,
  companionPageLink,
  ..._registeredPages.keys,
};

/// The page id [uri] names: exactly `dshgo://open/<id>` (a trailing slash is
/// fine) with an id from [pageLinkIds]; null otherwise.
String? pageLinkId(Uri uri) {
  if (uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != pageLinkHost) return null;
  if (uri.userInfo.isNotEmpty || uri.hasPort || uri.hasQuery || uri.hasFragment) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1) return null;
  final id = segments.single;
  return pageLinkIds.contains(id) ? id : null;
}

/// The page for [id] ([pageLinkIds]); [sessionId] is the conversation open in
/// the chat, as 全部功能 passes it.
Widget? pageForId(String id, String? sessionId) {
  if (settingsPageForLink(id, sessionId: sessionId) case final page?) return page;
  if (id == companionPageLink) return const CompanionPage();
  if (_registeredPages[id] case final page?) return page();
  if (!catalogPageLinks.contains(id)) return null;
  for (final section in featureSections) {
    for (final item in section.items) {
      if (item.id != id || item.needsSession || item.action != null) continue;
      return item.native?.call(sessionId);
    }
  }
  return null;
}

typedef PageResolver = Widget? Function(String id, String? sessionId);

/// [pageForId] (tests swap in light pages); on HarmonyOS, Android's own pages
/// have none ([registerPageLinks] says so).
final pageLinkResolverProvider = Provider<PageResolver>((ref) {
  if (ref.watch(androidSystemFeaturesProvider)) return pageForId;
  final ios = ref.watch(operatingSystemProvider) == 'ios';
  return (id, sessionId) => SettingsIndex.androidOnlyLink(id, ios: ios) ? null : pageForId(id, sessionId);
});

/// Routes `dshgo://open/…` to its page, pushed over the home route. [session]
/// reads the conversation open in the chat. Returns the unregister function.
VoidCallback registerPageLinks(LinkRouter router, {String? Function()? session, PageResolver page = pageForId}) =>
    router.registerLinkHandler(pageLinkHost, (uri) async {
      final id = pageLinkId(uri);
      final context = router.context;
      if (id == null || context == null || !context.mounted) return false;
      final widget = page(id, session?.call());
      if (widget == null) {
        if (!SettingsIndex.androidOnlyLink(id)) return false;
        router.toast(appL10n.harmonyPageUnavailable);
        return true;
      }
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => widget)));
      return true;
    });

/// A link tapped in a reply: when it is a page link (any `dshgo://open/…`),
/// hands it to the router — which opens the page, or shows its toast for one
/// it doesn't know — and returns true. False for every other link.
bool openReplyPageLink(BuildContext context, String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != appLinkScheme || uri.host.toLowerCase() != pageLinkHost) {
    return false;
  }
  try {
    unawaited(ProviderScope.containerOf(context, listen: false).read(linkRouterProvider).open(uri));
  } catch (_) {
    // No provider scope above this text (a detached render): nothing to open.
  }
  return true;
}
