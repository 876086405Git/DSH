// The schema-driven form engine of the native engine settings: one tile per
// field that reads the field's schemastery node, its layers and its save
// state from [engineSettingsProvider] and picks the control — switch,
// capsule or picker for constants, number sheet with units, text sheet,
// write-only secret, list / key-value / object-list editors, or a read-only
// value. Curated pages lay tiles out with Chinese copy; [schemaSections]
// lays out any plugin's namespace by itself.

import 'dart:async';

import 'schema_collapsed_groups.dart';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sequence_field.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/settings_state.dart';
import '../account/account_page.dart';
import '../common/segmented_pill.dart';
import '../features/feature_widgets.dart';
import '../settings/index/spot_anchor.dart' show anchorSpot;
import '../settings/index/spots.dart' show SettingsIndex;
import '../settings/settings_widgets.dart' show SettingsMetrics;
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../web/dsh_web_launcher.dart';
import '../web/web_target.dart';
import 'field_row.dart';
import 'field_sheets.dart';
import 'schema_fields.dart';
import 'bitset_field.dart';

export 'schema_fields.dart' show FieldCopy, FieldUnit;

/// One field placed on a page.
@immutable
class SchemaFieldSpec {
  const SchemaFieldSpec(
    this.ns,
    this.path, {
    this.copy = const FieldCopy(),
    this.icon,
    this.keyboardType,
    this.fallbackNode,
  });

  final String ns;
  final List<String> path;
  final FieldCopy copy;
  final IconData? icon;
  final TextInputType? keyboardType;

  /// A single unsupported branch at this value path, never a writable field.
  final SchemaNode? fallbackNode;

  FieldRef get ref => FieldRef(ns, path);

  String get key => path.isEmpty ? ns : path.last;
}

/// The tag a user-set field carries.
FieldBadge get modifiedBadge => FieldBadge(appL10n.engineFieldModified);

/// The tag an edited field carries until it is saved.
FieldBadge get stagedBadge => FieldBadge(appL10n.pluginConfigUnsaved);

/// Where a schema form reads its values and sends its edits: the engine's
/// settings unless a [SchemaFormScope] above says otherwise.
abstract class SchemaFormSource {
  const SchemaFormSource();

  EngineSettings? watch(WidgetRef ref);

  /// What [selector] picks from the settings, drawing again only when that
  /// changes (by `==`): a row of a long form leaves the others alone.
  T select<T>(WidgetRef ref, T Function(EngineSettings? settings) selector) => selector(watch(ref));

  SettingsEditor editor(WidgetRef ref, EngineSettings snapshot);

  /// What a secret that holds a value reads.
  String secretSetLabel(L10n l10n) => l10n.engineFieldConfigured;

  /// What a secret without one reads.
  String secretUnsetLabel(L10n l10n) => l10n.engineFieldNotConfigured;
}

/// The engine's settings (`settings/describe`, `settings/mutate`).
class EngineSettingsSource extends SchemaFormSource {
  const EngineSettingsSource();

  @override
  EngineSettings? watch(WidgetRef ref) => ref.watch(engineSettingsProvider).value;

  @override
  T select<T>(WidgetRef ref, T Function(EngineSettings? settings) selector) =>
      ref.watch(engineSettingsProvider.select((async) => selector(async.value)));

  @override
  SettingsEditor editor(WidgetRef ref, EngineSettings snapshot) =>
      ref.read(engineSettingsProvider.notifier).edit(snapshot);
}

/// Points the schema fields below at [source].
class SchemaFormScope extends InheritedWidget {
  const SchemaFormScope({super.key, required this.source, required super.child});

  final SchemaFormSource source;

  static SchemaFormSource of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SchemaFormScope>()?.source ?? const EngineSettingsSource();

  @override
  bool updateShouldNotify(SchemaFormScope oldWidget) => oldWidget.source != source;
}

/// What a locked field says instead of its hint.
String get lockedHint => appL10n.engineFieldLocked;

