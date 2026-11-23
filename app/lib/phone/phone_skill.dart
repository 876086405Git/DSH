// Values exchanged by skills.* and the two skill events on dsh/phone/events.
typedef SkillWireMap = Map<Object?, Object?>;

T _field<T>(SkillWireMap map, String key) {
  final value = map[key];
  if (value is T) return value;
  throw FormatException('Invalid skill field: $key');
}

List<T> _items<T>(SkillWireMap map, String key, T Function(Object?) parse) =>
    List.unmodifiable(_field<List<Object?>>(map, key).map(parse));

T _enum<T extends Enum>(SkillWireMap map, String key, List<T> values) =>
    values.asNameMap()[_field<String>(map, key)] ?? (throw FormatException('Invalid skill field: $key'));

enum PhoneSkillState { trial, active, suspended }

enum PhoneSkillSuspensionReason { manual, misses }

enum PhoneSkillSource { learned, written }

enum PhoneSkillDraftKind { newSkill, update }

enum PhoneSkillOutcome { ok, miss, unscored }

enum PhoneSkillChange { promoted, suspended }

enum PhoneSkillDiffOperation { added, removed, unchanged }

class PhoneSkillOrigin {
  const PhoneSkillOrigin(this.sessionId, this.taskId);
  final String sessionId;
  final int taskId;

  factory PhoneSkillOrigin.fromMap(SkillWireMap map) =>
      PhoneSkillOrigin(_field(map, 'sessionId'), _field(map, 'taskId'));
}

class PhoneSkillSections {
  const PhoneSkillSections({
    required this.entry,
    required this.steps,
    required this.pitfalls,
    required this.success,
    required this.handoff,
  });
  final String entry, steps, pitfalls, success, handoff;

  factory PhoneSkillSections.fromMap(SkillWireMap map) => PhoneSkillSections(
    entry: _field(map, 'entry'),
    steps: _field(map, 'steps'),
    pitfalls: _field(map, 'pitfalls'),
    success: _field(map, 'success'),
    handoff: _field(map, 'handoff'),
  );

  Map<String, String> toMap() => {
    'entry': entry,
    'steps': steps,
    'pitfalls': pitfalls,
    'success': success,
    'handoff': handoff,
  };
}

class PhoneSkill {
  PhoneSkill.fromMap(SkillWireMap map)
    : name = _field(map, 'name'),
      display = _field(map, 'display'),
      description = _field(map, 'description'),
      whenToUse = _field(map, 'whenToUse'),
      apps = _items(map, 'apps', (v) => v as String),
      source = _enum(map, 'source', PhoneSkillSource.values),
      state = _enum(map, 'state', PhoneSkillState.values),
      suspensionReason = map['suspensionReason'] == null
          ? null
          : _enum(map, 'suspensionReason', PhoneSkillSuspensionReason.values),
      uses = _field(map, 'uses'),
      updatedAt = _field(map, 'updatedAt'),
      recent = _items(
        map,
        'recent',
        (v) => switch (v) {
          'ok' => PhoneSkillOutcome.ok,
          'miss' => PhoneSkillOutcome.miss,
          'void' => PhoneSkillOutcome.unscored,
          _ => throw const FormatException('Invalid skill outcome'),
        },
      ),
      learnedFrom = map['learnedFrom'] == null ? null : PhoneSkillOrigin.fromMap(_field(map, 'learnedFrom')),
      body = map['body'] as String?,
      sections = map['sections'] == null ? null : PhoneSkillSections.fromMap(_field(map, 'sections')),
      history = map['history'] == null ? const [] : _items(map, 'history', (v) => v as int);

  final String name, display, description, whenToUse;
  final List<String> apps;
  final PhoneSkillSource source;
  final PhoneSkillState state;
  final PhoneSkillSuspensionReason? suspensionReason;
  final int uses, updatedAt;
  final List<PhoneSkillOutcome> recent;
  final PhoneSkillOrigin? learnedFrom;

