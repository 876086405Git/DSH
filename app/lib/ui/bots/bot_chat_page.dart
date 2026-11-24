// A Bot's own chat: the whole conversation across its parts as DS Bot lays
// it out, the reply it is writing, its cards (a question, a view, a model to
// pick, a DSH approval) and the chat's composer.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/settings_state.dart';
import '../../state/bots_state.dart';
import '../../state/connection_state.dart';
import '../chat/composer.dart';
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/model_sheet.dart';
import '../chat/widgets/approval_card.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import 'bot_stop_guard.dart';
import 'bot_action_scope.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_draft_send.dart';
import 'bot_avatar.dart';
import 'unavailable_message.dart';
import 'bot_chat_kit.dart';
import 'bot_details_page.dart';
import 'bot_format.dart';
import 'bot_pending_card.dart';

class BotChatPage extends ConsumerStatefulWidget {
  const BotChatPage({super.key, required this.botId});

  final String botId;

  static Route<void> route(String botId) => MaterialPageRoute<void>(builder: (_) => BotChatPage(botId: botId));

  @override
  ConsumerState<BotChatPage> createState() => _BotChatPageState();
}

class _BotChatPageState extends ConsumerState<BotChatPage> {
  late final BotStopGuard _stopGuard;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scrolled = ValueNotifier(0.0);
  late final DsBotViewingController _viewing;

