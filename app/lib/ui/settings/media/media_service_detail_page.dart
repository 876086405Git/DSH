// 设置 › 能力 › 图像与视频 › 服务详情 (media-generation §5.8): one service of
// the media plugin — its key (or the key another service of the provider
// already holds), whether it is on, the models the catalogue serves for its
// protocol, the advanced values a preset usually fills, and deleting it.
//
// The page edits the plugin's own `value.services[]`: every control writes the
// whole list through the engine settings' edit session, so it keeps the host
// affinity of the snapshot it was built from.

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
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';
import 'media_shared.dart';
import 'media_url_sheet.dart';

/// The plugin's `keyRef` / credential-name pattern.
const _credentialRefPattern = r'^[A-Za-z_][A-Za-z0-9_]{0,127}$';

class MediaServiceDetailPage extends ConsumerWidget {
  const MediaServiceDetailPage({super.key, required this.ns, required this.serviceId});

  final String ns;
  final String serviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(engineSettingsProvider).value;
    final view = settings?[ns];
    final presets = view == null ? fallbackMediaPresets : mediaPresetsOf(view);
    final service = settings == null
        ? null
        : mediaServiceById(mediaServicesOf(settings.valueOf(FieldRef(ns, const ['services']))), serviceId);
    final title = service == null ? serviceId : mediaServiceTitle(service, presets, english: AppLocale.isEnglish);
    return EngineFormScaffold(
      title: title,
      namespaces: [ns],
      builder: (context, settings) => [_MediaServiceDetailBody(ns: ns, serviceId: serviceId, settings: settings)],
    );
  }
}

class _MediaServiceDetailBody extends ConsumerWidget {
  const _MediaServiceDetailBody({required this.ns, required this.serviceId, required this.settings});

  final String ns;
  final String serviceId;
  final EngineSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final view = settings[ns]!;
    final servicesField = FieldRef(ns, const ['services']);
    final services = mediaServicesOf(settings.valueOf(servicesField));
    final service = mediaServiceById(services, serviceId);
    if (service == null) {
      return FeatureMessage(
        icon: AppIcons.error,
        title: l10n.mediaSettingsServiceGone,
        body: l10n.mediaSettingsServiceGoneBody,
      );
    }
    final presets = mediaPresetsOf(view);
    final preset = mediaPresetForService(presets, service);
    final english = AppLocale.isEnglish;
    final title = mediaServiceTitle(service, presets, english: english);
    final catalog = ref.watch(mediaCatalogProvider);
    final catalogNote = mediaCatalogNote(catalog, l10n);
    final saving = settings.isSaving(servicesField);
    final editable = settings.canWrite(ns) && !saving;
    final error = settings.errorOf(servicesField);
    final editor = ref.read(engineSettingsProvider.notifier).edit(settings);
    Future<bool> save(MediaServiceConfig next) => mediaWriteService(editor, servicesField, services, next);
    // A ref the page had not read yet (a manually typed existing env name) is
    // checked with the host once the write is through; reused refs are in the
    // snapshot already.
    Future<bool> saveKeyRef(MediaServiceConfig next) async {
      for (final donor in services.where((row) => row.keyRef == next.keyRef && row.id != service.id)) {
        if (!await confirmMediaTarget(context, donor.baseUrl, next.baseUrl)) return false;
        if (!context.mounted) return false;
      }
      final ok = await save(next);
      if (ok && !settings.credentials.containsKey(next.keyRef)) {
        unawaited(ref.read(engineSettingsProvider.notifier).refresh());
      }
      return ok;
    }

    // ── Key, reuse and the switch ──────────────────────────────────────────
    final credential = settings.credentials[service.keyRef];
    final configured = credential?.configured == true;
    // Only the media plugin's own references are ours to write: a reused
    // OpenAI/Ark environment credential belongs to whichever setting owns it,
    // and overwriting it here would silently break that integration.
    final owned = service.keyRef.startsWith('DSH_MEDIA_');
    final writable = owned && credential?.writable != false;
    final keyRow = EngineFieldRow(
      title: l10n.mediaSettingsApiKey,
      subtitle: !owned
          ? '${service.keyRef} · ${l10n.mediaSettingsKeyExternal}'
          : !writable && configured
          ? l10n.engineFieldFromEnvironment
          : service.keyRef,
      value: configured
          ? l10n.mediaConfigKeySaved
          : credential == null
          ? l10n.mediaConfigKeyUnknown
          : l10n.engineFieldNotConfigured,
      valueColor: configured ? null : colors.textTertiary,
      enabled: writable,
      onTap: writable
          ? () => unawaited(
              showSecretSheet(
                context,
                title: l10n.mediaSettingsApiKey,
                configured: configured,
                writable: writable,
                onSave: (value) => editor.setCredential(service.keyRef, value),
                onClear: () => editor.clearCredential(service.keyRef),
              ),
            )
          : null,
    );

