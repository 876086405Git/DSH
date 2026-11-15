// 「子代理」, after `dsh-client-ui-settings-subagent`: the delegation limits
// (`subagent`: recursion depth, how many run at once) and which models an
// agent may pick for the subagents it starts
// (`subagent-model-selection-settings`: a switch and the allowed routes from
// the model catalog). Turning the switch on needs at least one model, so it
// is only written together with the first one picked.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart' show ModelCatalog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../../state/models_state.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../providers/providers_page.dart' show openProviders;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'field_row.dart';
import 'namespace_copy.dart';
import 'schema_form.dart';

/// One allowed route (`{provider, model}`).
typedef ModelRoute = ({String provider, String model});

List<ModelRoute> routesOf(Object? value) => [
  if (value is List)
    for (final item in value)
      if (item is Map && item['provider'] is String && item['model'] is String)
        (provider: item['provider'] as String, model: item['model'] as String),
];

List<Map<String, Object?>> routesJson(List<ModelRoute> routes) => [
  for (final r in routes) {'provider': r.provider, 'model': r.model},
];

/// A model the switch can allow: from the catalog, or saved but no longer
/// offered.
class ModelCandidate {
  const ModelCandidate({required this.route, required this.name, required this.providerName, required this.available});

  final ModelRoute route;
  final String name;
  final String providerName;
  final bool available;
}

/// The catalog's models grouped by provider, then the saved routes the
/// catalog no longer lists. Pure for testing.
List<(String group, List<ModelCandidate> models)> modelCandidates(ModelCatalog? catalog, List<ModelRoute> saved) {
  final left = {...saved};
  final groups = <(String, List<ModelCandidate>)>[];
  for (final group in catalog?.groups ?? const []) {
    if (group.models.isEmpty) continue;
    groups.add((
      group.name,
      [
        for (final m in group.models)
          ModelCandidate(
            route: (provider: group.id, model: m.id),
            name: m.name,
            providerName: group.name,
            available: true,
          ),
      ],
    ));
    left.removeAll([for (final m in group.models) (provider: group.id, model: m.id)]);
  }
  if (left.isNotEmpty) {
    groups.add((
      appL10n.engineSubagentSavedUnavailable,
      [for (final r in left) ModelCandidate(route: r, name: r.model, providerName: r.provider, available: false)],
    ));
  }
  return groups;
}

class SubagentSettingsPage extends ConsumerStatefulWidget {
  const SubagentSettingsPage({super.key});

  static const limitsNs = 'subagent';
  static const modelsNs = 'subagent-model-selection-settings';

  @override
  ConsumerState<SubagentSettingsPage> createState() => _SubagentSettingsPageState();
}

class _SubagentSettingsPageState extends ConsumerState<SubagentSettingsPage> {
  static const _enabled = FieldRef(SubagentSettingsPage.modelsNs, ['enabled']);
  static const _allowed = FieldRef(SubagentSettingsPage.modelsNs, ['allowedModels']);

  /// Switched on, waiting for the first model before anything is written.
  bool _pendingOn = false;

  /// A local refusal (removing the last model).
  String? _note;

  EngineSettingsController get _controller => ref.read(engineSettingsProvider.notifier);

  void _toggle(EngineSettings settings, bool on) {
    setState(() => _note = null);
    _controller
      ..clearError(_enabled)
      ..clearError(_allowed);
    final allowed = routesOf(settings.valueOf(_allowed));
    if (on && allowed.isEmpty) {
      setState(() => _pendingOn = true);
      return;
    }
    if (!on && _pendingOn) {
      setState(() => _pendingOn = false);
      if (settings.valueOf(_enabled) != true) return;
    }
    unawaited(_controller.set(_enabled, on));
  }

