// 设置 › 能力 › 图像与视频 (media-generation §5.8): the curated page over the
// media plugin's own settings namespace — the default model per kind, the
// services, and the cost guard. Services start from the provider presets the
// catalogue publishes (plugin 0.3.0), or the app's fallback list for 0.2.x,
// so the protocol, endpoint, models and credential name are never typed; the
// details page edits what a preset cannot know (the key, models, advanced
// values).
//
// A catalogue that is missing, damaged or empty leaves the existing services
// editable but cannot name new ones or defaults: the page says so instead of
// inventing models.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/engine_settings_state.dart';
import '../../../state/media_catalog.dart';
import '../../../state/media_generation.dart' show GenerateKind, mediaCatalogProvider;
import '../../../state/media_settings.dart';
import '../../engine_settings/field_row.dart';
import '../../engine_settings/field_sheets.dart';
import '../../engine_settings/schema_form.dart';
import '../../features/feature_widgets.dart';
import '../settings_widgets.dart';
import 'media_service_detail_page.dart';
import 'media_shared.dart';

class MediaSettingsHomePage extends ConsumerWidget {
  const MediaSettingsHomePage({super.key, required this.ns});

  /// The namespace the catalogue was found under (the host may rename the
  /// plugin's instance).
  final String ns;

  @override
  Widget build(BuildContext context, WidgetRef ref) => EngineFormScaffold(
    title: context.l10n.mediaSettingsTitle,
    namespaces: [ns],
    builder: (context, settings) => [MediaSettingsHome(ns: ns, settings: settings)],
  );
}

class MediaSettingsHome extends ConsumerWidget {
  const MediaSettingsHome({super.key, required this.ns, required this.settings});

  final String ns;
  final EngineSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final view = settings[ns]!;
    final catalog = ref.watch(mediaCatalogProvider);
    final presets = mediaPresetsOf(view);
    final servicesField = FieldRef(ns, const ['services']);
    final defaultsField = FieldRef(ns, const ['defaults']);
    final services = mediaServicesOf(settings.valueOf(servicesField));
    final defaults = settings.valueOf(defaultsField);
    final saving = settings.isSaving(servicesField) || settings.isSaving(defaultsField);
    final editable = settings.canWrite(ns) && !saving;
    final error = settings.errorOf(servicesField) ?? settings.errorOf(defaultsField);
    final catalogNote = mediaCatalogNote(catalog, l10n);
    final catalogReady = mediaCatalogReady(catalog);
    final editor = ref.read(engineSettingsProvider.notifier).edit(settings);

    final addable = <(MediaPreset, MediaServiceConfig)>[
      if (catalogReady)
        for (final preset in presets)
          if (mediaServiceFromPreset(preset: preset, catalog: catalog, existing: services) case final service?)
            (preset, service),
    ];
    final full = services.length >= mediaServiceLimit;

    // 0.2.x plugins have one general default pair; only 0.3.0+ has the image
    // and video pairs. Offer the shape the host's schema actually has, so a
    // new app never writes fields an older plugin would reject.
    final kindDefaultsSupported = settings.nodeOf(FieldRef(ns, const ['defaults', 'imageServiceId'])) != null;

    Widget legacyDefaultRow() {
      final choices = catalog.entries;
      final enabled = editable && catalogReady && choices.isNotEmpty;
      final value = switch (defaults) {
        final Map map when map['modelId'] is String && (map['modelId'] as String).isNotEmpty =>
          catalog.modelOf(map['modelId'] as String)?.label ?? (map['modelId'] as String),
        _ => l10n.engineFieldAuto,
      };
      return EngineFieldRow(
        title: l10n.mediaSettingsDefaultModel,
        subtitle: catalogReady && choices.isEmpty ? l10n.mediaSettingsNoAvailableService : null,
        value: value,
        enabled: enabled,
        onTap: enabled
            ? () => unawaited(
                showChoiceSheet(
                  context,
                  title: l10n.mediaSettingsDefaultModel,
                  options: [
                    (null, l10n.engineFieldAuto),
                    for (final entry in choices)
                      ((entry.service.id, entry.model.id), '${entry.model.label} · ${entry.service.title}'),
                  ],
                  selected: mediaDefaultPairLegacy(defaults),
                  onSelect: (value) {
                    final next = value is (String, String)
                        ? mediaDefaultsWith(defaults, serviceId: value.$1, modelId: value.$2)
                        : mediaDefaultsWith(defaults);
                    unawaited(editor.set(defaultsField, next));
                  },
                ),
              )
            : null,
      );
    }