    final donors = <String, MediaServiceConfig>{};
    for (final other in services) {
      if (other.id == service.id || other.provider != service.provider || other.keyRef.isEmpty) continue;
      donors.putIfAbsent(other.keyRef, () => other);
    }
    final reuseOptions = <(Object?, String)>[
      for (final MapEntry(:key, :value) in donors.entries)
        (key, '$key · ${mediaServiceTitle(value, presets, english: english)}'),
    ];
    final shared = donors.containsKey(service.keyRef);
    final reuseRow = EngineFieldRow(
      title: l10n.mediaSettingsReuseKey,
      subtitle: reuseOptions.isEmpty ? l10n.mediaSettingsReuseKeyNone : l10n.mediaSettingsReuseKeyHint,
      value: shared ? l10n.mediaSettingsReuseKeyShared : null,
      enabled: editable && reuseOptions.isNotEmpty,
      onTap: editable && reuseOptions.isNotEmpty
          ? () => unawaited(
              showChoiceSheet(
                context,
                title: l10n.mediaSettingsReuseKey,
                options: reuseOptions,
                selected: service.keyRef,
                onSelect: (value) {
                  if (value is! String || value == service.keyRef) return;
                  unawaited(saveKeyRef(service.copyWith(keyRef: value)));
                },
              ),
            )
          : null,
    );

    final enabledRow = MergeSemantics(
      child: EngineFieldRow(
        title: l10n.engineFieldEnabled,
        subtitle: l10n.mediaSettingsEnabledHint,
        trailing: Switch.adaptive(
          value: service.enabled,
          onChanged: editable ? (on) => unawaited(save(service.copyWith(enabled: on))) : null,
        ),
      ),
    );

    // ── Models ─────────────────────────────────────────────────────────────
    final profileModels = [
      for (final model in catalog.models.values)
        if (model.profile == service.profile) model,
    ];
    final known = {for (final model in profileModels) model.id};
    final extras = [
      for (final id in service.models)
        if (!known.contains(id)) id,
    ];
    String kindName(GenerateKind kind) => kind == GenerateKind.image ? l10n.mediaKindImage : l10n.mediaKindVideo;
    Widget modelRow({
      required String id,
      required String title,
      required String? subtitle,
      required bool on,
      required bool last,
    }) {
      final note = last ? [subtitle, l10n.mediaSettingsModelKeepOne].nonNulls.join(' · ') : subtitle;
      return MergeSemantics(
        child: EngineFieldRow(
          title: title,
          subtitle: note,
          trailing: Switch.adaptive(
            value: on,
            onChanged: editable && !last ? (value) => unawaited(save(service.withModel(id, on: value))) : null,
          ),
        ),
      );
    }

    final modelRows = <Widget>[
      for (final model in profileModels)
        modelRow(
          id: model.id,
          title: model.label,
          subtitle: kindName(model.kind),
          on: service.models.contains(model.id),
          last: service.models.length == 1 && service.models.contains(model.id),
        ),
      for (final id in extras)
        modelRow(
          id: id,
          title: id,
          subtitle: l10n.mediaSettingsModelMissing,
          on: true,
          last: service.models.length == 1,
        ),
    ];

    // ── Advanced ───────────────────────────────────────────────────────────
    Future<void> editText({
      required String title,
      required String current,
      required Future<bool> Function(String) onSubmit,
      required Future<bool> Function() onReset,
      String? pattern,
      String? patternMessage,
      TextInputType? keyboardType,
    }) => showTextSheet(
      context,
      title: title,
      meta: SchemaMeta(pattern: pattern),
      current: current,
      inherited: null,
      modified: true,
      patternMessage: patternMessage,
      keyboardType: keyboardType,
      onSubmit: onSubmit,
      onReset: onReset,
    );

    final baseUrlRow = EngineFieldRow(
      title: l10n.mediaSettingsBaseUrl,
      value: service.baseUrl,
      enabled: editable,
      onTap: editable
          ? () => unawaited(
              showFieldSheet<void>(
                context,
                (_) => MediaUrlSheet(
                  service: service,
                  catalog: mediaCatalogMetaOf(view),
                  defaultUrl: preset?.baseUrl,
                  onSave: (value) => save(service.copyWith(baseUrl: value)),
                ),
              ),
            )
          : null,
    );

    final providerRow = EngineFieldRow(
      title: l10n.mediaSettingsProvider,
      value: service.provider,
      enabled: editable,
      onTap: editable
          ? () => unawaited(
              editText(
                title: l10n.mediaSettingsProvider,
                current: service.provider,
                onSubmit: (value) => save(service.copyWith(provider: value)),
                onReset: () => save(service.copyWith(provider: preset?.provider ?? service.provider)),
              ),
            )
          : null,
    );

