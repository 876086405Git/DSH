// 「分享」: one panel for everything a conversation or a delivered file can
// become — a link, a picture, a file, plain text. What to share (the scope and
// what it includes) is set once on the first page; each way out is a page of
// its own (share_panel_pages.dart). docs/design/share-redesign.md.
//
// The state lives in a [SharePanelModel] above the panel's own page stack, so
// going into 「链接」 and back keeps the scope, the privacy choices and a link
// just made.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_export.dart';
import '../../share_code/conversation_html.dart';
import '../../share_code/conversation_redact.dart' show markdownWithoutImages, redactText;
import '../../share_code/conversation_share.dart';
import '../../share_hosted/hosted_client.dart' show HostedShareException;
import '../../share_hosted/hosted_links_state.dart' show HostedStorageException;
import '../../state/app_info.dart';
import '../../state/android_features.dart';
import '../../state/artifact_files.dart';
import '../../state/artifacts.dart';
import '../../state/chat_state.dart';
import '../../state/regenerate.dart' show sessionImageBytes;
import '../../state/sessions_state.dart';
import '../../usage/usage_stats.dart';
import '../chat/dsh_ui/dsh_ui.dart' show dshUiPlainText;
import '../common/app_sheet.dart';
import '../common/sheet_navigator.dart';
import '../replay/continue_chat.dart' show conversationMarkdown;
import '../replay/conversation_out.dart';
import 'share_content.dart';
import 'share_image_page.dart';
import 'share_panel_pages.dart';

/// How much of a conversation goes out.
enum ShareScope {
  /// The reply the panel was opened from, and the question above it.
  reply,

  /// Messages picked one by one (or a stretch at once).
  picked,

  /// All of it.
  whole;

  String get label => switch (this) {
    ShareScope.reply => appL10n.viewShareScopeReply,
    ShareScope.picked => appL10n.viewShareScopePicked,
    ShareScope.whole => appL10n.viewShareWhole,
  };
}

/// What a shared conversation carries besides its messages. Set once, true
/// for every way out. Redaction (keys, personal paths) is not a choice: it
/// always applies.
@immutable
class SharePrivacy {
  const SharePrivacy({this.thinking = true, this.tools = true, this.images = true});

  /// The reasoning behind replies (files and links; a card never shows it).
  final bool thinking;

  /// Tool calls with their results, todos and goals; on a card, what the
  /// agent did.
  final bool tools;

  /// Pictures attached to prompts; on a card, a reply's pictures too.
  final bool images;

  SharePrivacy copyWith({bool? thinking, bool? tools, bool? images}) =>
      SharePrivacy(thinking: thinking ?? this.thinking, tools: tools ?? this.tools, images: images ?? this.images);

  @override
  bool operator ==(Object other) =>
      other is SharePrivacy && other.thinking == thinking && other.tools == tools && other.images == images;

  @override
  int get hashCode => Object.hash(thinking, tools, images);
}

/// What the panel shares.
@immutable
sealed class ShareSubject {
  const ShareSubject();
}

/// A conversation: one in the chat ([sessionId]) or a replayed one
/// ([replay]). [reply] is the reply the panel was opened from (「这条回复」);
/// without it the panel starts at the whole conversation.
final class ConversationSubject extends ShareSubject {
  const ConversationSubject({this.sessionId, this.replay, this.reply}) : assert(sessionId != null || replay != null);

  final String? sessionId;
  final ReplaySource? replay;
  final AssistantChatItem? reply;
}

/// A replayed conversation as the replay page holds it.
@immutable
class ReplaySource {
  const ReplaySource({required this.share, required this.state, this.assets = const {}, this.container});

  final ConversationShare share;

  /// The conversation at the end of its replay, as the chat's items.
  final ChatState state;

  /// The file's pictures by asset id (= the replay's attachment id).
  final Map<String, ConversationAsset> assets;

  /// The replay page's providers (its pictures come from the file).
  final ProviderContainer? container;
}

/// A delivered file: its card ([card], [refine] once the picture or first
/// lines are in) and the file itself.
final class ArtifactSubject extends ShareSubject {
  const ArtifactSubject({required this.sessionId, required this.artifact, required this.card, this.refine});