/// The rows of one field, driven by its schema; nothing when the namespace
/// or the field is not served. They draw again when what they show of the
/// settings changes ([SchemaFieldWatch]), not on every edit of the form.
class SchemaFieldTile extends ConsumerWidget {
  const SchemaFieldTile(this.spec, {super.key});

  final SchemaFieldSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = SchemaFormScope.of(context).select(ref, (settings) => SchemaFieldWatch(settings, spec)).settings;
    final node = spec.fallbackNode ?? settings?.nodeOf(spec.ref);
    if (settings == null || node == null) return const SizedBox.shrink();
    return SchemaFieldView(spec: spec, node: node, settings: settings);
  }
}

/// What one field's rows ([SchemaFieldView], [SecretFieldTile]) read from the
/// settings, so they draw again when it changes and not when another field
/// does: the field's value and layers, its error and edit state, and what
/// the namespace says as a whole (its schema, whether it can be written or
/// is locked); for a secret, what its row says of it (the credential it is
/// read from, set, writable, bound). A row that comes to read more of the
/// settings adds it here.
@immutable
class SchemaFieldWatch {
  factory SchemaFieldWatch(EngineSettings? settings, SchemaFieldSpec spec) {
    final view = settings?[spec.ns];
    if (settings == null || view == null) return SchemaFieldWatch._(settings, [settings == null], const []);
    final field = spec.ref;
    final key = field.key;
    final node = spec.fallbackNode ?? schemaAt(view.schema, spec.path);
    final secret = (node?.isSecret ?? false) || (node?.effective.isSecret ?? false);
    final (inValue, value) = lookupPath(view.value, spec.path);
    final (inBase, base) = lookupPath(view.base, spec.path);
    final (inUser, user) = lookupPath(view.user, spec.path);
    return SchemaFieldWatch._(
      settings,
      [
        view.schema,
        settings.writable,
        view.writable,
        settings.isLocked(spec.ns),
        settings.local,
        settings.errors[key],
        settings.staged.contains(key),
        settings.saving.contains(key),
        if (secret) ...[
          settings.credentialRefOf(field),
          settings.secretConfigured(field),
          settings.secretWritable(field),
          settings.secretUnbound(field),
        ],
      ],
      [inValue, value, inBase, base, inUser, user],
    );
  }

  const SchemaFieldWatch._(this.settings, this._same, this._values);

  /// The settings the rows draw from (not compared).
  final EngineSettings? settings;

  /// Compared with `==`.
  final List<Object?> _same;

  /// Compared by content.
  final List<Object?> _values;

  @override
  bool operator ==(Object other) =>
      other is SchemaFieldWatch && listEquals(_same, other._same) && jsonEquals(_values, other._values);

  @override
  int get hashCode => Object.hashAll(_same);
}

/// [SchemaFieldTile] with its inputs resolved (also used by pages that read
/// the settings themselves).
class SchemaFieldView extends ConsumerWidget {
  const SchemaFieldView({super.key, required this.spec, required this.node, required this.settings});

  final SchemaFieldSpec spec;
  final SchemaNode node;
  final EngineSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final source = SchemaFormScope.of(context);
    final controller = source.editor(ref, settings);
    final field = spec.ref;
    final copy = spec.copy;
    final kind = spec.fallbackNode != null ? FieldKind.readOnly : kindOf(node);
    final layer = settings.layerOf(field);
    final error = settings.errorOf(field);
    final enabled =
        settings.canWrite(field.ns) &&
        !schemaPathDisabled(settings[field.ns]!.schema, field.path) &&
        !node.effective.meta.disabled &&
        !node.meta.disabled;
    final title = labelFor(spec.key, node, copy);
    final hint = hintFor(node, copy);
    final subtitle = error ?? (layer == FieldLayer.locked ? lockedHint : hint);
    final subtitleColor = error != null ? colors.danger : null;
    final badge = settings.isStaged(field)
        ? stagedBadge
        : layer == FieldLayer.user && enabled
        ? modifiedBadge
        : null;
    final modified = layer == FieldLayer.user;
    final value = settings.valueOf(field);
    final inherited = settings.inheritedOf(field, fallback: copy.fallback);
    // Bounds and patterns of what the control edits (an optional value's member).
    final edited = valueNodeOf(node);
    final meta = edited.meta;

