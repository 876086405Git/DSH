// 添加 / 编辑渠道: name, protocol, Base URL, API Key, optional headers, then models —
// fetched from the endpoint (`llm/discoverModels`) and picked in a sheet, or
// added by hand. One pinned 「保存」.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/providers_state.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/discard_guard.dart';
import '../common/expand_reveal.dart';
import '../common/field_paste.dart';
import '../common/sheet_title_bar.dart';
import '../common/smooth_size.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'provider_model_page.dart';
import 'provider_widgets.dart';

/// Protocol choices, in the adapter's order. 「兼容」 lives in the field label
/// so all three labels fit one capsule without shrinking.
const _protocols = [
  PillSegment(ProviderApi.openaiCompletions, 'OpenAI'),
  PillSegment(ProviderApi.anthropicMessages, 'Anthropic'),
  PillSegment(ProviderApi.openaiResponses, 'Responses'),
];

/// Pops with the provider id once saved.
class ProviderFormPage extends ConsumerStatefulWidget {
  const ProviderFormPage({super.key, this.existing});

  /// Null to add a new provider.
  final CustomProvider? existing;

  @override
  ConsumerState<ProviderFormPage> createState() => _ProviderFormPageState();
}

/// The fields that can carry an error, in page order.
enum _F { baseUrl, key, headers, models }

class _HeaderDraft {
  _HeaderDraft(this.name, this.value, {this.locked = false});

  final key = UniqueKey();
  final bool locked;
  String name;
  String value;
}

class _ProviderFormPageState extends ConsumerState<ProviderFormPage> with FieldPaste<ProviderFormPage> {
  late final _name = TextEditingController(text: widget.existing?.displayName ?? '');
  late final _baseUrl = TextEditingController(text: widget.existing?.baseUrl ?? '');
  final _key = TextEditingController();
  late ProviderApi _api = widget.existing?.api ?? ProviderApi.openaiCompletions;
  late List<ProviderModelSpec> _models = [...?widget.existing?.models];
  late final _headers = [
    for (final entry in (widget.existing?.headers ?? const <String, String>{}).entries)
      _HeaderDraft(entry.key, entry.value, locked: isReservedProviderHeader(entry.key)),
  ];
  bool _headersOpen = false;

  /// The provider being edited; set after a create whose key failed, so the
  /// next 「保存」 only retries what is missing.
  late CustomProvider? _editing = widget.existing;

  bool _obscure = true;
  bool _saving = false;
  bool _discovering = false;

  Map<_F, String> _errors = const {};

  /// Discovery's failure, under the models card.
  String? _modelsError;

  /// 「已补全为 …」 under the Base URL, after discovery added `/v1`.
  String? _baseUrlNote;

  /// A failure that isn't about one field.
  String? _formError;

  final _fieldKeys = {for (final f in _F.values) f: GlobalKey()};

  bool get _isEdit => _editing != null;

  /// A stored base is authoritative until its address or protocol is edited.
  String _baseUrlForRequest(String raw, ProviderApi api) {
    final existing = _editing;
    if (existing != null && existing.api == api && existing.baseUrl == raw) return raw;
    return normalizeBaseUrl(raw, api);
  }

  String _headersSignature() => jsonEncode([
    for (final header in _headers) [header.name, header.value],
  ]);

  bool get _headersEdited =>
      _headersSignature() !=
      jsonEncode([
        for (final entry in (_editing?.headers ?? const <String, String>{}).entries) [entry.key, entry.value],
      ]);

  String? _headersError() {
    // Existing settings can come from a newer or differently configured Host.
    // An unrelated edit must not rewrite or reject those stored fields.
    if (!_headersEdited) return null;
    return providerHeadersError([
      for (final header in _headers)
        if (!header.locked) MapEntry(header.name, header.value),
    ]);
  }

  Map<String, String>? _headersForRequest() {
    if (!_headersEdited) return null;
    final headers = {
      for (final header in _headers)
        if (header.name.trim().isNotEmpty) (header.locked ? header.name : header.name.trim()): header.value,
    };
    return mapEquals(headers, _editing?.headers ?? const {}) ? null : headers;
  }