  final String sessionId;
  final Artifact artifact;
  final ShareContent card;
  final Future<ShareContent?>? refine;
}

/// Opens the share panel for [subject], at [scope] (default: the reply when
/// there is one, otherwise the whole conversation).
Future<void> showSharePanel(BuildContext context, ShareSubject subject, {ShareScope? scope}) {
  HapticFeedback.selectionClick();
  final replay = switch (subject) {
    ConversationSubject(:final replay?) => replay.container,
    _ => null,
  };
  return showAppSheet<void>(
    context,
    dismissal: SheetDismissal.drag,
    heightFactor: 0.92,
    builder: (_) {
      final panel = SharePanel(subject: subject, scope: scope);
      return replay == null ? panel : UncontrolledProviderScope(container: replay, child: panel);
    },
  );
}

/// The panel: its model, then its own page stack starting at the first page.
class SharePanel extends ConsumerStatefulWidget {
  const SharePanel({super.key, required this.subject, this.scope, this.clock, this.loadImage});

  final ShareSubject subject;
  final ShareScope? scope;

  /// Export time (tests).
  final DateTime Function()? clock;

  /// Reads a prompt's picture for a file or link (tests); default: from the
  /// engine, or from the replayed file.
  final ExportImageLoader? loadImage;

  @override
  ConsumerState<SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends ConsumerState<SharePanel> {
  late final SharePanelModel _model;
  ProviderSubscription<ChatState>? _chat;

  @override
  void initState() {
    super.initState();
    _model = SharePanelModel(
      subject: widget.subject,
      ref: ref,
      scope: widget.scope,
      clock: widget.clock ?? DateTime.now,
      loadImage: widget.loadImage,
    );
    if (widget.subject case ConversationSubject(:final sessionId?, replay: null)) {
      // Held while the panel is up; history read for a whole conversation
      // arrives through it.
      _chat = ref.listenManual(chatProvider(sessionId), (_, _) => _model.chatChanged());
    }
    _model.start();
  }

  @override
  void dispose() {
    _chat?.close();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SharePanelScope(
    model: _model,
    child: SheetNavigator(root: (_) => const SharePanelHome()),
  );
}

/// The panel's model for the pages under it.
class SharePanelScope extends InheritedNotifier<SharePanelModel> {
  const SharePanelScope({super.key, required SharePanelModel model, required super.child}) : super(notifier: model);

  static SharePanelModel of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SharePanelScope>()!.notifier!;
}

/// A file form of what is shared: its text and size.
typedef ShareFileText = ({String text, int bytes});

/// What the panel has made of the current scope and privacy.
class ShareBuild {
  ShareBuild(this.share, this.file, {this.assets = const {}});

  final ConversationShare share;

  /// The pictures the file carries, by asset id (for its replay preview).
  final Map<String, ConversationAsset> assets;

  /// The `.dshgo` file (and what a link uploads).
  final ShareFileText file;

  ShareFileText? _page;
  ShareFileText? _markdown;

  ShareFileText of(ConversationFormat format) => switch (format) {
    ConversationFormat.file => file,
    ConversationFormat.page => _page ??= _sized(conversationHtml(file.text, title: share.title)),
    ConversationFormat.markdown => _markdown ??= _sized(conversationMarkdown(share)),
  };

  /// Over what a file can carry (`maxConversationFileBytes`).
  bool get tooLarge => file.bytes > maxConversationFileBytes;

  static ShareFileText _sized(String text) => (text: text, bytes: utf8.encode(text).length);
}

/// Busy states of the panel's actions.
enum ShareWork { text, link, saving, sharing }

/// Everything the panel's pages show and do.
class SharePanelModel extends ChangeNotifier {
  SharePanelModel({
    required this.subject,
    required this._ref,
    ShareScope? scope,
    required this._clock,
    this._loadImage,
  }) {
    final conversation = this.conversation;
    _scope = conversation == null
        ? ShareScope.whole
        : (scope ?? (conversation.reply != null ? ShareScope.reply : ShareScope.whole));
    if (!scopes.contains(_scope)) _scope = scopes.last;
  }

  final ShareSubject subject;
  final WidgetRef _ref;
  final DateTime Function() _clock;
  final ExportImageLoader? _loadImage;

  /// The card's look, shared by the preview and 「图片」.
  final style = ShareCardStyle();

  /// The panel's clock (a link's expiry, a file's time).
  DateTime now() => _clock();

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _stopTimer?.cancel();
    _doneTimer?.cancel();
    style.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Starts what the first page needs.
  void start() {
    if (_scope == ShareScope.whole) unawaited(_loadHistory());
    // A file's picture or first lines arrive after the panel is up.
    artifact?.refine?.then((card) {
      if (card == null || _disposed) return;
      _artifactCard = card;
      _notify();
    }, onError: (Object _) {});
  }

  ShareContent? _artifactCard;

  // ── The subject ──────────────────────────────────────────────────────────

  ConversationSubject? get conversation => switch (subject) {
    final ConversationSubject c => c,
    _ => null,
  };

  ArtifactSubject? get artifact => switch (subject) {
    final ArtifactSubject a => a,
    _ => null,
  };

  String? get _sessionId => conversation?.sessionId;
  ReplaySource? get _replay => conversation?.replay;

  /// The conversation as it is now.
  ChatState get chat {
    if (_replay case final replay?) return replay.state;
    return _ref.read(chatProvider(_sessionId!));
  }

  /// The reply the panel was opened from, as the chat holds it now.
  AssistantChatItem? get anchor {
    final reply = conversation?.reply;
    if (reply == null) return null;
    return chat.items.whereType<AssistantChatItem>().where((i) => i.key == reply.key).firstOrNull ?? reply;
  }

  /// The conversation is still arriving (opened from the drawer).
  bool get loading => conversation != null && chat.loading && chat.items.isEmpty;

  List<ChatItem> get shareable => shareableItems(chat.items);

  /// Nothing to share yet.
  bool get isEmpty => conversation != null && !loading && shareable.isEmpty;

  /// The links this app can make (null: none).
  bool get _harmony => _ref.read(operatingSystemProvider) == 'ohos';

  ConversationLinkMaker? get linkMaker => conversation == null ? null : _ref.read(conversationLinkMakerProvider);

  void chatChanged() {
    _card = null;
    _notify();
  }

  // ── Scope and privacy ────────────────────────────────────────────────────

  late ShareScope _scope;
  Set<String>? _picked;
  SharePrivacy _privacy = const SharePrivacy();

  ShareScope get scope => _scope;
  SharePrivacy get privacy => _privacy;

  /// The scopes this conversation offers: 「这条回复」 only with a reply.
  List<ShareScope> get scopes => [
    if (conversation?.reply != null) ShareScope.reply,
    ShareScope.picked,
    ShareScope.whole,
  ];

  /// What 「选中消息」 starts with: the picks so far, else the reply and its
  /// question, else the last exchange.
  Set<String> get pickStart {
    if (_picked case final picked?) return picked;
    final reply = anchor ?? shareable.whereType<AssistantChatItem>().lastOrNull;
    return reply == null ? const {} : initialSelection(chat.items, reply);
  }

  /// `ChatItem.key`s of the messages in scope.
  Set<String> get keys => switch (_scope) {
    ShareScope.reply => initialSelection(chat.items, anchor!),
    ShareScope.picked => _picked ?? pickStart,
    ShareScope.whole => {for (final item in shareable) item.key},
  };

  void setScope(ShareScope scope) {
    if (scope == _scope) return;
    _scope = scope;
    _export = null;
    _changed();
    if (scope == ShareScope.whole) unawaited(_loadHistory());
  }

  /// 「选中消息」 with [keys].
  void pick(Set<String> keys) {
    if (keys.isEmpty) return;
    _picked = {...keys};
    _scope = ShareScope.picked;
    _export = null;
    _changed();
  }

  void setPrivacy(SharePrivacy privacy) {
    if (privacy == _privacy) return;
    _privacy = privacy;
    _changed();
  }

  /// What is shared changed: what was made of the old content goes.
  void _changed() {
    _card = null;
    _built = null;
    _building = null;
    _error = null;
    _fileSaved = false;
    _notify();
  }

  /// What scope and privacy give, as one value (a link is made for one).
  Object get _contentKey => (_scope, (keys.toList()..sort()).join('\n'), _privacy);

  // ── The card ─────────────────────────────────────────────────────────────

  ShareContent? _card;

  /// The card for what is in scope (null while the conversation is still
  /// arriving or empty).
  ShareContent? get card {
    if (artifact case final a?) return _artifactCard ?? a.card;
    if (loading || isEmpty) return null;
    return _card ??= _makeCard();
  }

  ShareContent _makeCard() {
    final state = chat;
    final reply = anchor;
    if (_scope == ShareScope.reply && reply != null) {
      return shareContentForReply(state, reply, sessionId: _sessionId, images: _privacy.images, tools: _privacy.tools);
    }
    return shareContentForItems(state, keys, sessionId: _sessionId, images: _privacy.images, tools: _privacy.tools);
  }

  /// Messages, tool calls and pictures in scope, for the summary line.
  ({int messages, int tools, int images}) get counts {
    final state = chat;
    final keys = this.keys;
    final picked = [
      for (final item in shareable)
        if (keys.contains(item.key)) item,
    ];
    final whole = _scope == ShareScope.whole;
    final turns = {for (final reply in picked.whereType<AssistantChatItem>()) ?turnOf(state.turns, reply.seq)};
    var tools = 0;
    if (_privacy.tools) {
      for (final item in state.items) {
        if (item is ToolChatItem && (whole || turns.contains(turnOf(state.turns, item.seq)))) tools++;
      }
    }
    var images = 0;
    if (_privacy.images) {
      for (final prompt in picked.whereType<UserChatItem>()) {
        images += prompt.images.length;
      }
    }
    return (messages: picked.length, tools: tools, images: images);
  }

  // ── History (a whole conversation) ───────────────────────────────────────

  Future<void>? _history;

  /// Older history is being read.
  bool get historyLoading => _historyLoading;
  bool _historyLoading = false;

  Future<void> _loadHistory() => _history ??= _readHistory();

  Future<void> _readHistory() async {
    final sessionId = _sessionId;
    if (sessionId == null || _replay != null) return;
    _historyLoading = true;
    _notify();
    try {
      final provider = chatProvider(sessionId);
      for (var i = 0; i < 40 && _ref.read(provider).loading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (_disposed) return;
      }
      final notifier = _ref.read(provider.notifier);
      for (var page = 0; page < 60 && _ref.read(provider).hasMoreHistory; page++) {
        final before = _ref.read(provider).items.length;
        await notifier.loadOlder();
        if (_disposed) return;
        if (_ref.read(provider).items.length == before) break;
      }
    } catch (_) {
      // Whatever arrived is shared.
    } finally {
      _historyLoading = false;
      _card = null;
      _notify();
    }
  }

  // ── Files and links ──────────────────────────────────────────────────────

  Future<ConversationExport>? _export;
  ShareBuild? _built;
  Future<ShareBuild>? _building;

  /// What the current scope and privacy make (null until [prepare] is done).
  ShareBuild? get built => _built;

  /// Builds the file forms of what is shared; pages that show a size call it.
  Future<ShareBuild> prepare() => _building ??= _build();

  Future<ShareBuild> _build() async {
    final key = _contentKey;
    final export = await (_export ??= _makeExport());
    final whole = _scope == ShareScope.whole;
    final share = export.build(
      only: whole ? null : keys,
      thinking: _privacy.thinking,
      tools: _privacy.tools,
      images: _privacy.images,
      now: _clock(),
      app: 'dsh-go ${AppInfo.version.split('+').first}',
    );
    final built = ShareBuild(share, export.file(share), assets: {for (final a in export.assets) a.id: a});
    // Changed while building: the newer request answers.
    if (key == _contentKey && !_disposed) {
      _built = built;
      _notify();
    }
    return built;
  }

  Future<ConversationExport> _makeExport() async {
    final source = await _source();
    final export = ConversationExport(source);
    final load = _loadImage ?? _defaultLoader();
    if (load != null) await export.loadImages(load);
    return export;
  }

  ExportImageLoader? _defaultLoader() {
    if (_replay case final replay?) return (image) async => replay.assets[image.attachmentId]?.bytes;
    final sessionId = _sessionId;
    if (sessionId == null) return null;
    return (image) => sessionImageBytes(_ref, sessionId, image);
  }

  /// The conversation with all of its history.
  Future<ConversationSource> _source() async {
    if (_replay case final replay?) {
      final end = replay.state;
      return ConversationSource(
        title: replay.share.title,
        items: end.items,
        turns: end.turns,
        commands: end.commands,
        model: replay.share.model,
      );
    }
    await _loadHistory();
    final sessionId = _sessionId!;
    final state = chat;
    final notifier = _ref.read(chatProvider(sessionId).notifier);
    final listed = _ref.exists(sessionsProvider) ? _ref.read(sessionsProvider).value : null;
    final title =
        state.title ??
        listed?.where((s) => s.sessionId == sessionId).firstOrNull?.projections.title ??
        appL10n.viewShareChat;
    return ConversationSource(
      title: title,
      items: state.items,
      turns: state.turns,
      commands: state.commands,
      events: List.of(notifier.events),
      model: state.model?.model,
    );
  }

  // ── Errors and busy keys ─────────────────────────────────────────────────

  ShareWork? _work;
  String? _error;
  double? _progress;

  ShareWork? get work => _work;
  String? get error => _error;

  /// Download progress of a delivered file (0–1), when known.
  double? get progress => _progress;

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  Future<void> _busy(ShareWork work, Future<void> Function() body) async {
    if (_work != null) return;
    _work = work;
    _error = null;
    _progress = null;
    _notify();
    try {
      await body();
    } finally {
      _work = null;
      _progress = null;
      _notify();
    }
  }

  // ── 文字 ─────────────────────────────────────────────────────────────────

  /// The text 「文字」 hands to the share sheet: a reply's own words, or the
  /// picked / whole conversation as Markdown.
  Future<String> shareTextContent() async {
    final reply = anchor;
    if (_scope == ShareScope.reply && reply != null) {
      final text = redactText(dshUiPlainText(reply.text).trim());
      return _privacy.images ? text : markdownWithoutImages(text);
    }
    return (await prepare()).of(ConversationFormat.markdown).text;
  }

  /// Something went out (usage statistics). The panel may be gone by then.
  void _shared() {
    if (!_disposed) _ref.read(usageStatsProvider.notifier).count(UsageCount.share);
  }

  Future<void> shareText() => _busy(ShareWork.text, () async {
    try {
      final text = await shareTextContent();
      await _ref.read(conversationOutProvider).shareText(text);
      _shared();
    } catch (_) {
      _error = appL10n.viewShareOpenFailed;
    }
  });

  // ── 链接 ─────────────────────────────────────────────────────────────────

  LinkExpiry _expiry = LinkExpiry.month;
  ConversationLink? _link;
  Object? _linkFor;
  ({ConversationLink link, Object key})? _stopped;
  Timer? _stopTimer;

  LinkExpiry get expiry => _expiry;

  set expiry(LinkExpiry value) {
    if (value == _expiry) return;
    _expiry = value;
    _error = null;
    _notify();
  }

  /// The link made for what is shared now, at the chosen expiry.
  ConversationLink? get link => _linkFor == (_contentKey, _expiry) ? _link : null;

  /// A link just stopped, while it can still be brought back.
  ConversationLink? get stopped => _stopped?.link;

  Future<void> makeLink() => _busy(ShareWork.link, () async {
    final maker = linkMaker;
    if (maker == null) return;
    final key = (_contentKey, _expiry);
    try {
      final built = await prepare();
      if (built.tooLarge) return;
      final link = await maker.upload(conversationFileBytes(built.file.text), _expiry, title: built.share.title);
      _shared();
      HapticFeedback.lightImpact();
      _link = link;
      if (_harmony) _error = link.locallySaved ? null : appL10n.remoteHostedCreatedUnsaved;
      _linkFor = key;
      _stopped = null;
      _stopTimer?.cancel();
    } catch (e) {
      _error = _harmony && e is HostedStorageException
          ? appL10n.remoteHostedLoadFailed
          : e is HostedShareException
          ? e.message
          : appL10n.viewShareLinkFailed;
    }
  });

  /// 「停止分享」: the link stops working once the undo window passes.
  Future<void> stopLink() async {
    final maker = linkMaker;
    final link = this.link;
    if (maker == null || link == null) return;
    final key = _linkFor!;
    if (_harmony) {
      try {
        await maker.revoke(link);
      } catch (_) {
        _error = appL10n.remoteHostedStopFailed;
        _notify();
        return;
      }
      _error = null;
    } else {
      await maker.revoke(link);
    }
    _link = null;
    _linkFor = null;
    _stopped = (link: link, key: key);
    _stopTimer?.cancel();
    _stopTimer = Timer(maker.undoWindow, () {
      _stopped = null;
      _notify();
    });
    _notify();
  }

  /// Takes 「停止分享」 back.
  Future<void> restoreLink() async {
    final maker = linkMaker;
    final stopped = _stopped;
    if (maker == null || stopped == null) return;
    if (_harmony) {
      try {
        await maker.restore(stopped.link);
        _error = null;
      } on ConversationLinkRestoreUnsaved {
        _error = appL10n.remoteHostedUndoUnsaved;
      } catch (_) {
        _error = appL10n.remoteHostedUndoFailed;
        _notify();
        return;
      }
      _stopTimer?.cancel();
    } else {
      _stopTimer?.cancel();
      await maker.restore(stopped.link);
    }
    _stopped = null;
    _link = stopped.link;
    _linkFor = stopped.key;
    _notify();
  }

  Future<void> copyLink() async {
    final link = this.link;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: link.url.toString()));
  }