    Future<void> set(Object? next) async {
      controller.clearError(field);
      await controller.set(field, next, fallback: copy.fallback);
    }

    if (spec.fallbackNode != null || kind == FieldKind.readOnly) {
      return SchemaUnsupportedField(title: title, ns: spec.ns);
    }

    switch (kind) {
      case FieldKind.hidden:
      case FieldKind.group:
        return const SizedBox.shrink();

      case FieldKind.toggle:
        final on = (value ?? inherited) == true;
        return MergeSemantics(
          child: EngineFieldRow(
            icon: spec.icon,
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            badge: badge,
            enabled: enabled,
            onTap: enabled ? () => unawaited(set(!on)) : null,
            trailing: Switch.adaptive(value: on, onChanged: enabled ? (v) => unawaited(set(v)) : null),
          ),
        );

      case FieldKind.choice:
        final options = choicesFor(node, copy);
        final current = choiceValue(value ?? inherited, copy);
        if (segmentOf(spec, node, settings) case final segment?) {
          return FieldSegmentRow<Object?>(
            title: title,
            subtitle: subtitle,
            subtitleColor: subtitleColor,
            badge: badge,
            segments: [for (final (v, label) in segment.options) PillSegment<Object?>(v, label)],
            selected: segment.selected,
            onChanged: enabled ? (v) => unawaited(set(v)) : null,
          );
        }
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: valueLabel(current, copy, node: node),
          enabled: enabled,
          onTap: () => unawaited(
            showChoiceSheet(
              context,
              title: title,
              options: options,
              selected: current,
              onSelect: (v) => unawaited(set(v)),
            ),
          ),
        );