  /// Present in the detail returned by skills.get and successful edits.
  final String? body;
  final PhoneSkillSections? sections;
  final List<int> history;
}

class PhoneSkillDiffLine {
  PhoneSkillDiffLine.fromMap(SkillWireMap map)
    : text = _field(map, 'text'),
      operation = switch (map['op']) {
        '+' => PhoneSkillDiffOperation.added,
        '-' => PhoneSkillDiffOperation.removed,
        ' ' => PhoneSkillDiffOperation.unchanged,
        _ => throw const FormatException('Invalid skill diff operation'),
      };
  final PhoneSkillDiffOperation operation;
  final String text;
}

class PhoneSkillDraft {
  PhoneSkillDraft.fromMap(SkillWireMap map)
    : id = _field(map, 'id'),
      name = _field(map, 'name'),
      display = _field(map, 'display'),
      description = _field(map, 'description'),
      whenToUse = _field(map, 'whenToUse'),
      apps = _items(map, 'apps', (v) => v as String),
      sections = PhoneSkillSections.fromMap(_field(map, 'sections')),
      body = _field(map, 'body'),
      createdAt = _field(map, 'createdAt'),
      from = PhoneSkillOrigin.fromMap(_field(map, 'from')),
      kind = switch (map['kind']) {
        'new' => PhoneSkillDraftKind.newSkill,
        'update' => PhoneSkillDraftKind.update,
        _ => throw const FormatException('Invalid skill draft kind'),
      },
      target = map['target'] as String?,
      baseFingerprint = map['baseFingerprint'] as String?,
      diff = map['diff'] == null ? const [] : _items(map, 'diff', (v) => PhoneSkillDiffLine.fromMap(v as SkillWireMap));
  final String id, name, display, description, whenToUse, body;
  final List<String> apps;
  final PhoneSkillSections sections;
  final int createdAt;
  final PhoneSkillOrigin from;
  final PhoneSkillDraftKind kind;
  final String? target, baseFingerprint;
  final List<PhoneSkillDiffLine> diff;
}

class PhoneLegacySkill {
  PhoneLegacySkill.fromMap(SkillWireMap map) : name = _field(map, 'name'), path = _field(map, 'path');
  final String name, path;
}

class PhoneSkillListing {
  PhoneSkillListing.fromMap(SkillWireMap map)
    : learn = _field(map, 'learn'),
      skills = _items(map, 'skills', (v) => PhoneSkill.fromMap(v as SkillWireMap)),
      drafts = _items(map, 'drafts', (v) => PhoneSkillDraft.fromMap(v as SkillWireMap)),
      legacy = _items(map, 'legacy', (v) => PhoneLegacySkill.fromMap(v as SkillWireMap)),
      archived = _items(map, 'archived', (v) => v as String);
  final bool learn;
  final List<PhoneSkill> skills;
  final List<PhoneSkillDraft> drafts;
  final List<PhoneLegacySkill> legacy;
  final List<String> archived;
}

sealed class PhoneSkillEvent {
  const PhoneSkillEvent();
}

final class PhoneSkillDraftEvent extends PhoneSkillEvent {
  PhoneSkillDraftEvent.fromMap(SkillWireMap map) : draft = PhoneSkillDraft.fromMap(_field(map, 'draft'));
  final PhoneSkillDraft draft;
}

final class PhoneSkillOutcomeEvent extends PhoneSkillEvent {
  PhoneSkillOutcomeEvent.fromMap(SkillWireMap map)
    : name = _field(map, 'name'),
      display = _field(map, 'display'),
      state = _enum(map, 'state', PhoneSkillState.values),
      change = _enum(map, 'change', PhoneSkillChange.values),
      from = PhoneSkillOrigin.fromMap(_field(map, 'from'));
  final String name, display;
  final PhoneSkillState state;
  final PhoneSkillChange change;
  final PhoneSkillOrigin from;
}

/// Domain failures are returned as {error, detail} by native. Transport failures use unavailable.
class PhoneSkillException implements Exception {
  const PhoneSkillException(this.code, this.detail);
  final String code, detail;
}