    // A 0.3.0 plugin still keeps the old general pair for older clients and
    // still fails closed when its service disappears. Surface it when it is
    // set, so an upgraded host can see and clear a stale target instead of
    // showing 「自动」 while generation keeps refusing.
    Widget legacyCompatibilityRow() {
      final pair = mediaDefaultPairLegacy(defaults)!;
      final entry = catalog.entries
          .where((e) => e.namespace == ns && e.service.id == pair.$1 && e.model.id == pair.$2)
          .firstOrNull;
      final label = entry?.model.label ?? catalog.modelOf(pair.$2)?.label ?? pair.$2;
      return EngineFieldRow(
        title: l10n.mediaSettingsLegacyDefault,
        subtitle: entry == null ? l10n.mediaSettingsLegacyDefaultStale : l10n.mediaSettingsLegacyDefaultHint,
        value: label,
        enabled: editable,
        onTap: editable
            ? () => unawaited(
                showChoiceSheet(
                  context,
                  title: l10n.mediaSettingsLegacyDefault,
                  options: [
                    (null, l10n.mediaSettingsLegacyDefaultClear),
                    for (final choice in catalog.entries)
                      ((choice.service.id, choice.model.id), '${choice.model.label} · ${choice.service.title}'),
                  ],
                  selected: pair,
                  onSelect: (value) {
                    final next = value is (String, String)
                        ? mediaDefaultsWith(defaults, serviceId: value.$1, modelId: value.$2)
                        : mediaDefaultsWith(defaults, serviceId: '', modelId: '');
                    unawaited(editor.set(defaultsField, next));
                  },
                ),
              )
            : null,
      );
    }

    Widget defaultRow(GenerateKind kind) {
      final image = kind == GenerateKind.image;
      final choices = catalog.of(kind);
      final catalogHasKind = catalog.models.values.any((model) => model.kind == kind);
      final enabled = editable && catalogReady && choices.isNotEmpty;
      final value = catalog.defaultFor(kind)?.model.label ?? l10n.engineFieldAuto;
      final subtitle = !catalogReady || choices.isNotEmpty
          ? null
          : catalogHasKind
          ? (image ? l10n.mediaSettingsNoImageService : l10n.mediaSettingsNoVideoService)
          : (image ? l10n.mediaSettingsNoImageModels : l10n.mediaSettingsNoVideoModels);
      return EngineFieldRow(
        title: image ? l10n.mediaKindImage : l10n.mediaKindVideo,
        subtitle: subtitle,
        value: value,
        enabled: enabled,
        onTap: enabled
            ? () => unawaited(
                showChoiceSheet(
                  context,
                  title: image ? l10n.mediaKindImage : l10n.mediaKindVideo,
                  options: [
                    (null, l10n.engineFieldAuto),
                    for (final entry in choices)
                      ((entry.service.id, entry.model.id), '${entry.model.label} · ${entry.service.title}'),
                  ],
                  selected: mediaDefaultPair(defaults, kind),
                  onSelect: (value) {
                    final next = value is (String, String)
                        ? mediaDefaultsWith(defaults, kind: kind, serviceId: value.$1, modelId: value.$2)
                        : mediaDefaultsWith(defaults, kind: kind);
                    unawaited(editor.set(defaultsField, next));
                  },
                ),
              )
            : null,
      );
    }