      case FieldKind.sequence:
      case FieldKind.jsonValue:
        final (present, stored) = lookupPath(settings[field.ns]?.value, field.path);
        final shown = present ? stored : inherited;
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: compactJson(shown),
          enabled: enabled,
          onTap: () => unawaited(
            showSequenceFieldSheet(
              context,
              title: title,
              node: node,
              current: shown,
              modified: modified,
              onSubmit: (next) async {
                if (jsonEquals(next, shown)) return true;
                return controller.set(field, next, fallback: copy.fallback);
              },
              onReset: () => controller.reset(field),
              namespace: spec.ns,
            ),
          ),
        );

      case FieldKind.number:
        final unit = copy.unit ?? unitFor(spec.key, node);
        final shown = (value ?? inherited) is num ? (value ?? inherited) as num : null;
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: shown == null ? l10n.commonNotSet : formatFieldNumber(shown, unit, copy),
          enabled: enabled,
          onTap: () => unawaited(
            showNumberSheet(
              context,
              title: title,
              meta: meta,
              unit: unit,
              suffix: copy.suffix,
              countUnit: copy.countUnit,
              current: value is num ? value : null,
              inherited: inherited is num ? inherited : null,
              modified: modified,
              onSubmit: (v) => controller.set(field, v, fallback: copy.fallback),
              onReset: () => controller.reset(field),
            ),
          ),
        );

      case FieldKind.bitset:
        final shown = value ?? inherited;
        final selected = shown is num ? shown.toInt().toSigned(32) : 0;
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: bitsetSummary(edited.bits, selected),
          enabled: enabled,
          onTap: () => unawaited(
            showBitsetFieldSheet(
              context,
              title: title,
              bits: edited.bits,
              current: selected,
              modified: modified,
              onSubmit: (next) async {
                if (next == selected) return true;
                return controller.set(field, next, fallback: copy.fallback);
              },
              onReset: () => controller.reset(field),
            ),
          ),
        );

      case FieldKind.text:
        final text = value is String && value.isNotEmpty ? value : (inherited is String ? inherited : null);
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: text == null || text.isEmpty ? (copy.placeholder ?? l10n.commonNotSet) : (copy.shown[text] ?? text),
          valueColor: text == null || text.isEmpty ? colors.textTertiary : null,
          enabled: enabled,
          onTap: () => unawaited(
            showTextSheet(
              context,
              title: title,
              meta: meta,
              current: value is String ? value : null,
              inherited: inherited is String ? inherited : null,
              modified: modified,
              hint: hint,
              placeholder: copy.placeholder,
              patternMessage: copy.patternMessage,
              keyboardType: spec.keyboardType,
              onSubmit: (v) => controller.set(field, v, fallback: copy.fallback),
              onReset: () => controller.reset(field),
            ),
          ),
        );

      case FieldKind.secret:
        return SecretFieldTile(spec: spec, title: title, hint: hint, settings: settings);

      case FieldKind.list:
        final items = value is List ? value : const [];
        final item = edited.inner!;
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: items.isEmpty ? l10n.engineFieldNone : l10n.commonItemCount(items.length),
          enabled: enabled,
          onTap: () => unawaited(
            showListSheet(
              context,
              title: title,
              item: item,
              itemLabel: copy.itemLabel ?? l10n.engineFieldItem,
              placeholder: copy.placeholder,
              patternMessage: copy.patternMessage,
              choices: copy.choices,
              read: (ref) => switch (source.watch(ref)?.valueOf(field)) {
                final List<Object?> list => list,
                _ => const [],
              },
              onChange: (next) => controller.set(field, next, fallback: copy.fallback),
            ),
          ),
        );

      case FieldKind.objectList:
        final items = value is List ? value : const [];
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: items.isEmpty ? l10n.engineFieldNone : l10n.commonItemCount(items.length),
          enabled: enabled,
          onTap: () => unawaited(
            showObjectListSheet(
              context,
              title: title,
              item: edited.inner!,
              read: (ref) => switch (source.watch(ref)?.valueOf(field)) {
                final List<Object?> list => list,
                _ => const [],
              },
              onChange: (next) => controller.set(field, next, fallback: copy.fallback),
            ),
          ),
        );

      case FieldKind.dict:
        final entries = value is Map ? value : const {};
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          badge: badge,
          value: entries.isEmpty ? l10n.engineFieldNone : l10n.commonItemCount(entries.length),
          enabled: enabled,
          onTap: () => unawaited(
            showDictSheet(
              context,
              title: title,
              value: edited.inner!,
              read: (ref) => asJsonMap(source.watch(ref)?.valueOf(field)),
              onChange: (next) => controller.set(field, next, fallback: copy.fallback),
            ),
          ),
        );

      case FieldKind.readOnly:
        final shown = value ?? inherited;
        return EngineFieldRow(
          icon: spec.icon,
          title: title,
          subtitle: subtitle,
          subtitleColor: subtitleColor,
          value: compactJson(shown),
          onTap: shown is Map || shown is List
              ? () => unawaited(showValueSheet(context, title: title, value: shown))
              : null,
        );
    }
  }
}

/// The capsule a choice field shows (two or three choices, one of them
/// current), or null when it gets a picker row: an unset optional choice
/// reads 「未设置」 there instead of a capsule with nothing selected.
({List<(Object?, String)> options, Object? selected})? segmentOf(
  SchemaFieldSpec spec,
  SchemaNode node,
  EngineSettings settings,
) {
  if (kindOf(node) != FieldKind.choice || spec.icon != null) return null;
  final options = choicesFor(node, spec.copy);
  if (options.length > 3) return null;
  final stored = settings.valueOf(spec.ref) ?? settings.inheritedOf(spec.ref, fallback: spec.copy.fallback);
  final current = choiceValue(stored, spec.copy);
  final matched = options.where((o) => jsonEquals(o.$1, current)).firstOrNull;
  return matched == null ? null : (options: options, selected: matched.$1);
}

