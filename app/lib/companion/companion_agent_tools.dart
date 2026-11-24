import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import 'companion_light.dart';
import 'companion_memory.dart';

typedef CompanionAgentMemoryCommit = void Function({
  required CompanionMemoryOwner memory,
  required String sourceId,
  required int beforeRevision,
  required int revision,
});

typedef CompanionAgentMaintenanceCommit = void Function({
  required CompanionMemoryOwner memory,
  required String turnId,
  required int beforeRevision,
  required int revision,
});

/// These rows were assembled by the store for this model response. User text,
/// model fields and unrelated cards in the same archive confer no provenance.
bool _noticeCards(List rows) =>
    rows.any((row) => row is Map && row['source'] is Map && row['source']['kind'] == 'notice');

bool companionSelectionHasNotice(MemorySelection selection) =>
    selection.ids.isNotEmpty && _noticeCards((jsonDecode(selection.block) as Map)['items'] as List);

/// The original SQLite source owns this turn and its durable three-card budget.
/// A model HTTP continuation does not create another turn or another allowance.
class CompanionAgentMemoryTools {
  CompanionAgentMemoryTools({
    required this.memory,
    required MemoryRow source,
    required this._isCurrent,
    required this._onCommitted,
    required this.forgottenNotice,
    this.semanticRecall,
  }) : sourceId = source['id']! as String,
       _onMaintenanceCommitted = null {
    final turn = memory.store.beginAgentTurn(
      messageId: source['id']! as String,
      expectedSourceRev: source['source_rev']! as int,
      shownCardRevisions: const {},
    );
    turnId = turn['id']! as String;
    _knownControlRevision = turn['control_revision']! as int;
    _closed = turn['closed'] != 0;
    _originKind = 'chat';
    _characterId = turn['character_id'] as String?;
  }

  CompanionAgentMemoryTools.maintenance({
    required this.memory,
    required MemoryRow turn,
    required this._isCurrent,
    required this._onMaintenanceCommitted,
    required this.forgottenNotice,
    this.semanticRecall,
  }) : sourceId = null,
       _onCommitted = null {
    if (!const ['extract', 'organize'].contains(turn['origin_kind'])) {
      throw ArgumentError('A maintenance adapter needs an actual maintenance turn');
    }
    turnId = turn['id']! as String;
    _knownControlRevision = turn['control_revision']! as int;
    _closed = turn['closed'] != 0;
    _originKind = turn['origin_kind'] as String;
    _characterId = turn['character_id'] as String?;
  }

  final CompanionMemoryOwner memory;
  final String? sourceId;
  final String forgottenNotice;
  final Future<List<String>?> Function(String query)? semanticRecall;
  final bool Function() _isCurrent;
  final CompanionAgentMemoryCommit? _onCommitted;
  final CompanionAgentMaintenanceCommit? _onMaintenanceCommitted;
  late final String turnId;
  late final String _originKind;
  late final String? _characterId;
  late int _knownControlRevision;
  bool _closed = false;

  bool get isCurrent =>
      !_closed &&
      _isCurrent() &&
      memory.store.archive['control_revision'] == _knownControlRevision &&
      memory.store.isAgentTurnCurrent(turnId);

  /// The caller supplies exactly the cards placed in its current model input.
  void grantCards(List<MemoryRow> cards) {
    if (!isCurrent) return;
    memory.store.grantAgentCards(
      turnId: turnId,
      cardRevisions: {for (final card in cards) card['id']! as String: card['row_rev']! as int},
    );
  }

  /// Wire this to the Agent's actual onSelected callback, including each new
  /// selection after one of this turn's own control commits.
  void grantSelection(MemorySelection selection) {
    if (!isCurrent || selection.controlRevision != _knownControlRevision) return;
    final selected = selection.ids.toSet();
    final revisions = memory.store.cardRevisions(selected);
    if (revisions.length != selected.length) {
      throw const DshRemoteException('companion/conflict', 'Selected memory changed', {'status': 409});
    }
    memory.store.grantAgentCards(turnId: turnId, cardRevisions: revisions);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (sourceId == null) {
      memory.store.finishAgentMaintenance(turnId: turnId, complete: false);
    } else {
      memory.store.closeAgentTurn(turnId);
    }
  }

