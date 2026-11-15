// 「联网搜索」, after `dsh-client-ui-settings-web-search`: the switch between
// DeepSeek Messages search (`web-search-deepseek`) and the Search / Fetch
// APIs (`web-deepseek-api`), which writes both provider selections of `web`
// together; then the selected API's key, endpoint and per-search limit. The
// key goes to the credential the selected section names.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/engine_settings_state.dart';
import '../theme/theme.dart';
import 'field_row.dart';
import 'namespace_copy.dart';
import 'schema_form.dart';

/// Provider ids the switch writes, by `web` field and position.
const webSearchProviders = {
  'searchProvider': (api: 'deepseek-search-api', messages: 'deepseek-official'),
  'fetchProvider': (api: 'deepseek-fetch-api', messages: 'http'),
};

/// The `web` edits for one switch position: a target equal to the composed
/// value clears the override instead of storing a copy of it.
List<SettingsOp> webSearchSwitchOps(SettingsNamespaceView web, {required bool api}) => [
  for (final MapEntry(:key, :value) in webSearchProviders.entries)
    if (lookupPath(web.base, [key]).$2 == (api ? value.api : value.messages))
      SettingsOp.unset([key])
    else
      SettingsOp.set([key], api ? value.api : value.messages),
];

class WebSearchSettingsPage extends ConsumerWidget {
  const WebSearchSettingsPage({super.key});

  static const messagesNs = 'web-search-deepseek';
  static const apiNs = 'web-deepseek-api';
  static const webNs = 'web';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return EngineFormScaffold(
      title: l10n.engineSearchTitle,
      namespaces: const [messagesNs],
      builder: (context, settings) {
        final switchable = settings.served(webNs) && settings.served(apiNs);
        final api = switchable && settings.valueOf(const FieldRef(webNs, ['searchProvider'])) == 'deepseek-search-api';
        final ns = api ? apiNs : messagesNs;
        SchemaFieldSpec field(String key) => SchemaFieldSpec(
          ns,
          [key],
          copy: copyOf(ns, [key]),
          keyboardType: key == 'baseURL' ? TextInputType.url : null,
        );
        return schemaFormGroups([
          if (switchable)
            SchemaFormSection(
              children: [_ApiSwitch(settings: settings, api: api)],
            ),
          SchemaFormSection(
            title: l10n.engineSearchDeepSeek,
            fields: [field('apiKey'), field('baseURL'), field(api ? 'count' : 'maxUses')],
          ),
        ], settings: settings);
      },
    );
  }
}

class _ApiSwitch extends ConsumerWidget {
  const _ApiSwitch({required this.settings, required this.api});

  final EngineSettings settings;
  final bool api;

  static const _fields = [
    FieldRef(WebSearchSettingsPage.webNs, ['searchProvider']),
    FieldRef(WebSearchSettingsPage.webNs, ['fetchProvider']),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final web = settings[WebSearchSettingsPage.webNs]!;
    final saving = _fields.any(settings.isSaving);
    final error = _fields.map(settings.errorOf).nonNulls.firstOrNull;
    final enabled = settings.canWrite(WebSearchSettingsPage.webNs) && !saving;
    final layer = settings.layerOf(_fields.first);
    void toggle(bool on) {
      for (final f in _fields) {
        ref.read(engineSettingsProvider.notifier).clearError(f);
      }
      unawaited(
        ref
            .read(engineSettingsProvider.notifier)
            .write(WebSearchSettingsPage.webNs, webSearchSwitchOps(web, api: on), fields: _fields),
      );
    }

    return MergeSemantics(
      child: EngineFieldRow(
        title: l10n.engineSearchNewApi,
        subtitle: error ?? (layer == FieldLayer.locked ? lockedHint : null),
        subtitleColor: error != null ? colors.danger : null,
        badge: layer == FieldLayer.user && enabled ? modifiedBadge : null,
        enabled: enabled,
        onTap: enabled ? () => toggle(!api) : null,
        trailing: Switch.adaptive(value: api, onChanged: enabled ? toggle : null),
      ),
    );
  }
}