  @override
  void initState() {
    super.initState();
    _stopGuard = BotStopGuard(ref);
    _viewing = ref.read(dsBotViewingProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _viewing.set(widget.botId);
    });
  }

  @override
  void dispose() {
    _stopGuard.dispose();
    _viewing.leave(widget.botId);
    _input.dispose();
    _focus.dispose();
    _scrolled.dispose();
    super.dispose();
  }

  /// Whether what the person sends now still goes to this page's Bot.
  bool _sendsTo(BotActionScope target, String part) {
    if (!mounted || target.botId != widget.botId || !target.current(context, ref)) return false;
    final status = ref.read(dsBotProvider);
    return status.ready && status.team?.bot(widget.botId)?.sessionId == part;
  }

  Future<void> _send(BotActionScope target, String part) async {
    if (!_sendsTo(target, part)) return;
    await sendBotDraft(
      context,
      ref,
      _input,
      botId: widget.botId,
      send: (text) => ref.read(botChatProvider(widget.botId).notifier).send(text),
    );
  }

  /// A card's answer, sent as the person's message (`[dsh-ui reply] …`).
  Future<bool> _reply(BotActionScope target, String part, String text) async =>
      _sendsTo(target, part) && await ref.read(botChatProvider(widget.botId).notifier).send(text);

  Future<void> _pickModel(DsBot bot, BotActionScope scope) => pickBotModel(context, ref, bot, scope: scope);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(dsBotProvider);
    final team = status.team;
    final bot = team?.bot(widget.botId);
    final mobileUnavailable =
        status.availability == DsBotAvailability.missing || status.availability == DsBotAvailability.outdated;
    if (team == null || bot == null || mobileUnavailable) {
      return AppPage.list(
        title: 'Bot',
        children: [DsBotUnavailableMessage(status: status, goneIcon: AppIcons.bot, goneTitle: l10n.botsBotGone)],
      );
    }
    final feed = botChatProvider(widget.botId);
    // The transcript owns the live row. Its words only rebuild that row.
    ref.watch(
      feed.select((s) => (s.items, s.pending, s.loading, s.loadingEarlier, s.hasEarlier, s.error, s.streaming != null)),
    );
    final chat = ref.read(feed);
    final work = status.live.bots[bot.id];
    final ownTurn = work != null && work.roomId == null;
    final question = team.questionOf(bot);
    final view = team.viewOf(bot);
    final api = ref.read(dsBotProvider.notifier).api;
    final (String label, StatusTone tone) = switch (()) {
      _ when question != null || view != null => (l10n.commonWaitingAnswer, StatusTone.warn),
      _ when bot.waiting => (l10n.botsWaitingModel, StatusTone.warn),
      _ when work != null => (
        [
          workPhrase(work, activity: status.live.activity[bot.id]) ?? l10n.botsThinking,
          ?team.room(work.roomId)?.name,
        ].join(' · '),
        StatusTone.busy,
      ),
      _ => (bot.role.isEmpty ? (team.isMain(bot.id) ? l10n.botsMainBot : l10n.botsIdle) : bot.role, StatusTone.ok),
    };
    final rows = transcriptRows(chat.items, pending: chat.pending, streaming: ownTurn ? chat.streaming : null);
    final topInset = BotChatHeader.heightOf(context);
    final rooms = {for (final room in team.rooms) room.id: room.name};
    final readOnly = status.readOnly != null;
    final modelScope = BotActionScope(ref, botId: bot.id);
    final sendTarget = BotActionScope(ref, botId: bot.id);

    return BotChatFrame(
      header: BotChatHeader(
        face: BotAvatar(bot: bot, size: BotChatHeader.faceSize),
        title: bot.name,
        status: label,
        tone: tone,
        scrolledUnder: _scrolled,
        onDetails: () => Navigator.of(context).push(BotDetailsPage.route(bot.id)),
      ),
      body: chat.loading && chat.items.isEmpty
          ? Padding(
              padding: EdgeInsets.only(top: topInset),
              child: const QuietSpinner(),
            )
          : BotTranscript(
              rows: rows,
              topInset: topInset,
              scrolledUnder: _scrolled,
              hasEarlier: chat.hasEarlier,
              loadingEarlier: chat.loadingEarlier,
              onEarlier: () => ref.read(botChatProvider(widget.botId).notifier).loadEarlier(),
              empty: _Intro(bot: bot),
              rowBuilder: (context, row) => Padding(
                padding: rowPadding(row),
                child: switch (row) {
                  BotTimeRow(:final time) => BotTimeLine(time),
                  BotPendingRow(:final pending) => BotUserMessage(text: pending.text, pending: true),
                  BotStreamingRow() => Consumer(
                    builder: (context, ref, _) {
                      final text = ref.watch(feed.select((s) => s.streaming));
                      return text == null || text.isEmpty
                          ? const Align(alignment: Alignment.centerLeft, child: _Thinking())
                          : BotReplyText(text: text, streaming: true);
                    },
                  ),
                  BotTypingRow() => const SizedBox.shrink(),
                  BotItemRow(:final item) => switch (item.kind) {
                    DsBotItemKind.user => BotUserMessage(text: item.text, images: item.images),
                    DsBotItemKind.bot => _WithCards(
                      chat: chat,
                      item: item,
                      sessionId: bot.sessionId,
                      running: ownTurn,
                      onReply: readOnly ? null : (text) => _reply(sendTarget, bot.sessionId, text),
                      child: BotReplyText(text: item.text),
                    ),
                    DsBotItemKind.event => BotEventLine(
                      text: chatEventText(item, roomName: rooms[item.roomId]),
                      icon: AppIcons.swap,
                    ),
                    DsBotItemKind.answer => BotEventLine(text: l10n.botsAnsweredQuestion, icon: AppIcons.done),
                    DsBotItemKind.divider => BotEventLine(text: l10n.botsEarlierMessages, icon: AppIcons.history),
                    DsBotItemKind.unknown => const SizedBox.shrink(),
                  },
                },
              ),
            ),
      bottom: [
        if (bot.waiting && !readOnly)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BotModelCard(name: bot.name, onPick: () => _pickModel(bot, modelScope)),
          ),
        if ((question != null || view != null) && api != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BotPendingCard(
              key: ValueKey((
                status.host,
                status.hello?.boot,
                api,
                bot.id,
                bot.sessionId,
                question != null,
                question?.id ?? view?.id,
              )),
              api: api,
              origin: status,
              bot: bot,
              question: question,
              view: view,
            ),
          ),
        _OwnApprovals(sessionId: bot.sessionId),
        BotErrorSlot(
          error: chat.error,
          onDismiss: () => ref.read(botChatProvider(widget.botId).notifier).dismissError(),
        ),
        Composer(
          hardwareEnterSends: ref.watch(settingsProvider.select((s) => s.hardwareEnterSends)),
          controller: _input,
          focusNode: _focus,
          connected: api != null && !readOnly,
          running: ownTurn,
          onSend: () => _send(sendTarget, bot.sessionId),
          onStop: _stopGuard.action(botId: bot.id),
          placeholder: l10n.botsComposerHint(bot.name),
        ),
      ],
    );
  }
}

