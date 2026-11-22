/// Schema-driven settings forms (`settings/describe` with each namespace's
/// schemastery schema, `settings/mutate`) and the read-only plugin inventory
/// (`pluginInventory/list`).
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-settings`,
/// `dsh-api-settings-controller`, `dsh-config-editor`,
/// `dsh-host-plugin-inventory`, `@deepseek-ai/schemastery`) and a throwaway
/// `dsh web`:
/// * a namespace is one Loader entry (`entry.options.id`, the bundle row id);
///   its `schema` is `schema.toJSON()` — `{uid, refs: {uid: node}}` where a
///   node's `dict` / `list` / `inner` / `sKey` hold uids;
/// * `value` is the resolved config, `base` the composition beneath the
///   profile (defaults resolved), `user` the profile's own override;
/// * a home patch or command-line overlay sits above the profile: then
///   `value` differs from what `base` + `user` give, and every write to that
///   namespace is refused (`settings/rejected`, "overridden by a home patch");
/// * `unset` drops the field from the user layer; a write that leaves the user
///   layer equal to `base` removes it entirely; the revision only moves when
///   the stored entry changes;
/// * `role('secret')` fields never come back: [SettingsNamespaceView.secrets]
///   says which slots hold a value. A sibling `role('credential-ref')` field
///   names the credential the secret is read from instead.
library;

import 'dart:collection';

import 'background_session_read.dart';
import 'features_api.dart';
import 'json.dart';
import 'plugins_api.dart';
import 'session_api.dart';

// -----------------------------------------------------------------------------
// Schemastery
// -----------------------------------------------------------------------------

/// `meta` of one schemastery node: UI and validation hints.
class SchemaMeta {
  const SchemaMeta({
    this.defaultValue,
    this.hasDefault = false,
    this.required = false,
    this.hidden = false,
    this.disabled = false,
    this.collapse = false,
    this.loose = false,
    this.volatile = false,
    this.role,
    this.extra,
    this.title,
    this.description,
    this.comment,
    this.link,
    this.pattern,
    this.patternFlags,
    this.min,
    this.max,
    this.step,
    this.badges = const [],
  });

  factory SchemaMeta.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final pattern = asMap(map['pattern']);
    return SchemaMeta(
      defaultValue: map['default'],
      hasDefault: map.containsKey('default'),
      required: map['required'] == true,
      hidden: map['hidden'] == true,
      disabled: map['disabled'] == true,
      collapse: map['collapse'] == true,
      loose: map['loose'] == true,
      volatile: map['volatile'] == true,
      role: asString(map['role']),
      extra: map['extra'],
      title: LocalizedText.fromJson(map['title']),
      description: LocalizedText.fromJson(map['description']),
      comment: asString(map['comment']),
      link: asString(map['link']),
      pattern: asString(pattern?['source']),
      patternFlags: asString(pattern?['flags']),
      min: asNum(map['min']),
      max: asNum(map['max']),
      step: asNum(map['step']),
      badges: [for (final b in asListOrEmpty(map['badges'])) ?asString(asMap(b)?['text'])],
    );
  }

  /// `.default(v)`; objects and arrays get `{}` / `[]` implicitly.
  final Object? defaultValue;
  final bool hasDefault;
  final bool required;
  final bool hidden;
  final bool disabled;

  /// Request initially collapsed rendering of a nested form group.
  final bool collapse;

  /// Invalid input falls back to the default instead of failing.
  final bool loose;

  /// `.volatile()`: the field (and everything under it) takes effect without
  /// remounting the plugin. `settings/describe` strips it, since every field
  /// it serves is live; a complete schema keeps it on the live nodes.
  final bool volatile;

  /// Renderer role: `secret`, `credential-ref`, `slider`, `textarea`, ….
  final String? role;
  final Object? extra;

  /// A name the schema gives itself (`meta.title`; the dsh-go bridge keeps
  /// it). Rare: a plugin's Config usually only has a description.
  final LocalizedText? title;
  final LocalizedText? description;
  final String? comment;
  final String? link;

  /// Regular expression a string must match (JavaScript syntax).
  final String? pattern;
  final String? patternFlags;

  /// Inclusive bounds of a number, or of a string's / collection's length.
  final num? min;
  final num? max;

  /// A number must be `min + k·step`.
  final num? step;

  /// `deprecated`, `experimental`.
  final List<String> badges;
}

/// One node of a schemastery schema, children linked (cycles possible for
/// `lazy` schemas: walk with a depth limit).
class SchemaNode {
  SchemaNode._(this.type, this.meta, {this.value, this.hasValue = false, this.bits = const {}});

  static Map<String, int> _readBits(Object? raw) => Map.unmodifiable({
    for (final entry in asMapOrEmpty(raw).entries)
      if (entry.value case final num mask when mask.isFinite) entry.key: mask.toInt().toSigned(32),
  });

  /// A node no reader understands (missing ref, malformed JSON).
  factory SchemaNode.unknown() => SchemaNode._('unknown', const SchemaMeta());

  /// Reads `schema.toJSON()`: the `{uid, refs}` envelope, or one inline node.
  factory SchemaNode.fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return SchemaNode.unknown();
    final refs = asMap(map['refs']);
    if (refs != null) {
      final nodes = <String, SchemaNode>{};
      for (final MapEntry(:key, :value) in refs.entries) {
        final raw = asMapOrEmpty(value);
        nodes[key] = SchemaNode._(
          asString(raw['type']) ?? 'unknown',
          SchemaMeta.fromJson(raw['meta']),
          value: raw['value'],
          hasValue: raw.containsKey('value'),
          bits: _readBits(raw['bits']),
        );
      }
      SchemaNode? ref(Object? uid) => uid == null ? null : nodes['$uid'];
      for (final MapEntry(:key, :value) in refs.entries) {
        final raw = asMapOrEmpty(value);
        final node = nodes[key]!;
        if (asMap(raw['dict']) case final dict?) {
          for (final MapEntry(key: name, value: uid) in dict.entries) {
            node._dict[name] = ref(uid) ?? SchemaNode.unknown();
          }
        }
        for (final uid in asListOrEmpty(raw['list'])) {
          node._list.add(ref(uid) ?? SchemaNode.unknown());
        }
        node._inner = ref(raw['inner']);
        node._sKey = ref(raw['sKey']);
      }
      return ref(map['uid']) ?? SchemaNode.unknown();
    }
    return SchemaNode._inline(map);
  }

  factory SchemaNode._inline(Map<String, Object?> raw) {
    final node = SchemaNode._(
      asString(raw['type']) ?? 'unknown',
      SchemaMeta.fromJson(raw['meta']),
      value: raw['value'],
      hasValue: raw.containsKey('value'),
      bits: _readBits(raw['bits']),
    );
    SchemaNode child(Object? json) => asMap(json) == null ? SchemaNode.unknown() : SchemaNode._inline(asMap(json)!);
    if (asMap(raw['dict']) case final dict?) {
      for (final MapEntry(:key, :value) in dict.entries) {
        node._dict[key] = child(value);
      }
    }
    for (final item in asListOrEmpty(raw['list'])) {
      node._list.add(child(item));
    }
    if (raw['inner'] != null) node._inner = child(raw['inner']);
    if (raw['sKey'] != null) node._sKey = child(raw['sKey']);
    return node;
  }

  /// `object`, `dict`, `array`, `tuple`, `union`, `intersect`, `const`,
  /// `string`, `number`, `boolean`, `transform`, `lazy`, `any`, `never`, ….
  final String type;
  final SchemaMeta meta;

  /// The constant of a `const` node.
  final Object? value;
  final bool hasValue;

  /// Named bit masks declared by Schema.bitset(); JavaScript bitwise values
  /// are signed 32-bit integers, including combined masks.
  final Map<String, int> bits;

  final Map<String, SchemaNode> _dict = {};
  final List<SchemaNode> _list = [];
  SchemaNode? _inner;
  SchemaNode? _sKey;

  /// Properties of an `object` (declaration order).
  Map<String, SchemaNode> get dict => UnmodifiableMapView(_dict);

  /// Members of a `union`, `intersect` or `tuple`.
  List<SchemaNode> get list => UnmodifiableListView(_list);

  /// Item of an `array` / `dict`; wrapped schema of `transform` / `lazy`.
  SchemaNode? get inner => _inner;

  /// Key schema of a `dict`.
  SchemaNode? get sKey => _sKey;

  /// `transform` and `lazy` resolve to what they wrap (meta of the wrapper
  /// kept where the wrapped node has none).
  SchemaNode get effective {
    var node = this;
    for (var i = 0; i < 8 && (node.type == 'transform' || node.type == 'lazy') && node._inner != null; i++) {
      node = node._inner!;
    }
    return node;
  }

  bool get isNullConst => type == 'const' && value == null;

  bool get isSecret => meta.role == 'secret';

  bool get isCredentialRef => meta.role == 'credential-ref';

  /// Members of a union without the `null` constant (an optional enum's
  /// "nothing").
  List<SchemaNode> get members => [
    for (final m in _list)
      if (!m.effective.isNullConst) m.effective,
  ];

  /// A union admits `null` explicitly.
  bool get nullable => type == 'union' && _list.any((m) => m.effective.isNullConst);

  /// The constants of an enum-like union (`union(['a', 'b'])`), or of a lone
  /// `const`; null when any member is not a constant.
  List<Object?>? get enumValues {
    final node = effective;
    if (node.type == 'const') return [node.value];
    if (node.type != 'union') return null;
    final members = node.members;
    if (members.isEmpty || members.any((m) => m.type != 'const')) return null;
    return [for (final m in members) m.value];
  }

  /// Properties of an `object`, or of every object member of an `intersect`
  /// (later members win). Null for anything else.
  Map<String, SchemaNode>? get fields {
    final node = effective;
    if (node.type == 'object') return node.dict;
    if (node.type == 'intersect') {
      final merged = <String, SchemaNode>{};
      for (final member in node._list) {
        final f = member.fields;
        if (f == null) return null;
        merged.addAll(f);
      }
      return merged;
    }
    return null;
  }

  @override
  String toString() => 'SchemaNode($type)';
}

// -----------------------------------------------------------------------------
// Values
// -----------------------------------------------------------------------------

/// Whether [path] exists in [root] (a JSON object tree), and its value.
(bool, Object?) lookupPath(Object? root, List<String> path) {
  Object? node = root;
  for (final key in path) {
    if (node is Map) {
      if (!node.containsKey(key)) return (false, null);
      node = node[key];
    } else if (node is List) {
      final i = int.tryParse(key);
      if (i == null || i < 0 || i >= node.length) return (false, null);
      node = node[i];
    } else {
      return (false, null);
    }
  }
  return (true, node);
}

/// A copy of [root] with [value] at [path] (intermediate objects created).
Map<String, Object?> withPath(Map<String, Object?>? root, List<String> path, Object? value) {
  if (path.isEmpty) return asMap(value) ?? {};
  final copy = Map<String, Object?>.of(root ?? const {});
  final head = path.first;
  if (path.length == 1) {
    copy[head] = value;
  } else {
    final child = copy[head];
    if (child is List) {
      final i = int.tryParse(path[1]);
      final list = List<Object?>.of(child);
      if (i != null && i >= 0 && i < list.length) {
        list[i] = path.length == 2 ? value : withPath(asMap(list[i]), path.sublist(2), value);
        copy[head] = list;
      }
    } else {
      copy[head] = withPath(asMap(child), path.sublist(1), value);
    }
  }
  return copy;
}

/// A copy of [root] without [path] (empty parents kept).
Map<String, Object?> withoutPath(Map<String, Object?>? root, List<String> path) {
  final copy = Map<String, Object?>.of(root ?? const {});
  if (path.isEmpty) return {};
  if (path.length == 1) {
    copy.remove(path.first);
    return copy;
  }
  final child = asMap(copy[path.first]);
  if (child == null) return copy;
  copy[path.first] = withoutPath(child, path.sublist(1));
  return copy;
}

/// Structural equality of JSON values (`1 == 1.0`, maps unordered).
bool jsonEquals(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

// -----------------------------------------------------------------------------
// settings/describe
// -----------------------------------------------------------------------------

/// One schema-declared secret slot (`SettingsSecretView`): never the value.
class SettingsSecretSlot {
  const SettingsSecretSlot(this.path, {required this.set});

  /// From the section root.
  final List<String> path;

  /// The slot holds a value.
  final bool set;
}

/// One namespace of `settings/describe` with its schema
/// (`SettingsNamespaceView`).
class SettingsNamespaceView {
  const SettingsNamespaceView({
    required this.ns,
    required this.schema,
    required this.value,
    required this.revision,
    this.base,
    this.user,
    this.autoGenerate = true,
    this.secrets = const [],
    this.writable = true,
  });

  factory SettingsNamespaceView.fromJson(Object? json, {bool writable = true}) {
    final map = asMapOrEmpty(json);
    return SettingsNamespaceView(
      ns: asString(map['ns']) ?? '',
      schema: SchemaNode.fromJson(map['schema']),
      value: asMapOrEmpty(map['value']),
      revision: asInt(map['revision']) ?? 0,
      base: asMap(map['base']),
      user: asMap(map['user']),
      autoGenerate: map['autoGenerate'] != false,
      secrets: [
        for (final s in asListOrEmpty(map['secrets']))
          if (asMap(s) case final slot?) SettingsSecretSlot(asStringList(slot['path']), set: slot['set'] == true),
      ],
      writable: writable,
    );
  }

  /// Profile entry id (the bundle row id: `subagent`, `cot-translation`).
  final String ns;
  final SchemaNode schema;

  /// Resolved value (secrets removed).
  final Map<String, Object?> value;

  /// Composition beneath the profile, defaults resolved.
  final Map<String, Object?>? base;

  /// The profile's own override; a field here is the user's.
  final Map<String, Object?>? user;
  final int revision;

  /// The plugin did not opt out of a generated page.
  final bool autoGenerate;
  final List<SettingsSecretSlot> secrets;

  /// From the describe envelope: the profile accepts writes.
  final bool writable;

  /// The same namespace as the schema-less [SettingsSection].
  SettingsSection get section =>
      SettingsSection(ns: ns, value: value, revision: revision, writable: writable, user: user, base: base);

  SettingsNamespaceView copyWith({
    Map<String, Object?>? value,
    Map<String, Object?>? user,
    int? revision,
    List<SettingsSecretSlot>? secrets,
  }) => SettingsNamespaceView(
    ns: ns,
    schema: schema,
    value: value ?? this.value,
    revision: revision ?? this.revision,
    base: base,
    user: user ?? this.user,
    autoGenerate: autoGenerate,
    secrets: secrets ?? this.secrets,
    writable: writable,
  );
}

/// `settings/describe` (`SettingsDescribeValue`).
class SettingsDescription {
  const SettingsDescription({required this.namespaces, this.writable = true, this.hasDocument = false});

  factory SettingsDescription.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final writable = map['writable'] != false;
    return SettingsDescription(
      writable: writable,
      hasDocument: map['hasDocument'] == true,
      namespaces: {
        for (final n in asListOrEmpty(map['namespaces']))
          if (SettingsNamespaceView.fromJson(n, writable: writable) case final view when view.ns.isNotEmpty)
            view.ns: view,
      },
    );
  }

  /// False under a read-only profile: every write is refused.
  final bool writable;

  /// The Host owns a local settings document (its path is not exposed).
  final bool hasDocument;

  /// By namespace, in the Host's order.
  final Map<String, SettingsNamespaceView> namespaces;
}

// -----------------------------------------------------------------------------
// pluginInventory/list
// -----------------------------------------------------------------------------

/// One non-group Loader entry (`PluginInventoryEntry`).
class PluginInventoryEntry {
  const PluginInventoryEntry({
    required this.entryId,
    required this.moduleName,
    required this.enabled,
    this.meta,
    this.fiberPhase,
  });

  factory PluginInventoryEntry.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginInventoryEntry(
      entryId: asString(map['entryId']) ?? '',
      moduleName: asString(map['moduleName']) ?? '',
      enabled: map['enabled'] == true,
      meta: PluginDisplayMeta.fromJson(map['meta']),
      fiberPhase: asString(map['fiberPhase']),
    );
  }

  /// Loader-tree id: `include:subagent` for a bundle row, a hash for a
  /// hand-written profile row.
  final String entryId;

  /// Module the Loader imports (`@deepseek-ai/dsh-subagent`, `cordis:include`).
  final String moduleName;
  final PluginDisplayMeta? meta;

  /// Effective enablement, disabled ancestor groups included.
  final bool enabled;

  /// `pending`, `loading`, `active`, `failed`, `unloading`, or null when no
  /// root fiber lives.
  final String? fiberPhase;

  /// The row id a bundle declared (`subagent` for `include:subagent`): also
  /// the entry's settings namespace.
  String get rowId => entryId.startsWith('include:') ? entryId.substring('include:'.length) : entryId;
}

/// One plugin row of an agent preset's composition (`AgentPresetPluginRow`).
class PresetPluginRow {
  const PresetPluginRow({
    required this.moduleName,
    required this.enabled,
    this.entryId,
    this.meta,
    this.conditional = false,
    this.condition,
    this.fiberPhase,
  });

  factory PresetPluginRow.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PresetPluginRow(
      entryId: asString(map['entryId']),
      moduleName: asString(map['moduleName']) ?? '',
      enabled: map['enabled'] == true,
      conditional: map['enabled'] == 'conditional',
      condition: asString(map['condition']),
      meta: PluginDisplayMeta.fromJson(map['meta']),
      fiberPhase: asString(map['fiberPhase']),
    );
  }

  final String? entryId;
  final String moduleName;
  final PluginDisplayMeta? meta;
  final bool enabled;

  /// `enabled: 'conditional'`: a `!!js` expression no live session decided.
  final bool conditional;

  /// The row's own disabled expression.
  final String? condition;
  final String? fiberPhase;
}

/// One agent preset's composition (`AgentPresetPluginGroup`).
class PresetPlugins {
  const PresetPlugins({required this.id, this.name, this.isDefault = false, this.broken, this.rows = const []});

  factory PresetPlugins.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PresetPlugins(
      id: asString(map['id']) ?? '',
      name: asString(map['name']),
      isDefault: map['isDefault'] == true,
      broken: asString(map['broken']),
      rows: [for (final r in asListOrEmpty(map['rows'])) PresetPluginRow.fromJson(r)],
    );
  }

  final String id;
  final String? name;
  final bool isDefault;

  /// Why the composition could not be read; [rows] is empty then.
  final String? broken;
  final List<PresetPluginRow> rows;
}

/// `pluginInventory/list` (`PluginInventorySnapshot`).
class PluginInventory {
  const PluginInventory({required this.entries, this.presets = const [], this.managementAvailable = false});

  factory PluginInventory.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return PluginInventory(
      managementAvailable: map['managementAvailable'] == true,
      entries: [
        for (final e in asListOrEmpty(map['entries']))
          if (PluginInventoryEntry.fromJson(e) case final entry when entry.entryId.isNotEmpty) entry,
      ],
      presets: [
        for (final p in asListOrEmpty(map['agentPresets']))
          if (PresetPlugins.fromJson(p) case final preset when preset.id.isNotEmpty) preset,
      ],
    );
  }

  /// Built from `pluginManager/listPlugins` where the inventory Remote is not
  /// reachable (the relay allow-list): no preset compositions.
  factory PluginInventory.fromEntries(List<PluginEntry> entries) => PluginInventory(
    entries: [
      for (final e in entries)
        if (e.entryId.isNotEmpty)
          PluginInventoryEntry(
            entryId: e.entryId,
            moduleName: e.moduleName,
            enabled: e.enabled,
            meta: e.meta,
            fiberPhase: e.fiberPhase,
          ),
    ],
  );

  final bool managementAvailable;

  /// Loader order.
  final List<PluginInventoryEntry> entries;

  /// Present when an agent-preset roster is composed.
  final List<PresetPlugins> presets;
}

// -----------------------------------------------------------------------------
// Calls
// -----------------------------------------------------------------------------

extension EngineSettingsApi on DshClient {
  /// `settings/describe`: every configurable entry with its schema and layers
  /// (secrets redacted).
  Future<SettingsDescription> describeSettings() async {
    final read = tryBackgroundListRead(BackgroundListKind.settings);
    if (read != null) return (await read) as SettingsDescription;
    return SettingsDescription.fromJson(await rpc.call('settings/describe'));
  }

  /// `settings/mutate` with the namespace's new view (schema included). A
  /// stale [expectedRevision] fails with `settings/conflict`; validation, a
  /// read-only profile or a home-patch override with `settings/rejected`.
  Future<SettingsNamespaceView> mutateSettingsView(
    String ns,
    List<SettingsOp> ops, {
    int? expectedRevision,
    bool writable = true,
  }) async {
    final result = await rpc.call('settings/mutate', {
      'ns': ns,
      'ops': [for (final op in ops) op.toJson()],
      'expectedRevision': ?expectedRevision,
    });
    return SettingsNamespaceView.fromJson(result, writable: writable);
  }

  /// `pluginInventory/list`.
  Future<PluginInventory> pluginInventory() async {
    final read = tryBackgroundListRead(BackgroundListKind.inventory);
    if (read != null) return (await read) as PluginInventory;
    return PluginInventory.fromJson(await rpc.call('pluginInventory/list'));
  }
}