  void _editHeaders(VoidCallback edit) => setState(() {
    edit();
    _errors = {..._errors}..remove(_F.headers);
    _formError = null;
  });

  late final Listenable _edits = Listenable.merge([_name, _baseUrl, _key]);
  late String _clean;

  String _signature() => jsonEncode([
    _name.text,
    _baseUrl.text,
    _key.text,
    _api.name,
    _headersSignature(),
    [for (final model in _models) model.toJson()],
  ]);

  @override
  void initState() {
    super.initState();
    _clean = _signature();
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _key.dispose();
    super.dispose();
  }

  void _edited(_F field) {
    if (_errors.containsKey(field) || _formError != null) {
      setState(() {
        _errors = {..._errors}..remove(field);
        _formError = null;
      });
    }
  }

  void _showErrors(Map<_F, String> errors) {
    setState(() {
      _errors = errors;
      if (errors.containsKey(_F.headers)) _headersOpen = true;
    });
    if (errors.isEmpty) return;
    final first = _F.values.firstWhere(errors.containsKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _fieldKeys[first]!.currentContext;
      if (target == null || !target.mounted) return;
      // Already in view between the top bar and the bottom bar: stay put.
      final box = target.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final media = MediaQuery.of(context);
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final visibleBottom = media.size.height - media.viewInsets.bottom - FormBottomBar.height;
        if (top >= media.padding.top + 56 && bottom <= visibleBottom) return;
      }
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: AppMotion.of(context, AppMotion.emphasized),
          curve: AppMotion.glide,
        ),
      );
    });
  }

  Future<void> _paste() async {
    final text = normalizeProviderKey(await readClipboard() ?? '');
    if (text.isEmpty || !mounted) return;
    _key.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _edited(_F.key);
  }

  Future<void> _discover() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final key = normalizeProviderKey(_key.text);
    final keyError = !_isEdit && key.isEmpty
        ? context.l10n.engineProviderKeyFirst
        : providerKeyError(key, required: false);
    final errors = <_F, String>{
      _F.baseUrl: ?baseUrlError(_baseUrl.text),
      _F.key: ?keyError,
      _F.headers: ?_headersError(),
    };
    _showErrors(errors);
    if (errors.isNotEmpty) return;
    final backend = ref.read(providerBackendProvider);
    final api = _api;
    final expectedHeaders = _headersSignature();
    final headers = _headersForRequest();
    var expectedUrl = _baseUrl.text;
    final url = _baseUrlForRequest(expectedUrl, api);
    bool isCurrent() =>
        mounted &&
        identical(ref.read(providerBackendProvider), backend) &&
        _api == api &&
        _baseUrl.text == expectedUrl &&
        normalizeProviderKey(_key.text) == key &&
        _headersSignature() == expectedHeaders;
    setState(() {
      _discovering = true;
      _modelsError = null;
      _baseUrlNote = null;
    });
    try {
      final result = await ref
          .read(providerActionsProvider)
          .discover(api: api, baseUrl: url, apiKey: key, existingId: _editing?.id, headers: headers);
      if (!mounted || !isCurrent()) return;
      if (result.baseUrl != url) {
        _baseUrl.text = result.baseUrl;
        setState(() => _baseUrlNote = context.l10n.engineProviderCompletedUrl(result.baseUrl));
      }
      // Keep pasted endpoints intact: saving must normalize the original input
      // once, not strip a second suffix from discovery's normalized base.
      // An actual discovery fallback belongs to this request; later edits do not.
      expectedUrl = _baseUrl.text;
      if (result.models.isEmpty) {
        setState(() => _modelsError = context.l10n.engineProviderNoDiscoveredModels);
        return;
      }
      final picked = await showModelPicker(context, candidates: result.models, added: {for (final m in _models) m.id});
      if (picked == null || picked.isEmpty || !isCurrent()) return;
      setState(() {
        _models = [..._models, for (final m in picked) m.toSpec()];
        _errors = {..._errors}..remove(_F.models);
      });
    } catch (error) {
      if (isCurrent()) setState(() => _modelsError = describeProviderError(error));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _addByHand() async {
    final id = await showAppDialog<String>(
      context: context,
      builder: (_) => _ManualModelDialog(taken: {for (final m in _models) m.id}),
    );
    if (id == null || !mounted) return;
    setState(() {
      _models = [..._models, ProviderModelSpec(id: id)];
      _errors = {..._errors}..remove(_F.models);
    });
  }

  void _remove(ProviderModelSpec model) => setState(() => _models = [..._models]..remove(model));

  /// 模型设置; what comes back replaces the row and is saved with the form.
  Future<void> _editModel(ProviderModelSpec model) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final edited = await Navigator.of(context).push(
      MaterialPageRoute<ProviderModelSpec>(
        builder: (_) => ProviderModelPage(model: model, defaults: _editing?.defaults ?? const ModelDefaults()),
      ),
    );
    if (edited == null || !mounted) return;
    setState(() => _models = [for (final m in _models) m.id == model.id ? edited : m]);
  }

  Future<void> _save() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final key = normalizeProviderKey(_key.text);
    final errors = <_F, String>{
      _F.baseUrl: ?baseUrlError(_baseUrl.text),
      _F.key: ?providerKeyError(key, required: !_isEdit),
      _F.headers: ?_headersError(),
      if (_models.isEmpty) _F.models: context.l10n.engineProviderNeedModel,
    };
    setState(() => _formError = null);
    _showErrors(errors);
    if (errors.isNotEmpty) return;
    final draft = ProviderDraft(
      name: _name.text,
      api: _api,
      baseUrl: _baseUrlForRequest(_baseUrl.text, _api),
      apiKey: key,
      models: _models,
      headers: _headersForRequest(),
    );
    setState(() => _saving = true);
    try {
      final id = await ref.read(providerActionsProvider).save(draft, existing: _editing);
      if (mounted) Navigator.of(context).pop(id);
    } on ProviderFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _formError = failure.message;
        if (failure.savedId case final id?) {
          _editing = CustomProvider(
            id: id,
            displayName: draft.effectiveName,
            api: draft.api,
            baseUrl: draft.baseUrl,
            models: draft.models,
            headers: draft.headers ?? _editing?.headers ?? const {},
            apiKeyEnv: deriveProviderKeyRef(id),
          );
        }
      });
    } catch (error) {
      if (mounted) setState(() => _formError = context.l10n.engineProviderSaveFailed(describeProviderError(error)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = DshColors.of(context);
    final backend = ref.watch(providerBackendProvider);
    // Keeps the read-back alive: its revision guards the edit, its ids the create.
    final snapshot = ref.watch(customProvidersProvider).value;
    final keyStored = switch (_editing) {
      final p? => snapshot?.keyStored(p) ?? p.apiKeyEnv != null,
      null => false,
    };
    final anthropic = _api == ProviderApi.anthropicMessages;
    final busy = _saving || _discovering;
    final modelsMessage = _errors[_F.models] ?? _modelsError;

    final page = AppPage.list(
      title: _isEdit ? l10n.engineProviderEdit : l10n.engineProviderAdd,
      // One column, not a lazy list: every field stays built so the first one
      // with a problem can be scrolled into view.
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection(
              title: l10n.engineProviderBasicInfo,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      label: l10n.commonName,
                      child: TextField(
                        controller: _name,
                        textInputAction: TextInputAction.next,
                        inputFormatters: [LengthLimitingTextInputFormatter(32)],
                        decoration: InputDecoration(hintText: l10n.engineProviderNameHint),
                      ),
                    ),
                    FormFieldBlock(
                      label: l10n.engineProviderCompatibleProtocol,
                      child: SegmentedPill<ProviderApi>(
                        segments: _protocols,
                        selected: _api,
                        onChanged: busy ? null : (v) => setState(() => _api = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              title: l10n.engineProviderConnection,
              children: [
                FormFieldGroup(
                  children: [
                    FormFieldBlock(
                      key: _fieldKeys[_F.baseUrl],
                      error: _errors[_F.baseUrl],
                      label: 'Base URL',
                      helper: _errors[_F.baseUrl] == null ? _baseUrlNote : null,
                      child: TextField(
                        controller: _baseUrl,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        // Android adds a password variation when suggestions are disabled.
                        enableSuggestions: true,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) {
                          if (_baseUrlNote != null) setState(() => _baseUrlNote = null);
                          _edited(_F.baseUrl);
                        },
                        decoration: InputDecoration(
                          hintText: anthropic ? 'https://api.example.com' : 'https://api.example.com/v1',
                          error: _errors[_F.baseUrl] == null ? null : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    FormFieldBlock(
                      key: _fieldKeys[_F.key],
                      error: _errors[_F.key],
                      label: 'API Key',
                      helper: _errors[_F.key] == null && keyStored ? l10n.engineProviderKeepStoredKey : null,
                      trailing: FormSmallButton(label: l10n.commonPaste, onPressed: busy ? null : _paste),
                      child: TextField(
                        controller: _key,
                        obscureText: _obscure,
                        obscuringCharacter: '•',
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        keyboardType: TextInputType.visiblePassword,
                        onChanged: (_) => _edited(_F.key),
                        decoration: InputDecoration(
                          hintText: keyStored ? '••••••••' : 'sk-…',
                          error: _errors[_F.key] == null ? null : const SizedBox.shrink(),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? l10n.engineFieldShow : l10n.commonHide,
                            icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SettingsSection(
              children: [
                SettingsTile(
                  key: _fieldKeys[_F.headers],
                  title: l10n.engineProviderHeaders,
                  trailing: Icon(_headersOpen ? AppIcons.collapse : AppIcons.expand, size: 18),
                  onTap: () => setState(() => _headersOpen = !_headersOpen),
                ),
                ExpandReveal(
                  open: _headersOpen,
                  child: FormFieldGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          l10n.engineProviderHeadersWarning,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ),
                      if (_errors[_F.headers] case final error?)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                        ),
                      for (final (index, header) in _headers.indexed)
                        Column(
                          key: header.key,
                          children: [
                            FormFieldBlock(
                              label: l10n.engineProviderHeaderName,
                              helper: header.locked ? l10n.engineProviderHeaderLocked : null,
                              trailing: FormSmallButton(
                                label: l10n.commonDelete,
                                onPressed: _saving || header.locked
                                    ? null
                                    : () => _editHeaders(() => _headers.remove(header)),
                              ),
                              child: TextFormField(
                                key: ValueKey('provider-header-name-$index'),
                                initialValue: header.name,
                                enabled: !_saving,
                                readOnly: header.locked,
                                autocorrect: false,
                                enableSuggestions: true,
                                textInputAction: TextInputAction.next,
                                onChanged: header.locked ? null : (value) => _editHeaders(() => header.name = value),
                                decoration: const InputDecoration(hintText: 'x-opencode-session'),
                              ),
                            ),
                            FormFieldBlock(
                              label: l10n.engineProviderHeaderValue,
                              child: TextFormField(
                                key: ValueKey('provider-header-value-$index'),
                                initialValue: header.value,
                                enabled: !_saving,
                                readOnly: header.locked,
                                autocorrect: false,
                                enableSuggestions: true,
                                textInputAction: TextInputAction.next,
                                onChanged: header.locked ? null : (value) => _editHeaders(() => header.value = value),
                              ),
                            ),
                          ],
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _saving ? null : () => _editHeaders(() => _headers.add(_HeaderDraft('', ''))),
                            icon: const Icon(AppIcons.add, size: 18),
                            label: Text(l10n.engineProviderHeaderAdd),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              key: _fieldKeys[_F.models],
              padding: kSettingsGroupMargin,
              child: _ModelsCard(
                models: _models,
                defaults: _editing?.defaults ?? const ModelDefaults(),
                discovering: _discovering,
                onDiscover: backend == null || busy ? null : _discover,
                onAdd: busy ? null : _addByHand,
                onOpen: busy ? null : _editModel,
                onRemove: busy ? null : _remove,
                message: modelsMessage,
              ),
            ),
            SmoothSize(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.std,
              alignment: Alignment.topCenter,
              child: _formError == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      child: Text(_formError!, style: theme.textTheme.bodySmall?.copyWith(color: colors.danger)),
                    ),
            ),
            const SizedBox(height: FormBottomBar.height),
          ],
        ),
      ],
    );

    return DiscardGuard(
      listenable: _edits,
      isDirty: () => !_saving && _signature() != _clean,
      child: Stack(
        children: [
          page,
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.viewInsetsOf(context).bottom,
            child: FormBottomBar(
              child: FilledButton(
                onPressed: backend == null || busy ? null : _save,
                child: _saving
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          ),
                          const SizedBox(width: 10),
                          Text(l10n.engineProviderSaving),
                        ],
                      )
                    : Text(backend == null ? l10n.engineProviderWaitingEngine : l10n.commonSave),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「模型」: the fetch action, the chosen models (each opens its settings),
/// 「手动添加」; discovery's outcome right under the card.
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({
    required this.models,
    required this.defaults,
    required this.discovering,
    required this.onDiscover,
    required this.onAdd,
    required this.onOpen,
    required this.onRemove,
    this.message,
  });

  final List<ProviderModelSpec> models;
  final ModelDefaults defaults;
  final bool discovering;
  final VoidCallback? onDiscover;
  final VoidCallback? onAdd;
  final ValueChanged<ProviderModelSpec>? onOpen;
  final ValueChanged<ProviderModelSpec>? onRemove;

  /// An error (danger colour).
  final String? message;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    return SettingsSection(
      title: models.isEmpty ? l10n.engineModelTitle : l10n.engineProviderModelCount(models.length),
      margin: EdgeInsets.zero,
      footer: message == null ? null : Text(message!, style: TextStyle(color: colors.danger)),
      children: [
        SettingsTile(
          icon: AppIcons.fetchModels,
          tinted: false,
          title: discovering ? l10n.engineProviderFetchingModels : l10n.engineProviderFetchModels,
          chevron: false,
          trailing: discovering
              ? Padding(
                  padding: const EdgeInsets.only(right: SettingsMetrics.inset - SettingsMetrics.trailingPad),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: colors.textTertiary),
                  ),
                )
              : null,
          onTap: onDiscover,
        ),
        for (final model in models)
          _ModelRow(
            model: model,
            defaults: defaults,
            onTap: onOpen == null ? null : () => onOpen!(model),
            onRemove: onRemove == null ? null : () => onRemove!(model),
          ),
        SettingsTile(
          icon: AppIcons.add,
          tinted: false,
          title: l10n.engineProviderAddManually,
          chevron: false,
          onTap: onAdd,
        ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.defaults, required this.onTap, required this.onRemove});

  final ProviderModelSpec model;
  final ModelDefaults defaults;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final subtitle = modelSummary(context, model, defaults: defaults);
    return SettingsTile(
      icon: AppIcons.modelItem,
      tinted: false,
      title: model.label,
      subtitle: subtitle.isEmpty ? null : subtitle,
      onTap: onTap,
      // The glyph's ink ends 16 from the card edge, like a chevron's.
      trailing: Transform.translate(
        offset: const Offset(SettingsMetrics.trailingPad + 10 - SettingsMetrics.inset, 0),
        child: IconButton(
          tooltip: l10n.engineFieldRemoveItem(model.id),
          visualDensity: VisualDensity.compact,
          color: colors.textTertiary,
          icon: const Icon(AppIcons.close, size: 20),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

class _ManualModelDialog extends StatefulWidget {
  const _ManualModelDialog({required this.taken});

  final Set<String> taken;

  @override
  State<_ManualModelDialog> createState() => _ManualModelDialogState();
}

class _ManualModelDialogState extends State<_ManualModelDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = modelIdError(_controller.text, widget.taken);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.engineProviderManualModel),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(hintText: l10n.engineProviderModelId, errorText: _error),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l10n.commonAdd)),
      ],
    );
  }
}

// ── Model picker ─────────────────────────────────────────────────────────────

/// The models an endpoint listed, to tick and add. Models already in the form
/// show ticked and can't be unticked here. A short list starts all ticked; a
/// long one (a gateway with hundreds) starts empty, with a search field.
Future<List<DiscoveredModel>?> showModelPicker(
  BuildContext context, {
  required List<DiscoveredModel> candidates,
  required Set<String> added,
}) => showAppSheet<List<DiscoveredModel>>(
  context,
  dismissal: SheetDismissal.button,
  isScrollControlled: true,
  builder: (_) => ModelPickerSheet(candidates: candidates, added: added),
);

class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({super.key, required this.candidates, required this.added});

  final List<DiscoveredModel> candidates;
  final Set<String> added;

  /// Up to this many start ticked; more get a search field.
  static const shortList = 8;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  late final Set<String> _picked = widget.candidates.length <= ModelPickerSheet.shortList
      ? {
          for (final m in widget.candidates)
            if (!widget.added.contains(m.id)) m.id,
        }
      : {};
  String _query = '';

  List<DiscoveredModel> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return [
      for (final m in widget.candidates)
        if (m.id.toLowerCase().contains(q) || (m.name?.toLowerCase().contains(q) ?? false)) m,
    ];
  }

  void _toggle(String id) => setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    const inset = SheetTitleBar.inset;
    final visible = _visible;
    final selectable = [
      for (final m in visible)
        if (!widget.added.contains(m.id)) m.id,
    ];
    final allPicked = selectable.isNotEmpty && selectable.every(_picked.contains);
    final maxList = MediaQuery.sizeOf(context).height * 0.5;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.engineProviderSelectModels),
            if (widget.candidates.length > ModelPickerSheet.shortList)
              Padding(
                padding: const EdgeInsets.fromLTRB(inset, 0, inset, 8),
                child: TextField(
                  autocorrect: false,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: l10n.engineProviderSearchModels,
                    prefixIcon: const Icon(AppIcons.search, size: 20),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(inset, 0, inset - 6, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.engineProviderCandidateCount(widget.candidates.length),
                      style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                  FormSmallButton(
                    label: allPicked ? l10n.engineProviderDeselectAll : l10n.engineProviderSelectAll,
                    onPressed: selectable.isEmpty
                        ? null
                        : () => setState(() => allPicked ? _picked.removeAll(selectable) : _picked.addAll(selectable)),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxList),
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        l10n.engineProviderNoMatchingModels,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: inset - SettingsMetrics.inset + 4),
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final m = visible[i];
                        final added = widget.added.contains(m.id);
                        return _CandidateRow(
                          model: m,
                          checked: added || _picked.contains(m.id),
                          added: added,
                          onTap: added ? null : () => _toggle(m.id),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(inset, 12, inset, 12),
              child: FilledButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => Navigator.of(context).pop([
                        for (final m in widget.candidates)
                          if (_picked.contains(m.id)) m,
                      ]),
                child: Text(_picked.isEmpty ? l10n.commonAdd : l10n.engineProviderAddModels(_picked.length)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.model, required this.checked, required this.added, required this.onTap});

  final DiscoveredModel model;
  final bool checked;
  final bool added;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final subtitle = [
      if (model.name != null && model.name != model.id) model.name!,
      if (model.contextWindow case final c?) l10n.engineProviderContext(formatTokens(c)),
    ].join(' · ');
    return Semantics(
      checked: checked,
      enabled: onTap != null,
      label: model.id,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShape.radiusMd,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: subtitle.isEmpty ? 52 : 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SelectionTick(checked: checked, dimmed: added),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        model.id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: settingsTitleStyle(context)
                            ?.copyWith(color: added ? colors.textTertiary : theme.colorScheme.onSurface),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ],
                  ),
                ),
                if (added) ...[
                  const SizedBox(width: 12),
                  Text(
                    l10n.engineProviderAlreadyAdded,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