  Future<void> shareLink() async {
    final link = this.link;
    final built = _built;
    if (link == null || built == null) return;
    try {
      await _ref.read(conversationOutProvider).shareText(appL10n.viewShareLinkText(built.share.title, '${link.url}'));
    } catch (_) {
      _error = appL10n.viewShareOpenFailed;
      _notify();
    }
  }

  // ── 文件 ─────────────────────────────────────────────────────────────────

  ConversationFormat _format = ConversationFormat.file;
  bool _fileSaved = false;
  Timer? _doneTimer;

  ConversationFormat get format => _format;

  set format(ConversationFormat value) {
    if (value == _format) return;
    _format = value;
    _error = null;
    _fileSaved = false;
    _notify();
  }

  /// Just saved: 「已保存」 for a moment.
  bool get fileSaved => _fileSaved;

  /// The chosen form can't go out: over the size a file can carry.
  bool get fileTooLarge => _format.carriesFile && (_built?.tooLarge ?? false);

  Future<void> saveFile() => _busy(ShareWork.saving, () async {
    try {
      if (artifact case final a?) {
        await _ref.read(artifactFilesProvider).saveToDownloads(a.sessionId, a.artifact, onProgress: _onProgress);
      } else {
        final out = _ref.read(conversationOutProvider);
        final built = await prepare();
        final content = built.of(_format).text;
        await out.save(ConversationOut.fileName(built.share.title, _format), content, _format);
      }
      _shared();
      HapticFeedback.lightImpact();
      _fileSaved = true;
      _doneTimer?.cancel();
      _doneTimer = Timer(const Duration(milliseconds: 2400), () {
        _fileSaved = false;
        _notify();
      });
    } on PlatformException catch (e) {
      if (saveWindowDismissed(e)) return;
      _error = e.code == 'permission' ? appL10n.viewShareNoPermission : appL10n.commonSaveFailedRetry;
    } catch (e) {
      _error = artifact != null ? artifactErrorText(e) : appL10n.commonSaveFailedRetry;
    }
  });

  Future<void> shareFile() => _busy(ShareWork.sharing, () async {
    try {
      if (artifact case final a?) {
        await _ref.read(artifactFilesProvider).share(a.sessionId, a.artifact, onProgress: _onProgress);
      } else {
        final out = _ref.read(conversationOutProvider);
        final built = await prepare();
        final content = built.of(_format).text;
        final file = await out.write(ConversationOut.fileName(built.share.title, _format), content);
        await out.shareFile(file, _format);
      }
      _shared();
    } catch (e) {
      _error = artifact != null && e is! PlatformException ? artifactErrorText(e) : appL10n.viewShareOpenFailed;
    }
  });

  void _onProgress(double? progress) {
    _progress = progress;
    _notify();
  }
}
