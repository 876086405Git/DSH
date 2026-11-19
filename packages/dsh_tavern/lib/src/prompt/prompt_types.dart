import 'dart:convert';

/// Expansion is synchronous; a turn supplies its own mutable variable context.
typedef PromptExpansion = String Function(String text, Map<String, String> overrides);

/// Counts a serialized message using the same budget convention as ST.
abstract interface class PromptTokenCounter {
  String get name;
  bool get exact;
  int countMessage(Map<String, Object?> message);
  int countText(String text);
}

/// Per reply-002: approximately one CJK character per token, other text / 3.6.
/// Inject an exact counter when reproducing context-boundary decisions.
final class EstimatedTokenCounter implements PromptTokenCounter {
  const EstimatedTokenCounter();
  @override
  String get name => 'CJK 1 + other/3.6 estimate';
  @override
  bool get exact => false;
  @override
  int countText(String text) {
    var cjk = 0;
    var other = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x2E80 && rune <= 0x9FFF) ||
          (rune >= 0xF900 && rune <= 0xFAFF) ||
          (rune >= 0x20000 && rune <= 0x323AF) ||
          (rune >= 0xAC00 && rune <= 0xD7AF)) {
        cjk++;
      } else {
        // Count surrogate pairs twice; this errs on the conservative side for emoji.
        other += rune > 0xFFFF ? 2 : 1;
      }
    }
    return cjk + (other / 3.6).ceil();
  }

  @override
  int countMessage(Map<String, Object?> message) {
    if (message['content'] == '' &&
        (message['reasoning_content'] == null || message['reasoning_content'] == '') &&
        !message.containsKey('name') &&
        !message.containsKey('tool_calls')) {
      return 0;
    }
    final text = message.values.map((value) => value is String ? value : jsonEncode(value)).join('\n\n');
    // Estimated wrapper overhead, not a claim about the supplier's billed usage.
    return countText(text) + 2;
  }
}

/// Test, recording, or application adapter; it must declare its accuracy.
final class CallbackTokenCounter implements PromptTokenCounter {
  const CallbackTokenCounter({required this.name, required this.exact, required this.message, required this.text});
  @override
  final String name;
  @override
  final bool exact;
  final int Function(Map<String, Object?>) message;
  final int Function(String) text;
  @override
  int countMessage(Map<String, Object?> value) => message(value);
  @override
  int countText(String value) => text(value);
}

final class PromptSource {
  const PromptSource(this.kind, this.id, {this.label = '', this.details = const {}});
  final String kind;
  final String id;
  final String label;
  final Map<String, Object?> details;
  Map<String, Object?> toJson() => {'kind': kind, 'id': id, 'label': label, 'details': details};
}

/// Content and its origin before it is placed into a message.
final class PromptFragment {
  const PromptFragment(this.content, this.source, {this.role, this.trimOnOverflow = false, this.expandMacros = true});
  final String content;
  final PromptSource source;

  /// Explicit V3 role. Null inherits the enclosing prompt's existing role.
  final String? role;

  /// Remove this complete source entry before truncating history at capacity.
  /// Expanded results are retained; removal must not replay macro calls.
  final bool trimOnOverflow;

  /// Generated state/effect text is already resolved. Keep its literal values
  /// out of both preparation and later history macro expansion. Existing ST
  /// fragments retain their observable expansion phases by default.
  final bool expandMacros;
}

/// One ST worldInfoExamples item, in the original mixed before/after order.
/// Assembly expands each item before inserting its blocks at the chosen end.
final class PromptExample {
  const PromptExample({required this.fragment, required this.before});
  final PromptFragment fragment;
  final bool before;
}

final class PromptHistoryMessage {
  const PromptHistoryMessage({
    required this.id,
    required this.role,
    required this.content,
    this.name = '',
    this.hidden = false,
    this.isSystem = false,
    this.forceAvatar = false,
    this.expandMacros = true,
    this.toolCalls,
    this.toolCallId,
  });
  final String id;
  final String role;
  final String content;
  final String name;
  final bool hidden;
  final bool isSystem;
  final bool forceAvatar;

  /// Prepared request input shares its exact value with WI scanning.
  /// Stored history retains the existing later macro phase by default.
  final bool expandMacros;
  final List<Map<String, Object?>>? toolCalls;
  final String? toolCallId;
}

enum PromptPlacement { beforeMain, afterMain, inChat }

final class PromptInjection {
  const PromptInjection({
    required this.fragment,
    this.role = 'system',
    this.placement = PromptPlacement.inChat,
    this.depth = 4,
    this.order = 100,
    this.fragments = const [],
    this.v3Depth = false,
    this.sortKey,
    this.sourceOrder = 0,
  });
  final PromptFragment fragment;
  final String role;
  final PromptPlacement placement;
  final int depth;
  final int order;