/// A write-only secret: 「已配置 / 未配置」, the sheet to replace or remove it.
/// The local engine's DeepSeek key belongs to the app (it is pushed on every
/// start), so a field reading `DEEPSEEK_API_KEY` there opens the app's own
/// API Key page instead.
class SecretFieldTile extends ConsumerWidget {
  const SecretFieldTile({super.key, required this.spec, required this.title, this.hint, required this.settings});

  final SchemaFieldSpec spec;
  final String title;
  final String? hint;
  final EngineSettings settings;

  static const appKeyRef = 'DEEPSEEK_API_KEY';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final field = spec.ref;
    final credentialRef = settings.credentialRefOf(field);
    final configured = settings.secretConfigured(field);
    final writable = settings.secretWritable(field) && !schemaPathDisabled(settings[field.ns]!.schema, field.path);
    final error = settings.errorOf(field);
    if (settings.local && credentialRef == appKeyRef) {
      final hasKey = ref.watch(settingsProvider.select((s) => s.hasApiKey));
      return EngineFieldRow(
        icon: spec.icon,
        title: title,
        subtitle: error,
        subtitleColor: error != null ? colors.danger : null,
        value: hasKey || configured ? l10n.engineFieldSharedWithModel : l10n.engineFieldNotConfigured,
        valueColor: hasKey || configured ? null : colors.warning,
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AccountPage())),
      );
    }
    final source = SchemaFormScope.of(context);
    final controller = source.editor(ref, settings);
    return EngineFieldRow(
      icon: spec.icon,
      title: title,
      badge: settings.isStaged(field) ? stagedBadge : null,
      subtitle:
          error ??
          (settings.secretUnbound(field)
              ? l10n.pluginConfigSecretUnbound
              : !writable && configured
              ? l10n.engineFieldFromEnvironment
              : hint),
      subtitleColor: error != null ? colors.danger : null,
      value: configured ? source.secretSetLabel(l10n) : source.secretUnsetLabel(l10n),
      valueColor: configured ? null : colors.textTertiary,
      enabled: writable || configured,
      onTap: () => unawaited(
        showSecretSheet(
          context,
          title: title,
          configured: configured,
          writable: writable,
          onSave: (value) => controller.setSecret(field, value),
          onClear: () => controller.clearSecret(field),
        ),
      ),
    );
  }
}

// ── Sections ─────────────────────────────────────────────────────────────────

/// A titled group of fields (or of ready-made rows).
@immutable
class SchemaFormSection {
  const SchemaFormSection({this.title, this.fields = const [], this.children, this.footer});

  final String? title;
  final List<SchemaFieldSpec> fields;

  /// Rows built by the page; replace [fields].
  final List<Widget>? children;
  final String? footer;
}

