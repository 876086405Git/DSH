// What the pet shows, as reduced from the app's signals by the mood reducer
// (pet_mood.dart). The chat page's pet layer and the out-of-app overlay
// (Kotlin, `dsh/pet_overlay`) both draw from this one value; the overlay
// never reduces anything itself. Product rules: `docs/design/pets.md`.
//
// State names are Clawd on Desk's (the keys of `states` in pack.json).

import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';

/// The pet's states, in Clawd on Desk's names.
enum PetStateName {
  idle,
  thinking,
  working,
  juggling,
  sweeping,
  notification,
  attention,
  error,
  carrying,
  sleeping,
  waking;

  /// Unknown names read as [idle].
  static PetStateName fromName(String? name) => values.asNameMap()[name] ?? idle;
}

/// The sizes in 宠物设置, by body height (docs/design/pets.md §2.10): three
/// presets, and [custom] at the height the person dragged to
/// ([PetPrefs.customHeight]). The name is the persisted value.
enum PetSize {
  small,
  medium,
  large,
  custom;

  /// The three with a height of their own.
  static const presets = [small, medium, large];

  /// 自定义's range, dp of body height: half to three times 标准.
  static const customMin = 15.0, customMax = 90.0;

  String get label => switch (this) {
    small => appL10n.stateSizeSmall,
    medium => appL10n.stateSizeStandard,
    large => appL10n.stateSizeLarge,
    custom => appL10n.stateSizeCustom,
  };

  /// Target height of the pet's body (its pack's `contentBox`), dp. The
  /// drawn size snaps to a whole number of device pixels per art pixel.
  /// [custom] has none of its own: [PetPrefs.bodyHeight] holds it.
  double get bodyHeight => switch (this) {
    small => 22,
    medium || custom => 30,
    large => 40,
  };

  static PetSize fromName(String? name) => values.asNameMap()[name] ?? medium;
}

/// What a bubble is about.
enum PetBubbleKind {
  done,
  failed,
  approval,
  question;

  /// The bubble's words.
  String get verb => switch (this) {
    done => appL10n.statePetDone,
    failed => appL10n.statePetFailed,
    approval => appL10n.commonWaitingApproval,
    question => appL10n.commonWaitingAnswer,
  };

  /// Waits on the person: stays up longer, outranks the rest.
  bool get waits => this == approval || this == question;

  /// How long it stays up.
  Duration get shownFor => switch (this) {
    done => const Duration(seconds: 4),
    failed => const Duration(seconds: 6),
    approval || question => const Duration(seconds: 8),
  };

  /// Which one wins when two meet: waiting requests, then failures, then done.
  int get rank => switch (this) {
    done => 0,
    failed => 1,
    approval || question => 2,
  };
}

/// A conversation on a host.
@immutable
class PetTarget {
  const PetTarget(this.host, this.sessionId);

  final HostRef host;
  final String sessionId;

  Map<String, Object?> toMap() => {'host': host.encode(), 'sessionId': sessionId};

  @override
  bool operator ==(Object other) => other is PetTarget && other.host == host && other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(host, sessionId);

  @override
  String toString() => 'PetTarget(${host.kind.name}:${host.id}/$sessionId)';
}

/// Titles longer than this are cut (docs/design/pets.md §2.6).
const petTitleMax = 12;

/// A request the floating pet's bubble shows and may answer (docs/design/
/// pets.md §2.7): the whole action or question as the alert masked it, and
/// how it can be answered there. The overlay answers only what it shows whole.
@immutable
class PetAsk {
  const PetAsk({
    required this.eventId,
    required this.text,
    this.token,
    this.approvable = false,
    this.choices = const [],
  });

  final String eventId;
  final int? token;

  /// An approval's whole action (「运行：git push」), or the question.
  final String text;

  /// 允许本次 / 拒绝 on the bubble: the exact call is known and shows whole.
  final bool approvable;

  /// A question's one-tap answers; empty: 「去回答」.
  final List<String> choices;

  Map<String, Object?> toMap(PetBubbleKind kind) => {
    'eventId': eventId,
    'token': token,
    'kind': kind.name,
    'text': text,
    'approvable': approvable,
    'choices': choices,
  };

  @override
  bool operator ==(Object other) =>
      other is PetAsk &&
      other.eventId == eventId &&
      other.token == token &&
      other.text == text &&
      other.approvable == approvable &&
      listEquals(other.choices, choices);

  @override
  int get hashCode => Object.hash(eventId, token, text, approvable, Object.hashAll(choices));
}

/// A short line over the pet's head: 「做完了」「标题 · 等你确认」
/// 「3 个对话做完了」. Never the conversation's text, with two exceptions on
/// the floating pet: a request it can answer ([ask]), and 问一句's own reply
/// ([preview]).
@immutable
class PetBubble {
  const PetBubble({
    required this.id,
    required this.kind,
    required this.target,
    required this.until,
    this.title,
    this.count = 1,
    this.ask,
    this.preview,
  });

  /// Unique per bubble: the same id pushed again is the same bubble.
  final String id;
  final PetBubbleKind kind;

  /// The conversation's title, already masked (`alertTitle`); null for none.
  final String? title;

  /// The conversation a tap opens (a merged bubble: the first one).
  final PetTarget target;

  /// Conversations merged into this bubble.
  final int count;

  /// Device clock: the bubble folds away then.
  final DateTime until;

  /// The request, to answer on the bubble; only for a single conversation.
  final PetAsk? ask;

  /// 问一句's reply, masked, on one line (the overlay shows two lines of it).
  final String? preview;