    final keyRefRow = EngineFieldRow(
      title: l10n.mediaSettingsKeyRef,
      value: service.keyRef,
      enabled: editable,
      onTap: editable
          ? () => unawaited(
              editText(
                title: l10n.mediaSettingsKeyRef,
                current: service.keyRef,
                pattern: _credentialRefPattern,
                patternMessage: l10n.mediaSettingsKeyRefInvalid,
                onSubmit: (value) => saveKeyRef(service.copyWith(keyRef: value)),
                onReset: () => saveKeyRef(
                  service.copyWith(
                    keyRef: preset == null
                        ? service.keyRef
                        : nextMediaCredentialRef(preset, [
                            for (final other in services)
                              if (other.id != service.id) other.keyRef,
                          ]),
                  ),
                ),
              ),
            )
          : null,
    );

    final responseFormatRow = service.profile == 'openai-compatible'
        ? EngineFieldRow(
            title: l10n.mediaSettingsResponseFormat,
            value: switch (service.responseFormat) {
              '' => l10n.mediaSettingsResponseFormatAuto,
              'url' => 'URL',
              _ => 'Base64',
            },
            enabled: editable,
            onTap: editable
                ? () => unawaited(
                    showChoiceSheet(
                      context,
                      title: l10n.mediaSettingsResponseFormat,
                      options: [('', l10n.mediaSettingsResponseFormatAuto), ('url', 'URL'), ('b64_json', 'Base64')],
                      selected: service.responseFormat,
                      onSelect: (value) {
                        if (value is String) unawaited(save(service.copyWith(responseFormat: value)));
                      },
                    ),
                  )
                : null,
          )
        : null;

    final serviceIdRow = EngineFieldRow(title: l10n.mediaSettingsServiceId, value: service.id, enabled: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null) MediaInlineError(error),
        SettingsSection(
          footer: Text(
            [
              l10n.mediaConfigKeyNote,
              l10n.mediaConfigConsumers(
                [
                  for (final namespace in settings.namespaces.values)
                    for (final row in mediaServicesOf(namespace.value['services']))
                      if (row.keyRef == service.keyRef)
                        '${mediaServiceTitle(row, mediaPresetsOf(namespace), english: english)} (${namespace.ns}/${row.id})',
                ].join(', '),
              ),
            ].join('\n'),
          ),
          children: [keyRow, reuseRow, enabledRow],
        ),
        SettingsSection(
          children: [
            EngineFieldRow(
              title: l10n.mediaConfigCheck,
              subtitle: l10n.mediaConfigCheckNote,
              onTap: () {
                final issues = <String>[
                  ?mediaUrlIssueText(l10n, mediaBaseUrlIssue(service.baseUrl, service.profile)),
                  if (!configured) l10n.mediaConfigCheckMissingKey,
                  if (!service.enabled) l10n.mediaConfigCheckDisabled,
                  if (!mediaCatalogReady(catalog)) ?catalogNote,
                  if (service.models.isEmpty ||
                      service.models.any((id) => catalog.modelOf(id)?.profile != service.profile))
                    l10n.mediaConfigCheckModels,
                ];
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (dialog) => AlertDialog(
                      title: Text(l10n.mediaConfigCheck),
                      content: SingleChildScrollView(
                        child: Text(
                          [
                            ...issues.isEmpty ? [l10n.mediaConfigCheckReady] : issues,
                            l10n.mediaConfigCheckNote,
                          ].join('\n\n'),
                        ),
                      ),
                      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonDone))],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        SettingsSection(
          title: l10n.mediaSettingsModels,
          footer: catalogNote == null ? null : Text(catalogNote),
          children: modelRows.isEmpty
              ? [EngineFieldRow(title: l10n.mediaSettingsModelsEmpty, enabled: false)]
              : modelRows,
        ),
        SettingsSection(
          title: l10n.mediaSettingsAdvanced,
          children: [baseUrlRow, providerRow, keyRefRow, ?responseFormatRow, serviceIdRow],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Center(
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              onPressed: editable ? () => unawaited(_delete(context, ref, service, services, title)) : null,
              icon: const Icon(AppIcons.delete, size: 19),
              label: Text(l10n.mediaSettingsDelete),
            ),
          ),
        ),
      ],
    );
  }

  /// Confirms, writes the service away and clears the defaults that named it;
  /// the key is left in the credential store.
  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    MediaServiceConfig service,
    List<MediaServiceConfig> services,
    String title,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.mediaSettingsDeleteTitle(title)),
        content: Text(l10n.mediaSettingsDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final defaultsField = FieldRef(ns, const ['defaults']);
    final nextDefaults = mediaDefaultsClearedFor(settings.valueOf(defaultsField), service.id);
    final editor = ref.read(engineSettingsProvider.notifier).edit(settings);
    final fields = [
      FieldRef(ns, const ['services']),
      if (nextDefaults != null) defaultsField,
    ];
    final saved = await editor.write(ns, [
      SettingsOp.set(const ['services'], mediaServiceRows(withoutMediaService(services, service.id))),
      if (nextDefaults != null) SettingsOp.set(const ['defaults'], nextDefaults),
    ], fields: fields);
    if (saved && context.mounted) Navigator.of(context).pop();
  }
}