  static List<CompanionAgentTool> definitionsFor({required String originKind, required String? characterId}) => [
    for (final definition in originKind == 'chat' ? definitions : _maintenanceDefinitions)
      if ((definition.name != 'diary' || originKind == 'organize') &&
          (definition.name != 'impression' || characterId != null) &&
          (definition.name != 'relationship' || (originKind != 'chat' && characterId != null)))
        definition,
  ];

  // Maintenance states shared source/reference/time rules once in its system
  // prompt. Keep the same tools and validation schema, without repeating those
  // annotations inside every nested write and group schema on every request.
  static final _maintenanceDefinitions = <CompanionAgentTool>[
    for (final definition in definitions)
      CompanionAgentTool(
        name: definition.name,
        description: _maintenanceDescriptions[definition.name]!,
        inputSchema: _maintenanceSchema(definition.inputSchema),
      ),
  ];

  static Map<String, Object?> _maintenanceSchema(Map<String, Object?> schema) => {
    for (final entry in schema.entries)
      if (entry.key != 'description' || entry.value is! String) entry.key: _maintenanceSchemaValue(entry.value),
  };

  static Object? _maintenanceSchemaValue(Object? value) {
    if (value is Map<String, Object?>) return _maintenanceSchema(value);
    if (value is List) return [for (final item in value) _maintenanceSchemaValue(item)];
    return value;
  }

  static const _maintenanceDescriptions = <String, String>{
    'remember':
        'Save or update a fact, preference or episode. about_you is shared; our_story belongs to this character.',
    'forget': 'Forget a card or complete changes group, preserving independent clauses. Maintenance cannot erase original chat or create a confirmation request; deleteChat does not change that. Report only the actual card changes.',
    'revise': 'Correct a card or complete changes group. Keep its ID and preserve independent clauses.',
    'related': 'Read and grant same-source candidates and required effects for a card; without card, return only stale cleanup IDs.',
    'merge': 'Merge proven duplicate facts or people into card, preserving proofs and consumed followups. Include required dependency updates.',
    'person': 'Save or update a shared person profile with actual names and aliases. Supply card when updating.',
    'diary': 'Write this completed-day diary from actual user sources. Supply its existing card to update; older diaries use revise or forget.',
    'impression': 'Update this character\'s concise impression, supplying its existing card and only this domain\'s sources or references.',
    'relationship': 'Classify real questions, confiding or answers using supplied original source/display IDs. Never invent events or scores.',
    'quiet': 'Set a supplied card topic to less or never proactive, or restore normal when the user allows it again. The card path requires all affected cards to be supplied and fit the shared budget. Alternatively, restore one quiet control just returned by recall using topic and mode normal, without card. This topic path leaves its cards unchanged and grants no card IDs. After each restoration, use a new recall call to read the next control. Restoring does not reopen old followups.',
    'cancel': 'Cancel a supplied memory plan and retire its followup; not a reminder or computer task.',
    'postpone':
        'Postpone a memory plan without a new time and retire its followup. Use ask_later when the time is known.',
    'ask_later': 'Schedule a real invitation\'s followup on a supplied card at whenMs (UTC milliseconds), within presentation limits.',
    'recall': 'Read bounded current eligible memories and at most one matching quiet control. Only returned card IDs are granted. A returned control may be restored with quiet(topic, normal); use a new recall call after restoring it to read another.',
  };

  List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
  get bindings => [
    for (final definition in definitionsFor(originKind: _originKind, characterId: _characterId))
      (definition: definition, execute: execute),
  ];

  Future<CompanionAgentToolResult> execute(CompanionAgentToolCall call) async {
    if (!isCurrent) return _failure('turn_not_current');
    List<String>? rankedRecallIds;
    final rank = semanticRecall;
    final query = call.input['query'];
    if (call.name == 'recall' && rank != null && query is String) {
      try {
        rankedRecallIds = await rank(query);
      } on Object {
        return _failure('recall_unavailable');
      }
    }
    // A ranker may await a local model. The original turn is checked again
    // before Store reads/grants actual current IDs; rank is never permission.
    return _execute(call, rankedRecallIds: rankedRecallIds);
  }