/// Fields grouped by their object path. Unsupported intersection branches
/// get their own local fallback; recursive schemas stop at the repeated node.
List<SchemaFormSection> schemaSections(
  SettingsNamespaceView view, {
  Map<String, FieldCopy> copy = const {},
  String? title,
}) {
  final sections = <SchemaFormSection>[];
  void fallback(SchemaNode node, List<String> path, String? heading) {
    sections.add(
      SchemaFormSection(
        title: heading,
        fields: [
          SchemaFieldSpec(
            view.ns,
            path,
            fallbackNode: node,
            copy: FieldCopy(label: heading ?? title ?? humanizeKey(view.ns)),
          ),
        ],
      ),
    );
  }

  // Resolve visibility against the complete schema: later intersect members
  // can hide a path contributed by an earlier member. Do this before
  // unsupported branches are collapsed into explicit web rows.
  bool hiddenPath(List<String> path) {
    for (var length = 0; length <= path.length; length++) {
      final resolved = schemaAt(view.schema, path.take(length).toList());
      if (resolved != null && kindOf(resolved) == FieldKind.hidden) return true;
    }
    return false;
  }

  bool nativeField(SchemaFieldSpec field) {
    if (field.fallbackNode != null) return false;
    final node = schemaAt(view.schema, field.path);
    if (node == null) return false;
    return !{FieldKind.hidden, FieldKind.group, FieldKind.readOnly}.contains(kindOf(node));
  }

  void collapseUnsupported(int start, SchemaNode source, List<String> path, String? heading) {
    if (sections.length == start || sections.skip(start).any((section) => section.fields.any(nativeField))) return;
    sections.removeRange(start, sections.length);
    fallback(source, path, heading);
  }

  void walk(SchemaNode source, List<String> prefix, String? heading, Set<SchemaNode> ancestors) {
    // An optional object (`union([object, const(undefined)])`) is its fields.
    final node = schemaValueOf(source);
    if (source.meta.hidden || source.effective.meta.hidden || node.meta.hidden || hiddenPath(prefix)) return;
    if (ancestors.contains(node) || ancestors.length >= 32) {
      fallback(source, prefix, heading);
      return;
    }
    final next = {...ancestors, node};
    final start = sections.length;
    if (node.type == 'intersect') {
      for (final member in node.list) {
        walk(member, prefix, heading, next);
      }
      collapseUnsupported(start, source, prefix, heading);
      return;
    }
    if (node.type != 'object') {
      fallback(source, prefix, heading);
      return;
    }
    if (node.dict.isEmpty) {
      fallback(source, prefix, heading);
      return;
    }
    final leaves = <SchemaFieldSpec>[];
    final groups = <(String, SchemaNode, String)>[];
    for (final MapEntry(:key, :value) in node.dict.entries) {
      final path = [...prefix, key];
      final dotted = path.join('.');
      if (value.meta.hidden || value.effective.meta.hidden || hiddenPath(path)) continue;
      final held = schemaValueOf(value).type;
      if (held == 'object' || held == 'intersect') {
        groups.add((key, value, labelFor(key, value, copy[dotted] ?? const FieldCopy())));
      } else if (kindOf(value) != FieldKind.hidden) {
        leaves.add(SchemaFieldSpec(view.ns, path, copy: copy[dotted] ?? const FieldCopy()));
      }
    }
    if (leaves.isNotEmpty) sections.add(SchemaFormSection(title: heading, fields: leaves));
    for (final (key, child, label) in groups) {
      walk(child, [...prefix, key], prefix.isEmpty || heading == null ? label : '$heading · $label', next);
    }
    collapseUnsupported(start, source, prefix, heading);
  }

  walk(view.schema, const [], title, <SchemaNode>{});
  return sections;
}

/// One unsupported item still leaves the rest of the native form available:
/// its title over 「在网页版编辑此项」 (wrapping, never cut), the
/// open-external glyph where a chevron would be, the row opening the item on
/// the web.
class SchemaUnsupportedField extends ConsumerWidget {
  const SchemaUnsupportedField({super.key, required this.title, required this.ns});
  final String title;
  final String ns;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EngineFieldRow(
    title: title,
    subtitle: context.l10n.engineFieldEditOnWeb,
    opensExternally: true,
    onTap: () => openDshWeb(context, ref, target: DshWebTarget(pluginItem: [ns])),
  );
}

/// Whether a namespace has anything a form would show. A web fallback row
/// alone is not a native form: such a namespace stays with the plugin's
/// island or web page (#44), and fallback rows only fill gaps beside fields.
bool hasFormFields(SettingsNamespaceView view) =>
    schemaSections(view).any((s) => s.fields.any((f) => f.fallbackNode == null));