    Widget serviceRow(MediaServiceConfig service) {
      final keySet = settings.credentials[service.keyRef]?.configured == true;
      final summary = mediaServiceModelsSummary(service, catalog);
      return EngineFieldRow(
        title: mediaServiceTitle(service, presets, english: AppLocale.isEnglish),
        subtitle: keySet ? summary : '$summary · ${l10n.mediaSettingsKeyMissing}',
        trailing: Switch.adaptive(
          value: service.enabled,
          onChanged: editable
              ? (on) => unawaited(mediaWriteService(editor, servicesField, services, service.copyWith(enabled: on)))
              : null,
        ),
        onTap: () => unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MediaServiceDetailPage(ns: ns, serviceId: service.id),
            ),
          ),
        ),
      );
    }

    final addSubtitle = full
        ? l10n.mediaSettingsServiceLimit(mediaServiceLimit)
        : addable.isEmpty
        ? (catalogNote == null ? l10n.mediaSettingsNoPresets : null)
        : l10n.mediaSettingsAddServiceHint;
    final addRow = EngineFieldRow(
      title: l10n.mediaSettingsAddService,
      subtitle: addSubtitle,
      enabled: editable && !full && addable.isNotEmpty,
      onTap: editable && !full && addable.isNotEmpty
          ? () => unawaited(
              showChoiceSheet(
                context,
                title: l10n.mediaSettingsAddService,
                options: [for (final (preset, _) in addable) (preset, preset.title(AppLocale.isEnglish))],
                selected: null,
                onSelect: (value) {
                  if (value is! MediaPreset) return;
                  final match = addable.where((entry) => entry.$1.id == value.id).firstOrNull;
                  if (match == null) return;
                  unawaited(_add(context, editor, servicesField, services, match.$2));
                },
              ),
            )
          : null,
    );

    final budgetSections = schemaFormGroups([
      SchemaFormSection(
        title: l10n.mediaSettingsBudget,
        fields: [
          SchemaFieldSpec(ns, const [
            'budget',
            'dailyCny',
          ], copy: FieldCopy(label: l10n.mediaSettingsDailyBudget, hint: l10n.mediaSettingsDailyBudgetHint)),
          SchemaFieldSpec(ns, const [
            'budget',
            'unknownPriceHoldCny',
          ], copy: FieldCopy(label: l10n.mediaSettingsUnknownPriceHold, hint: l10n.mediaSettingsUnknownPriceHoldHint)),
        ],
      ),
    ], settings: settings);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (catalogNote != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: FeatureNote(catalogNote)),
        if (services.isEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: FeatureNote(l10n.mediaSettingsNoServices)),
        SettingsSection(
          title: l10n.mediaSettingsDefaults,
          footer: Text(
            kindDefaultsSupported ? l10n.mediaSettingsDefaultsFooter : l10n.mediaSettingsDefaultFooterLegacy,
          ),
          children: kindDefaultsSupported
              ? [
                  defaultRow(GenerateKind.image),
                  defaultRow(GenerateKind.video),
                  if (mediaDefaultPairLegacy(defaults) != null) legacyCompatibilityRow(),
                ]
              : [legacyDefaultRow()],
        ),
        SettingsSection(
          title: l10n.mediaSettingsServices,
          children: [for (final service in services) serviceRow(service), addRow],
        ),
        if (error != null) MediaInlineError(error),
        ...budgetSections,
        if (settings.nodeOf(FieldRef(ns, const ['limits', 'maxImages'])) != null)
          SettingsSection(
            children: [
              EngineFieldRow(
                title: l10n.mediaSettingsLimits,
                subtitle: l10n.mediaSettingsLimitsHint,
                onTap: () => unawaited(
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _MediaLimitsPage(ns: ns))),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _add(
    BuildContext context,
    SettingsEditSession editor,
    FieldRef field,
    List<MediaServiceConfig> services,
    MediaServiceConfig service,
  ) async {
    final saved = await editor.set(field, mediaServiceRows([...services, service]));
    if (!saved || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MediaServiceDetailPage(ns: ns, serviceId: service.id),
      ),
    );
  }
}

/// 请求与存储上限, kept off the main page but not removed: the old generated
/// form exposed them and a low-bandwidth host may need them. The plugin's own
/// descriptions are Chinese; these labels follow the app language.
class _MediaLimitsPage extends ConsumerWidget {
  const _MediaLimitsPage({required this.ns});

  final String ns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.mediaSettingsLimits,
      namespaces: [ns],
      builder: (context, settings) => schemaFormGroups([
        SchemaFormSection(
          fields: [
            SchemaFieldSpec(ns, const ['limits', 'maxImages'], copy: FieldCopy(label: l10n.mediaSettingsMaxImages)),
            SchemaFieldSpec(ns, const [
              'limits',
              'maxImageBytes',
            ], copy: FieldCopy(label: l10n.mediaSettingsMaxImageBytes)),
            SchemaFieldSpec(ns, const [
              'limits',
              'maxResponseBytes',
            ], copy: FieldCopy(label: l10n.mediaSettingsMaxResponseBytes)),
            SchemaFieldSpec(ns, const [
              'limits',
              'maxTotalImageBytes',
            ], copy: FieldCopy(label: l10n.mediaSettingsMaxTotalImageBytes)),
            SchemaFieldSpec(ns, const [
              'limits',
              'maxVideoBytes',
            ], copy: FieldCopy(label: l10n.mediaSettingsMaxVideoBytes)),
          ],
        ),
      ], settings: settings),
    );
  }
}