  /// The title as the bubble shows it (cut at [petTitleMax]); null when
  /// merged or untitled.
  String? get shortTitle {
    final t = title?.trim();
    if (count > 1 || t == null || t.isEmpty) return null;
    final chars = t.runes.toList();
    return chars.length <= petTitleMax ? t : '${String.fromCharCodes(chars.take(petTitleMax))}…';
  }

  /// What the bubble says after the title: 「做完了」, or 「3 个对话做完了」.
  String get verb => count > 1
      ? switch (kind) {
          PetBubbleKind.done => appL10n.statePetChatsDone(count),
          PetBubbleKind.failed => appL10n.statePetChatsFailed(count),
          PetBubbleKind.approval => appL10n.statePetChatsApproval(count),
          PetBubbleKind.question => appL10n.statePetChatsQuestion(count),
        }
      : kind.verb;

  /// The line on screen.
  String get text => switch (shortTitle) {
    final t? => '$t · $verb',
    null => verb,
  };

  /// Merged ([count] > 1), a bubble speaks for several conversations: no
  /// request and no reply of one of them goes with it.
  PetBubble copyWith({int? count, DateTime? until}) {
    final merged = (count ?? this.count) > 1;
    return PetBubble(
      id: id,
      kind: kind,
      title: title,
      target: target,
      count: count ?? this.count,
      until: until ?? this.until,
      ask: merged ? null : ask,
      preview: merged ? null : preview,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind.name,
    'text': text,
    'title': ?title,
    'count': count,
    'host': target.host.encode(),
    'sessionId': target.sessionId,
    'untilMs': until.millisecondsSinceEpoch,
    if (count == 1 && preview != null) 'detail': preview,
    if (count == 1 && ask != null) 'ask': ask!.toMap(kind),
  };

  @override
  bool operator ==(Object other) =>
      other is PetBubble &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.target == target &&
      other.count == count &&
      other.until == until &&
      other.ask == ask &&
      other.preview == preview;

  @override
  int get hashCode => Object.hash(id, kind, title, target, count, until, ask, preview);

  @override
  String toString() => 'PetBubble(${kind.name} "$text" → $target)';
}

/// A host the floating pet's 切换主机 offers: one that switches without a
/// question (本机, a pinned SSH or DSH Remote host).
@immutable
class PetHostChoice {
  const PetHostChoice(this.host, this.label, {this.current = false});

  final HostRef host;
  final String label;
  final bool current;

  Map<String, Object?> toMap() => {'ref': host.encode(), 'label': label, 'current': current};

  @override
  bool operator ==(Object other) =>
      other is PetHostChoice && other.host == host && other.label == label && other.current == current;

  @override
  int get hashCode => Object.hash(host, label, current);
}

/// Id of the 「不显示」 choice.
const noPetId = 'none';

/// What the pet shows right now. Equal values need no redraw and no push.
@immutable
class PetState {
  const PetState({
    this.state = PetStateName.idle,
    this.tier = 0,
    this.bubble,
    this.target,
    this.active = false,
    this.foreground = true,
    this.packId = noPetId,
    this.size = PetSize.medium,
    this.bodyHeight = 30,
    this.quiet = false,
    this.reduceMotion = false,
    this.canStop = false,
    this.hosts = const [],
  });

  final PetStateName state;

  /// 0: not tiered. working 1–3 (running top-level conversations on every
  /// host, capped at 3); juggling 1–2 (running subagents).
  final int tier;

  /// Null in quiet mode, or when there is nothing to say.
  final PetBubble? bubble;

  /// The most relevant conversation (docs/design/pets.md §2.7): one waiting
  /// on the person (the longest), else one that failed unseen, else one that
  /// finished unseen, else the most recently active running one, else the
  /// one last looked at.
  final PetTarget? target;

  /// Something runs, waits on the person, or a bubble is up.
  final bool active;

  /// The app is on screen (the overlay steps aside).
  final bool foreground;

  /// The chosen pack, or [noPetId].
  final String packId;
  final PetSize size;

  /// Body height, dp: [size]'s, or the 自定义 one.
  final double bodyHeight;

  /// 安静模式: moves only, no bubbles.
  final bool quiet;
  final bool reduceMotion;

  /// [target] runs on the host in use: the floating pet's 「停止当前任务」.
  final bool canStop;

  /// The floating pet's 切换主机, when there are two or more; else empty.
  final List<PetHostChoice> hosts;

  Map<String, Object?> toMap() => {
    'state': state.name,
    'tier': tier,
    if (bubble case final bubble?) 'bubble': bubble.toMap(),
    if (target case final target?) 'target': target.toMap(),
    'active': active,
    'foreground': foreground,
    'packId': packId,
    'size': size.name,
    if (size == PetSize.custom) 'bodyHeight': bodyHeight,
    'quiet': quiet,
    'reduceMotion': reduceMotion,
    'canStop': canStop,
    'hosts': [for (final h in hosts) h.toMap()],
  };

  @override
  bool operator ==(Object other) =>
      other is PetState &&
      other.state == state &&
      other.tier == tier &&
      other.bubble == bubble &&
      other.target == target &&
      other.active == active &&
      other.foreground == foreground &&
      other.packId == packId &&
      other.size == size &&
      other.bodyHeight == bodyHeight &&
      other.quiet == quiet &&
      other.reduceMotion == reduceMotion &&
      other.canStop == canStop &&
      listEquals(other.hosts, hosts);

  @override
  int get hashCode => Object.hash(
    state,
    tier,
    bubble,
    target,
    active,
    foreground,
    packId,
    size,
    bodyHeight,
    quiet,
    reduceMotion,
    canStop,
    Object.hashAll(hosts),
  );

  @override
  String toString() => 'PetState(${state.name}${tier > 0 ? '/$tier' : ''}${bubble == null ? '' : ' $bubble'})';
}