  CompanionAgentToolResult _execute(CompanionAgentToolCall call, {List<String>? rankedRecallIds}) {
    if (!isCurrent) return _failure('turn_not_current');
    final CompanionAgentMemoryResult receipt;
    try {
      // No await separates the live check, transaction, acknowledgement and
      // changed notification. An external control never becomes our own commit.
      receipt = memory.store.applyAgentMemoryTool(
        turnId: turnId,
        callId: call.id,
        toolName: call.name,
        input: call.input,
        rankedRecallIds: rankedRecallIds,
      );
    } on DshRemoteException catch (error) {
      return _failure(error.code);
    } on ArgumentError {
      return _failure('invalid_arguments');
    }
    if (!receipt.applied) return _failure(receipt.code ?? 'not_applied');
    if (!receipt.replayed && receipt.controlRevision != receipt.beforeControlRevision) {
      try {
        if (sourceId case final id?) {
          _onCommitted!(
            memory: memory,
            sourceId: id,
            beforeRevision: receipt.beforeControlRevision,
            revision: receipt.controlRevision,
          );
        } else {
          _onMaintenanceCommitted!(
            memory: memory,
            turnId: turnId,
            beforeRevision: receipt.beforeControlRevision,
            revision: receipt.controlRevision,
          );
        }
        _knownControlRevision = receipt.controlRevision;
      } finally {
        // The commit is real even if a caller rejects its presentation context.
        memory.changed();
      }
    }
    final result = <String, Object?>{
      'applied': true,
      'replayed': receipt.replayed,
      'changedCardIds': receipt.changedCardIds,
      'currentCardRevisions': receipt.currentCardRevisions,
      'targetId': receipt.targetId,
    };
    var externalNoticeContent = false;
    if (receipt.pendingRawEraseId case final id?) result['pendingRawEraseId'] = id;
    if (receipt.rawEraseState case final state?) {
      result['rawEraseState'] = state;
      result['rawEraseMessage'] = switch (state) {
        'pending' =>
          'The card changes are committed. Original chat remains and needs the owner\'s separate confirmation.',
        'maintenance' =>
          'The card changes are committed. Maintenance cannot erase original chat or request confirmation.',
        'no_originals' => 'The card changes are committed. There are no original chat messages to confirm erasing.',
        'confirmed' => 'The owner separately confirmed the original chat erasure. This replay performs no new erasure.',
        'declined' => 'The owner kept the original chat. This request cannot erase it.',
        'expired' => 'The confirmation expired. This request did not erase the original chat.',
        'invalidated' => 'The confirmation is no longer valid. This request did not erase the original chat.',
        _ => 'No live confirmation is available for this recorded request. Do not claim that original chat was erased.',
      };
    }
    if (call.name == 'recall') {
      final selection = receipt.recallSelection;
      if (selection == null) return _failure('recall_not_current');
      final block = jsonDecode(selection.block) as Map;
      result['selection'] = block;
      externalNoticeContent = _noticeCards(block['items'] as List);
      if (receipt.recalledControl case final control?) result['control'] = control;
    }
    if (call.name == 'related') {
      if (receipt.relatedCards == null) return _failure('related_not_current');
      result['cards'] = receipt.relatedCards;
      externalNoticeContent = _noticeCards(receipt.relatedCards!);
    }
    return CompanionAgentToolResult(
      content: jsonEncode(result),
      externalNoticeContent: externalNoticeContent,
      notice: receipt.code == 'forgotten' && !receipt.replayed ? forgottenNotice : null,
    );
  }

  static CompanionAgentToolResult _failure(String code) => CompanionAgentToolResult(
    // The provider does not interpret is_error. The body must say it failed.
    content: jsonEncode({
      'applied': false,
      'code': code,
      'message': 'This request was not applied. Continue the conversation.',
    }),
    isError: true,
  );

  static const _card = {
    'type': 'string',
    'description': 'An exact card ID supplied in this turn or a successful recall.',
  };
  static const _text = {'type': 'string', 'minLength': 1};
  static const _source = {
    'type': 'string',
    'description': 'For maintenance, one exact source ID in this context. A chat tool already owns its user source.',
  };
  static const _writeProperties = {
    'card': _card,
    'text': _text,
    'source': _source,
    'sources': {'type': 'array', 'items': _source},
    'references': {
      'type': 'array',
      'items': _card,
      'description': 'Supplied cards on which this wording depends. Revisions are captured by Store, not invented.',
    },
    'keywords': {'type': 'array', 'items': _text},
    'aliases': {'type': 'array', 'items': _text},
    'event_time': {
      'type': 'object',
      'description': 'Copy first-source wording. Use its said_at_utc + offset_minutes, not edit/processing time. Unknown date is null; omit without evidence.',
      'properties': {
        'local_date': {
          'type': ['string', 'null'],
          'pattern': r'^\d{4}-\d{2}-\d{2}$',
        },
        'precision': {
          'type': 'string',
          'enum': ['day', 'part_of_day', 'clock', 'unspecified'],
        },
        'wording': _text,
      },
      'required': ['local_date', 'precision', 'wording'],
      'additionalProperties': false,
    },
  };
  static final _memoryNames = definitions.map((tool) => tool.name).toSet();