  void _pick(EngineSettings settings, ModelRoute route) {
    final allowed = routesOf(settings.valueOf(_allowed));
    final selected = allowed.contains(route);
    final enabled = settings.valueOf(_enabled) == true;
    if (selected) {
      if (allowed.length == 1 && enabled) {
        setState(() => _note = context.l10n.engineSubagentKeepOneModel);
        return;
      }
      setState(() => _note = null);
      unawaited(_controller.set(_allowed, routesJson([...allowed]..remove(route))));
      return;
    }
    setState(() => _note = null);
    final next = routesJson([...allowed, route]);
    if (_pendingOn && !enabled) {
      setState(() => _pendingOn = false);
      unawaited(
        _controller.write(
          SubagentSettingsPage.modelsNs,
          [
            const SettingsOp.set(['enabled'], true),
            SettingsOp.set(['allowedModels'], next),
          ],
          fields: [_enabled, _allowed],
        ),
      );
      return;
    }
    unawaited(_controller.set(_allowed, next));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineSubagentTitle,
      namespaces: const [SubagentSettingsPage.limitsNs, SubagentSettingsPage.modelsNs],
      builder: (context, settings) {
        const ns = SubagentSettingsPage.limitsNs;
        SchemaFieldSpec limit(String key) => SchemaFieldSpec(ns, [key], copy: copyOf(ns, [key]));
        return schemaFormGroups([
          SchemaFormSection(title: l10n.engineSubagentLimits, fields: [limit('maxDepth'), limit('maxActiveSubagents')]),
          if (settings.served(SubagentSettingsPage.modelsNs)) ..._modelSections(context, settings),
        ], settings: settings);
      },
    );
  }

  List<SchemaFormSection> _modelSections(BuildContext context, EngineSettings settings) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabledValue = settings.valueOf(_enabled) == true;
    final on = enabledValue || _pendingOn;
    final allowed = routesOf(settings.valueOf(_allowed));
    final canWrite = settings.canWrite(SubagentSettingsPage.modelsNs);
    final saving = settings.isSaving(_enabled) || settings.isSaving(_allowed);
    final error = settings.errorOf(_enabled) ?? settings.errorOf(_allowed);
    final layer = settings.layerOf(_enabled);
    final enabledCopy = copyOf(SubagentSettingsPage.modelsNs, ['enabled']);
    final switchRow = MergeSemantics(
      child: EngineFieldRow(
        title: enabledCopy.label!,
        subtitle: error ?? (layer == FieldLayer.locked ? lockedHint : null),
        subtitleColor: error != null ? colors.danger : null,
        badge: layer == FieldLayer.user && canWrite ? modifiedBadge : null,
        enabled: canWrite && !saving,
        onTap: canWrite && !saving ? () => _toggle(settings, !on) : null,
        trailing: Switch.adaptive(value: on, onChanged: canWrite && !saving ? (v) => _toggle(settings, v) : null),
      ),
    );
    final sections = <SchemaFormSection>[
      SchemaFormSection(
        title: l10n.engineSubagentModelSelection,
        children: [switchRow],
        footer: _note ?? (_pendingOn && allowed.isEmpty ? l10n.engineSubagentPickFirstModel : null),
      ),
    ];
    if (!on) return sections;

    final catalog = ref.watch(modelCatalogProvider);
    if (catalog.isLoading && !catalog.hasValue) {
      sections.add(const SchemaFormSection(children: [QuietSpinner(padding: EdgeInsets.symmetric(vertical: 20))]));
      return sections;
    }
    final groups = modelCandidates(catalog.value, allowed);
    if (catalog.hasError && !catalog.hasValue) {
      sections.add(
        SchemaFormSection(
          children: [
            EngineFieldRow(
              title: l10n.engineSubagentReadModelsFailed,
              value: l10n.commonRetry,
              onTap: () => ref.invalidate(modelCatalogProvider),
            ),
          ],
        ),
      );
    } else if (groups.isEmpty) {
      sections.add(
        SchemaFormSection(
          children: [
            EngineFieldRow(
              title: l10n.engineSubagentNoModels,
              value: l10n.engineSubagentConnectModel,
              onTap: () => openProviders(context),
            ),
          ],
        ),
      );
    }
    for (final (title, models) in groups) {
      sections.add(
        SchemaFormSection(
          title: title,
          children: [
            for (final m in models)
              Semantics(
                selected: allowed.contains(m.route),
                child: EngineFieldRow(
                  key: ValueKey('model-${m.route.provider}/${m.route.model}'),
                  title: m.name,
                  subtitle: m.available
                      ? (m.name == m.route.model ? null : m.route.model)
                      : l10n.engineSubagentUnavailableProvider(m.providerName),
                  enabled: canWrite && !saving,
                  chevron: false,
                  onTap: canWrite && !saving ? () => _pick(settings, m.route) : null,
                  trailing: allowed.contains(m.route)
                      ? Icon(AppIcons.radioOn, size: 22, color: scheme.primary)
                      : Icon(AppIcons.radioOff, size: 22, color: colors.textTertiary),
                ),
              ),
          ],
        ),
      );
    }
    return sections;
  }
}