/// Picks [bot]'s model in the chat's model sheet and saves it.
Future<void> pickBotModel(BuildContext context, WidgetRef ref, DsBot bot, {BotActionScope? scope}) {
  final target = scope ?? BotActionScope(ref, botId: bot.id);
  if (!target.current(context, ref)) return Future.value();
  final hub = ref.read(dsBotProvider.notifier);
  final api = target.api;
  bool current() => target.current(context, ref);

  if (!current()) return Future.value();
  final messenger = ScaffoldMessenger.maybeOf(context);
  return showModelSheet(
    context,
    current: botModelSelection(bot),
    onSelected: (selection) async {
      // A modal can outlive a host switch, reconnect, or removal of this Bot.
      // Check before any write; never redirect an old choice through hub.api.
      if (!current()) return;
      try {
        await api!.updateBot(
          bot.id,
          model: '${selection.provider}/${selection.model}',
          // A model without levels clears the previous Bot override.
          // Omission means "keep" to DS Bot, not "use the default".
          effort: selection.reasoningEffort ?? '',
        );
        if (current()) await hub.refresh();
      } catch (error) {
        if (current()) messenger?.showSnackBar(SnackBar(content: Text(describeDsBotError(error))));
      }
    },
  );
}

/// A Bot's model as the model sheet names it.
ModelSelection? botModelSelection(DsBot bot) {
  final ref = bot.modelRef;
  if (ref == null) return null;
  final slash = ref.indexOf('/');
  if (slash <= 0) return null;
  return ModelSelection(
    provider: ref.substring(0, slash),
    model: ref.substring(slash + 1),
    reasoningEffort: bot.effort,
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: TypingIndicator(color: DshColors.of(context).textTertiary),
    ),
  );
}

/// The empty chat: the Bot's face, name and role.
class _Intro extends StatelessWidget {
  const _Intro({required this.bot});

  final DsBot bot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BotAvatar(bot: bot, size: 64),
        const SizedBox(height: 12),
        Text(bot.name, style: theme.textTheme.titleLarge),
        if (bot.role.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(bot.role, style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary)),
        ],
      ],
    );
  }
}

/// DSH's own approval requests in the Bot's chat (a member's in a group are
/// answered in the group's details).
class _OwnApprovals extends ConsumerStatefulWidget {
  const _OwnApprovals({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_OwnApprovals> createState() => _OwnApprovalsState();
}

class _OwnApprovalsState extends ConsumerState<_OwnApprovals> {
  StreamSubscription<HostEvent>? _sub;
  DshClient? _client;
  List<ApprovalRequest> _requests = const [];

  void _attach(DshClient? client) {
    if (identical(client, _client)) return;
    unawaited(_sub?.cancel());
    _client = client;
    _sub = client?.hostEvents.listen((_) => _read());
    _read();
  }

  void _read() {
    final client = _client;
    final next = [
      for (final event in client?.mux.pendingRequests ?? const <HostEvent>[])
        if (event is ApprovalRequestedEvent && event.request.sessionId == widget.sessionId) event.request,
    ];
    if (!mounted) return;
    if (next.length != _requests.length || !next.every((r) => _requests.any((o) => o.eventId == r.eventId))) {
      setState(() => _requests = next);
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _attach(ref.watch(activeConnectionProvider.select((c) => c.value?.client)));
    final client = _client;
    if (_requests.isEmpty || client == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final request in _requests)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ApprovalCard(
              key: ValueKey(request.eventId),
              request: request,
              onRespond: (request, decision) async {
                await client.respondApproval(request, decision);
                _read();
              },
            ),
          ),
      ],
    );
  }
}

/// A reply's dsh-ui cards, answered here as in a chat: whether one still can be comes from
/// what followed it in this Bot's transcript.
class _WithCards extends StatelessWidget {
  const _WithCards({
    required this.chat,
    required this.item,
    required this.sessionId,
    required this.running,
    required this.onReply,
    required this.child,
  });

  final BotChatState chat;
  final DsBotItem item;
  final String sessionId;
  final bool running;
  final DshUiSend? onReply;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final index = chat.items.indexOf(item);
    final state = index < 0 || (!item.text.contains('dsh-ui') && !item.text.contains('{'))
        ? DshUiState.expired
        : dshUiStateAfter(
            [
              for (final later in chat.items.skip(index + 1))
                if (later.kind == DsBotItemKind.user)
                  (user: true, text: later.text)
                else if (later.kind == DsBotItemKind.bot)
                  (user: false, text: later.text),
            ],
            running: running,
            pending: [for (final p in chat.pending) p.text],
          );
    return DshUiScope(
      sessionId: sessionId,
      messageId: item.id ?? '',
      state: state,
      onReply: onReply,
      onAskResend: onReply,
      child: child,
    );
  }
}