  // A new memory the person asks for right after a notice («记一下») is theirs;
  // only rewriting existing cards stays closed for the rest of that turn.
  static bool allowedAfterNotice(String name) =>
      !_memoryNames.contains(name) || const {'recall', 'related', 'forget', 'remember'}.contains(name);

  static bool pureDeletion(Map<String, Object?> input) {
    if (input.containsKey('card') && input['card'] is! String) return false;
    if (input.keys.any((key) => key != 'card' && key != 'changes')) return false;
    if (!input.containsKey('changes')) return input['card'] is String;
    final changes = input['changes'];
    return changes is List &&
        changes.isNotEmpty &&
        changes.every(
          (change) => change is Map && change.length == 2 && change['card'] is String && change['forget'] == true,
        );
  }

  static const noticeForget = CompanionAgentTool(
    name: 'forget',
    description:
        'Delete a supplied card or an explicit group of deletions. Any replacement wording needs a separate user turn.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'card': _card,
        'changes': {
          'type': 'array',
          'minItems': 1,
          'items': {
            'type': 'object',
            'properties': {
              'card': _card,
              'forget': {
                'type': 'boolean',
                'enum': [true],
              },
            },
            'required': ['card', 'forget'],
            'additionalProperties': false,
          },
        },
      },
      'anyOf': [
        {
          'required': ['card'],
        },
        {
          'required': ['changes'],
        },
      ],
      'additionalProperties': false,
    },
  );

  static const _change = {
    'type': 'object',
    'properties': {
      ..._writeProperties,
      'forget': {'type': 'boolean'},
    },
    'required': ['card'],
    'anyOf': [
      {
        'required': ['text'],
      },
      {
        'required': ['forget'],
      },
    ],
    'additionalProperties': false,
  };
  static const definitions = <CompanionAgentTool>[
    CompanionAgentTool(
      name: 'remember',
      description: 'Save a concise fact, preference or episode. about_you is shared; our_story is private to the captured character. Maintenance must use actual supplied source IDs or reference IDs. At most three distinct entries change in one turn (one parent across maintenance roles).',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._writeProperties,
          'collection': {
            'type': 'string',
            'enum': ['about_you', 'our_story'],
          },
          'kind': {
            'type': 'string',
            'enum': ['fact', 'preference', 'episode'],
          },
        },
        'required': ['text'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'forget',
      description: 'First use related to inspect same-source candidates: sharing a source does not mean the same fact. Forget the intended entries atomically; changes must explicitly include all true literal/reference dependencies and preserve independent facts by nonempty rewrites. To request erasing original chat too, set deleteChat=true and supply top-level card as the single original-source target, also forgotten in changes if present. This only prepares a separate owner confirmation: original chat remains until the person confirms through the app. Other changes are not additional original-source targets. All affected entries must be granted and fit the shared budget. Report the actual card changes and pending confirmation; never claim raw erasure from the model request alone.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'deleteChat': {'type': 'boolean', 'default': false},
          'changes': {'type': 'array', 'minItems': 1, 'items': _change},
        },
        'anyOf': [
          {
            'required': ['card'],
          },
          {
            'required': ['changes'],
          },
        ],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'revise',
      description: 'Correct a supplied entry or an entire explicit changes group in one transaction. Inspect related candidates before changing a shared original. Preserve independent clauses in composite cards. References within this group bind to planned final revisions. A later correction uses the same ID and its new revision.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._writeProperties,
          'changes': {'type': 'array', 'minItems': 1, 'items': _change},
        },
        'anyOf': [
          {
            'required': ['card', 'text'],
          },
          {
            'required': ['changes'],
          },
        ],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'related',
      description: 'Read and grant actual same-source candidates and required literal/reference effects for a supplied card. Decide meaning from their text; do not equate a shared proof with the same fact. With no card, return only stale cleanup IDs without obsolete text.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'merge',
      description: 'Merge entries you have determined describe the same fact/person. Preserve original AND/OR proofs, aliases and followup consumption. Keep card as target; from are supplied IDs. Include retained dependency rewrites in updates. Never merge merely because a source or alias is shared.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'from': {'type': 'array', 'minItems': 1, 'items': _card},
          'text': _text,
          'keywords': {'type': 'array', 'items': _text},
          'updates': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': _writeProperties,
              'required': ['card', 'text'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['card', 'from'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'person',
      description: 'Create or update a shared profile of a real person using the supplied sources. Record known names/relationships/recent facts in text and actual aliases separately. Choose an existing supplied card when updating; use merge only when the people are actually the same.',
      inputSchema: {
        'type': 'object',
        'properties': _writeProperties,
        'required': ['text', 'aliases'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'diary',
      description: 'Write a short shared summary for this actual completed-day maintenance claim. Require at least one selected original user message from this exact completed day; shared references may only supplement it. Do not claim complete coverage. The day and timezone come from the claim, not tool arguments. Supply the existing diary for this day to update it; use generic revise/forget for a justified correction of an older diary while preserving its date and evidence.',
      inputSchema: {
        'type': 'object',
        'properties': _writeProperties,
        'required': ['text'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'impression',
      description: 'Update a few concise sentences about your relationship with this captured character. Use shared/current-character references and real supplied sources. Supply the existing impression ID when one is present; never use another character’s private material.',
      inputSchema: {
        'type': 'object',
        'properties': _writeProperties,
        'required': ['text'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'relationship',
      description: 'Classify an actual shown assistant question or a real user confiding/answer event in this maintenance context. Use supplied source and presentation IDs; no inferred display, invented time, or score. The Store rejects already settled days and deduplicates original sources.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'enum': ['question', 'confiding', 'answered_question', 'answered_followup'],
          },
          'source': _source,
          'presentation': {'type': 'string', 'description': 'An exact actual-display ticket in this context.'},
        },
        'required': ['kind'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'quiet',
      description: 'Mention the topic of this supplied card less, or never proactively; restore normal when the user allows it again, clearing its saved quiet anchors. The card path requires all affected topic cards to be supplied and fit the turn budget. Alternatively, restore one quiet control just returned by recall using topic and mode normal, without card. This topic path leaves its cards unchanged and grants no card IDs. After each restoration use a new recall call to read the next control. Restoring does not reopen old followups.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'topic': {'type': 'string', 'description': 'A quiet control topic_id just returned by recall.'},
          'mode': {
            'type': 'string',
            'enum': ['less', 'never', 'normal'],
          },
        },
        'required': ['mode'],
        'oneOf': [
          {
            'required': ['card'],
            'not': {
              'required': ['topic'],
            },
          },
          {
            'required': ['topic'],
            'not': {
              'required': ['card'],
            },
            'properties': {
              'mode': {
                'enum': ['normal'],
              },
            },
          },
        ],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'cancel',
      description: 'Mark a supplied memory plan cancelled and retire its followup. This does not cancel a reminder or a computer task.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'required': ['card'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'postpone',
      description: 'Mark a supplied memory plan postponed with no new time yet and retire its current followup. Use ask_later instead when a new time is known.',
      inputSchema: {
        'type': 'object',
        'properties': {'card': _card},
        'required': ['card'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'ask_later',
      description: 'Arrange a real followup opportunity about a supplied card at the chosen UTC epoch millisecond time. Existing presentation limits still apply.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'card': _card,
          'source': _source,
          'whenMs': {'type': 'integer', 'minimum': 0},
        },
        'required': ['card', 'whenMs'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'recall',
      description: 'Search the current eligible memory cards using the existing bounded selector. Only returned card IDs become available to this turn. Also read at most one matching quiet control, returned separately as control. Restore it with quiet(topic, normal), then use a new recall call to read another; replaying an old call does not grant the next control.',
      inputSchema: {
        'type': 'object',
        'properties': {'query': _text},
        'required': ['query'],
        'additionalProperties': false,
      },
    ),
  ];
}