  /// Preserve source sorting independently of the collision-free assembler id.
  /// Existing extensions continue to sort by their original source identifier.
  final String? sortKey;
  final int sourceOrder;

  /// A CCV3 depth/reverse_depth is bounded by the available history, not by
  /// ST's native 10000-message extension limit. Native injections retain it.
  final bool v3Depth;

  /// Optional complete, ordered pieces of this injection, including its base
  /// text. A nonempty list replaces [fragment]'s aggregate text while that
  /// fragment still supplies the extension identifier/anchor. Use this when
  /// an author's note or depth group mixes roles or optional and required WI.
  final List<PromptFragment> fragments;
}

final class PromptSegment {
  const PromptSegment({required this.id, required this.message, required this.sources, required this.tokens});
  final String id;
  final Map<String, Object?> message;
  final List<PromptSource> sources;
  final int tokens;
  Map<String, Object?> toJson() => {
    'id': id,
    'message': message,
    'sources': sources.map((source) => source.toJson()).toList(),
    'tokens': tokens,
  };
}

final class PromptExclusion {
  const PromptExclusion(this.id, this.reason, this.sources);
  final String id;
  final String reason;
  final List<PromptSource> sources;
  Map<String, Object?> toJson() => {'id': id, 'reason': reason, 'sources': sources.map((s) => s.toJson()).toList()};
}

/// Admission choices retained after history first exceeds its available budget.
/// The caller owns path/configuration invalidation and commits this value only
/// when the assembled request is admitted. Dynamic prompt text may still change.
final class PromptHistoryWindow {
  PromptHistoryWindow({
    required this.firstNodeId,
    Iterable<({String kind, String id, int block})> admittedExamples = const [],
    Iterable<({String kind, String id})> excludedOptionalSources = const [],
    Iterable<String> excludedInjections = const [],
  }) : admittedExamples = Set.unmodifiable(admittedExamples),
       excludedOptionalSources = Set.unmodifiable(excludedOptionalSources),
       excludedInjections = Set.unmodifiable(excludedInjections);

  final String firstNodeId;

  /// Block ordinals are local to their source, so another WI source appearing
  /// ahead of an admitted example does not change its identity.
  final Set<({String kind, String id, int block})> admittedExamples;
  final Set<({String kind, String id})> excludedOptionalSources;

  /// Opaque identities of depth pieces previously excluded by the budget.
  /// Keeping those choices prevents freed history space from refilling with
  /// an older injection in front of the retained history prefix.
  final Set<String> excludedInjections;

  Map<String, Object?> toJson() => {
    'firstNodeId': firstNodeId,
    'admittedExamples': [
      for (final example in admittedExamples) {'kind': example.kind, 'id': example.id, 'block': example.block},
    ],
    'excludedOptionalSources': [
      for (final source in excludedOptionalSources) {'kind': source.kind, 'id': source.id},
    ],
    'excludedInjections': excludedInjections.toList(),
  };
}

final class PromptAssembly {
  const PromptAssembly({
    required this.body,
    required this.beforePostProcessing,
    required this.afterPostProcessing,
    required this.excluded,
    required this.budget,
    required this.remainingBudget,
    required this.counterName,
    required this.exactTokenCounts,
    this.historyWindow,
  });
  final Map<String, Object?> body;
  final List<PromptSegment> beforePostProcessing;
  final List<PromptSegment> afterPostProcessing;
  final List<PromptExclusion> excluded;
  final int budget;
  final int remainingBudget;
  final String counterName;
  final bool exactTokenCounts;
  final PromptHistoryWindow? historyWindow;
  Map<String, Object?> toJson() => {
    'body': body,
    'beforePostProcessing': beforePostProcessing.map((s) => s.toJson()).toList(),
    'afterPostProcessing': afterPostProcessing.map((s) => s.toJson()).toList(),
    'excluded': excluded.map((s) => s.toJson()).toList(),
    'budget': budget,
    'remainingBudget': remainingBudget,
    'counter': counterName,
    'exactTokenCounts': exactTokenCounts,
    if (historyWindow != null) 'historyWindow': historyWindow!.toJson(),
  };
}

final class PromptBudgetExceeded implements Exception {
  const PromptBudgetExceeded(this.identifier, this.requiredTokens, this.remainingTokens);
  final String identifier;
  final int requiredTokens;
  final int remainingTokens;
  @override
  String toString() => 'Mandatory prompt $identifier needs $requiredTokens tokens; $remainingTokens remain';
}