/// [sections] as settings groups. With [settings], fields the engine does not
/// serve (or would not show) are left out, and so are groups left empty.
List<Widget> schemaFormGroups(List<SchemaFormSection> sections, {EngineSettings? settings}) {
  bool shown(SchemaFieldSpec f) {
    if (settings == null) return true;
    if (f.fallbackNode != null) return true;
    final node = settings.nodeOf(f.ref);
    if (node == null) return false;
    final kind = kindOf(node);
    return kind != FieldKind.hidden && kind != FieldKind.group;
  }

  /// The capsule rows of a card, as what decides whether they fit inline.
  List<(String, String?, List<String>)> capsules(SchemaFormSection section) {
    if (settings == null || section.children != null) return const [];
    return [
      for (final f in section.fields)
        if (f.fallbackNode == null)
          if (settings.nodeOf(f.ref) case final node? when shown(f))
            if (segmentOf(f, node, settings) case final segment?)
              (
                labelFor(f.key, node, f.copy),
                settings.layerOf(f.ref) == FieldLayer.locked ? lockedHint : hintFor(node, f.copy),
                [for (final (_, label) in segment.options) label],
              ),
    ];
  }

  return collapseSchemaGroups(
    [
      for (final section in splitCollapsedSections(sections, settings))
        if (section.children ??
                [
                  for (final f in section.fields)
                    if (shown(f))
                      anchorSpot(SettingsIndex.forField(f.ns, f.path), SchemaFieldTile(f, key: ValueKey(f.ref.key))),
                ]
            case final rows when rows.isNotEmpty)
          (section: section, rows: rows),
    ],
    settings,
    uniform: (sections, card) => _UniformCapsules(rows: [for (final s in sections) ...capsules(s)], child: card),
  );
}

/// Stacks every capsule of a card when one of them does not fit beside its
/// title (rows sit 16 inside the card, the card 16 inside the page).
class _UniformCapsules extends StatelessWidget {
  const _UniformCapsules({required this.rows, required this.child});

  final List<(String, String?, List<String>)> rows;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 2 * 16 - 2 * SettingsMetrics.inset;
        final stacked = rows.any(
          (r) => !FieldSegmentRow.fitsInline(context, title: r.$1, subtitle: r.$2, labels: r.$3, width: width),
        );
        return SegmentLayout(stacked: stacked, child: child);
      },
    );
  }
}

// ── Page frame ───────────────────────────────────────────────────────────────

/// The frame every engine settings page shares: not connected, loading,
/// failed and "this host has none of it" states, the host in the subtitle
/// when it is a remote one, and a note when the settings are read-only.
class EngineFormScaffold extends ConsumerWidget {
  const EngineFormScaffold({
    super.key,
    required this.title,
    required this.namespaces,
    required this.builder,
    this.subtitle,
    this.missingTitle,
    this.missingBody,
    this.actions,
  });

  final String title;
  final String? subtitle;

  /// The page shows when any of these is served.
  final List<String> namespaces;
  final List<Widget> Function(BuildContext context, EngineSettings settings) builder;
  final String? missingTitle;
  final String? missingBody;
  final List<Widget> Function(BuildContext context, EngineSettings settings)? actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(engineSettingsProvider);
    final settings = async.value;
    final served = settings != null && namespaces.any(settings.served);
    final subtitleText = [if (settings != null && !settings.local) settings.hostLabel, ?subtitle].join(' · ');
    return AppPage.list(
      title: title,
      actions: served ? actions?.call(context, settings) ?? const [] : const [],
      subtitle: subtitleText.isEmpty ? null : Text(subtitleText),
      children: [
        if (settings == null && async.hasError)
          FeatureMessage(
            icon: AppIcons.error,
            title: l10n.engineSettingsReadFailed,
            body: describeSettingsError(async.error!),
            action: (l10n.commonRetry, () => ref.invalidate(engineSettingsProvider)),
          )
        else if (settings == null && async.isLoading)
          const FeatureLoading()
        else if (settings == null)
          const FeatureOffline()
        else if (!served)
          FeatureMessage(
            icon: AppIcons.unsupported,
            title: missingTitle ?? l10n.engineSettingsMissing,
            body: missingBody ?? l10n.engineSettingsPluginDisabled,
          )
        else ...[
          if (!settings.writable)
            Padding(padding: const EdgeInsets.only(bottom: 16), child: FeatureNote(l10n.engineSettingsReadOnly)),
          ...builder(context, settings),
        ],
      ],
    );
  }
}
