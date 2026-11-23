// 她的声音: whether she speaks, and in whose voice. The same as 朗读's (设置 ›
// 语音); DeepSeek's; the phone's own; an OpenAI-compatible speech API; or any
// HTTP API the person describes (companion_voice_source.dart). Fields save as
// they are edited; 试听 says a line with what is filled in now.
//
// With [CompanionVoicePage.shared] it is 设置 › 语音 › 朗读的声音 instead: the
// voice replies are read aloud in and 语音通话 speaks with — no switch, no
// following, no cloned voice.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../speech/deepseek_speech.dart';
import '../../speech/speech_settings.dart';
import '../../state/account_state.dart';
import '../../state/android_features.dart' show operatingSystemProvider;
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/semantic_colors.dart';

class CompanionVoicePage extends ConsumerStatefulWidget {
  const CompanionVoicePage({super.key, this.shared = false});

  /// 朗读的声音 (the app's), not hers.
  final bool shared;

  @override
  ConsumerState<CompanionVoicePage> createState() => _CompanionVoicePageState();
}

class _CompanionVoicePageState extends ConsumerState<CompanionVoicePage> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _voice = TextEditingController();
  final _url = TextEditingController();
  final _headers = TextEditingController();
  final _body = TextEditingController();
  final _field = TextEditingController();
  final _presetKey = TextEditingController();
  final _presetVoice = TextEditingController();
  final _presetStyle = TextEditingController();
  bool _filled = false;

  // Held from the start: edits still waiting are saved as the page closes,
  // when it can no longer read providers.
  late final VoiceOutputSettingsController _store = widget.shared
      ? ref.read(speechVoiceSettingsProvider.notifier)
      : ref.read(companionVoiceSettingsProvider.notifier);

  CompanionVoiceSettings? _watch() =>
      widget.shared ? ref.watch(speechVoiceSettingsProvider) : ref.watch(companionVoiceSettingsProvider);

  CompanionSpeaker get _speaker => ref.read(widget.shared ? speechSpeakerProvider : companionSpeakerProvider);

  /// What actually speaks: hers may be 朗读's.
  CompanionVoiceSettings _speaking(CompanionVoiceSettings s) {
    if (widget.shared) return s;
    if (ref.read(operatingSystemProvider) == 'ohos') {
      return s.copyWith(source: CompanionVoiceSource.system, follow: false, cloneOn: false);
    }
    if (!s.follow) return s;
    final shared = ref.read(speechVoiceSettingsProvider);
    return (shared ?? const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek)).copyWith(on: s.on);
  }

  CompanionVoiceSettings? _seen;

  @override
  void initState() {
    super.initState();
    _store; // Bind now, not on first use.
  }

  bool _obscure = true;
  Timer? _saveTimer;

  /// 试听: null idle, '' requesting, 'ok', or why it failed.
  String? _preview;

  // The recording to clone from: what it is, picking one, why that failed.
  String? _recording;
  String? _recordingFor;
  bool _picking = false;
  String? _recordingError;

  List<TextEditingController> get _all => [
    _base,
    _key,
    _model,
    _voice,
    _url,
    _headers,
    _body,
    _field,
    _presetKey,
    _presetVoice,
    _presetStyle,
  ];

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Providers can't change while the tree is being torn down: right after.
    final pending = _pending();
    if (pending != null) scheduleMicrotask(() => unawaited(_store.update(pending)));
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(CompanionVoiceSettings s) {
    if (_filled) return;
    _filled = true;
    _base.text = s.openaiBase;
    _key.text = s.openaiKey;
    _model.text = s.openaiModel;
    _voice.text = s.openaiVoice;
    _url.text = s.customUrl;
    _headers.text = s.customHeaders;
    _body.text = s.customBody;
    _field.text = s.customField;
    _presetKey.text = s.presetKey;
    _presetVoice.text = s.presetVoice;
    _presetStyle.text = s.presetStyle;
  }

  CompanionVoiceSettings _fromFields(CompanionVoiceSettings s) => s.copyWith(
    presetKeys: {...s.presetKeys, s.preset: _presetKey.text.trim()},
    presetVoices: {...s.presetVoices, s.preset: _presetVoice.text.trim()}..removeWhere((_, voice) => voice.isEmpty),
    presetStyle: _presetStyle.text.trim(),
    openaiBase: _base.text.trim(),
    openaiKey: _key.text.trim(),
    openaiModel: _model.text.trim(),
    openaiVoice: _voice.text.trim(),
    customUrl: _url.text.trim(),
    customHeaders: _headers.text,
    customBody: _body.text,
    customField: _field.text.trim(),
  );

  void _edited() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _flush);
    if (_preview != null && _preview != '') setState(() => _preview = null);
  }

  /// The settings as the fields have them, when they differ from what is saved.
  CompanionVoiceSettings? _pending() {
    final s = _seen;
    if (s == null || !_filled) return null;
    final next = _fromFields(s);
    final changed =
        next.plain().toString() != s.plain().toString() ||
        next.openaiKey != s.openaiKey ||
        next.customHeaders != s.customHeaders ||
        next.presetKeys.toString() != s.presetKeys.toString();
    return changed ? next : null;
  }

  void _flush() {
    _saveTimer?.cancel();
    final next = _pending();
    if (next == null) return;
    _seen = next;
    unawaited(_store.update(next));
  }

  /// Another service: what is typed so far stays with the one before, and the
  /// fields show what this one has.
  Future<void> _choosePreset(CompanionVoiceSettings s, String id) async {
    final merged = _fromFields(s);
    final next = merged.copyWith(preset: id);
    _seen = next;
    _presetKey.text = next.presetKey;
    _presetVoice.text = next.presetVoice;
    setState(() => _preview = null);
    await _store.update(next);
  }

  /// Size and, for WAV, length of the kept recording, for its row.
  Future<void> _describe(String path) async {
    _recordingFor = path;
    String? text;
    try {
      final file = File(path);
      final size = await file.length();
      final head = await file.openRead(0, 44).fold<List<int>>([], (all, part) => all..addAll(part));
      final length = companionRecordingLength(Uint8List.fromList(head), size);
      if (!mounted) return;
      final l10n = context.l10n;
      text = [
        '${(size / 1024).round()} KB',
        if (length != null) l10n.companionCloneSeconds(length.inSeconds),
      ].join(' · ');
    } on FileSystemException {
      text = null;
    }
    if (mounted) setState(() => _recording = text);
  }

  Future<void> _pickRecording() async {
    final l10n = context.l10n;
    setState(() {
      _picking = true;
      _recordingError = null;
    });
    try {
      final picked = await ref.read(companionVoicePickerProvider)();
      if (picked == null || !mounted) return;
      final (bytes, size) = picked;
      if (size != null && size > companionCloneMaxBytes) throw const CompanionVoiceError('too-large');
      final folder = await ref.read(companionVoiceSampleFolderProvider)();
      final file = await companionKeepRecording(bytes, folder);
      if (!mounted) return;
      await _set(ref.read(companionVoiceSettingsProvider)!.copyWith(cloneSample: file.path));
      await _describe(file.path);
      if (mounted) setState(() => _preview = null);
    } on CompanionVoiceError catch (error) {
      if (mounted) {
        setState(
          () => _recordingError = switch (error.reason) {
            'too-large' => l10n.companionCloneTooLarge,
            'not-audio' => l10n.companionCloneNotAudio,
            _ => l10n.companionCloneFailed,
          },
        );
      }
    } on Object {
      if (mounted) setState(() => _recordingError = l10n.companionCloneFailed);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _set(CompanionVoiceSettings next) async {
    final merged = _fromFields(next);
    _seen = merged;
    await _store.update(merged);
  }

  Future<void> _turn(CompanionVoiceSettings s, bool on) async {
    if (!on) {
      _speaker.stop();
      await _set(s.copyWith(on: false));
      return;
    }
    // On only with a voice that can be heard: she says hello in it.
    final next = _fromFields(s).copyWith(on: true);
    setState(() => _preview = '');
    final why = await _speaker.preview(_speaking(next), context.l10n.companionVoiceHello);
    if (!mounted) return;
    setState(() => _preview = why ?? 'ok');
    if (why == null) await _set(next);
  }

  Future<void> _try(CompanionVoiceSettings s) async {
    _flush();
    setState(() => _preview = '');
    final hello = widget.shared ? context.l10n.speechVoiceHello : context.l10n.companionVoiceHello;
    final why = await _speaker.preview(_speaking(_fromFields(s)), hello);
    if (mounted) setState(() => _preview = why ?? 'ok');
  }

  String _why(String reason) {
    final l10n = context.l10n;
    return switch (reason) {
      'no-phone-voice' => l10n.companionVoiceUnavailable,
      'not-set-up' => l10n.companionVoiceNotSetUp,
      'no-deepseek' => ref.read(accountProvider).signedIn ? l10n.speechAccountUnusable : l10n.speechNoCredential,
      _ when reason.startsWith('deepseek ') => switch (reason.split(' ')[1]) {
        'noCredential' => l10n.speechNoCredential,
        'accountUnusable' => l10n.speechAccountUnusable,
        'signIn' => l10n.speechSignIn,
        'unauthorized' => l10n.speechUnauthorized,
        'insufficientBalance' => l10n.speechBalance,
        'rateLimited' => l10n.speechRateLimited,
        'busy' => l10n.speechBusy,
        'network' => l10n.speechNetwork,
        _ => l10n.companionVoicePreviewFailed(reason),
      },
      _ => l10n.companionVoicePreviewFailed(reason),
    };
  }

  Widget _text(
    TextEditingController controller, {
    String? hint,
    bool url = false,
    bool secret = false,
    int lines = 1,
  }) => TextField(
    controller: controller,
    onChanged: (_) => _edited(),
    onEditingComplete: _flush,
    minLines: lines,
    maxLines: secret ? 1 : (lines == 1 ? 1 : lines + 3),
    obscureText: secret && _obscure,
    obscuringCharacter: '•',
    autocorrect: false,
    enableSuggestions: !secret,
    enableIMEPersonalizedLearning: !secret,
    keyboardType: secret
        ? TextInputType.visiblePassword
        : url
        ? TextInputType.url
        : (lines > 1 ? TextInputType.multiline : TextInputType.text),
    style: lines > 1 ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
    decoration: InputDecoration(
      hintText: hint,
      suffixIcon: secret
          ? IconButton(
              tooltip: _obscure ? context.l10n.engineFieldShow : context.l10n.commonHide,
              icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
              onPressed: () => setState(() => _obscure = !_obscure),
            )
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final title = widget.shared ? l10n.speechVoiceTitle : l10n.companionMenuVoice;
    final s = _seen = _watch();
    if (s == null) return AppPage.list(title: title, children: const []);
    // HarmonyOS plays DeepSeek's stream for 朗读 and its own voice everywhere; the
    // others have no player there yet, and her room has only the phone's voice
    // (companionEffectiveVoiceProvider).
    final ohos = ref.watch(operatingSystemProvider) == 'ohos';
    final room = ohos && !widget.shared;
    final following = !room && !widget.shared && s.follow;
    final chosen = room ? CompanionVoiceSource.system : s.source;
    _fill(s);
    if (s.cloneSample.isNotEmpty && _recordingFor != s.cloneSample) unawaited(_describe(s.cloneSample));
    final busy = _preview == '';
    final status = switch (_preview) {
      null => null,
      '' => Text(l10n.companionVoicePreviewing, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
      'ok' => Text(
        l10n.companionVoicePreviewOk,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
      ),
      final reason => Text(_why(reason), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
    };

    return AppPage.list(
      title: title,
      children: [
        if (!widget.shared)
          SettingsSection(
            footer: s.on ? null : Text(l10n.companionVoiceOffHint),
            children: [
              SettingsSwitchTile(
                icon: AppIcons.companionVoice,
                tinted: false,
                title: l10n.companionVoiceOn,
                value: s.on,
                onChanged: busy ? null : (on) => unawaited(_turn(s, on)),
              ),
            ],
          ),
        SettingsSection(
          title: l10n.companionVoiceSource,
          children: [
            if (!widget.shared && !room)
              SettingsTile(
                key: const ValueKey('voice-source-follow'),
                title: l10n.speechVoiceFollow,
                subtitle: l10n.speechVoiceFollowHint,
                chevron: false,
                trailing: following ? const Icon(AppIcons.selected, size: 20) : null,
                onTap: () {
                  setState(() => _preview = null);
                  unawaited(_set(s.copyWith(follow: true)));
                },
              ),
            for (final (source, title, hint) in [
              if (!room) (CompanionVoiceSource.deepseek, l10n.speechVoiceDeepseek, l10n.speechVoiceDeepseekHint),
              (CompanionVoiceSource.system, l10n.companionVoiceSystem, l10n.companionVoiceSystemHint),
              if (!ohos) ...[
                (CompanionVoiceSource.preset, l10n.companionVoicePreset, l10n.companionVoicePresetHint),
                (CompanionVoiceSource.openai, l10n.companionVoiceOpenai, l10n.companionVoiceOpenaiHint),
                (CompanionVoiceSource.custom, l10n.companionVoiceCustom, l10n.companionVoiceCustomHint),
              ],
            ])
              SettingsTile(
                title: title,
                subtitle: hint,
                chevron: false,
                key: ValueKey('voice-source-${source.name}'),
                trailing: !following && chosen == source ? const Icon(AppIcons.selected, size: 20) : null,
                onTap: () {
                  setState(() => _preview = null);
                  unawaited(_set(s.copyWith(source: source, follow: false)));
                },
              ),
          ],
        ),
        if (!following && chosen == CompanionVoiceSource.deepseek)
          SettingsSection(
            title: l10n.companionVoiceVoice,
            footer: Text(l10n.speechVoiceDeepseekFooter),
            children: [
              for (final voice in deepSeekVoices)
                SettingsTile(
                  key: ValueKey('voice-deepseek-$voice'),
                  title: switch (voice) {
                    'tide' => l10n.speechVoiceTide,
                    _ => l10n.speechVoiceStella,
                  },
                  chevron: false,
                  trailing: s.deepseekVoice == voice ? const Icon(AppIcons.selected, size: 20) : null,
                  onTap: () {
                    setState(() => _preview = null);
                    unawaited(_set(s.copyWith(deepseekVoice: voice)));
                  },
                ),
            ],
          ),
        if (!following && chosen == CompanionVoiceSource.preset) ...[
          SettingsSection(
            title: l10n.companionVoiceService,
            children: [
              for (final preset in companionVoicePresets)
                SettingsTile(
                  title: preset.name,
                  subtitle: preset.site,
                  chevron: false,
                  trailing: s.preset == preset.id ? const Icon(AppIcons.selected, size: 20) : null,
                  onTap: () => unawaited(_choosePreset(s, preset.id)),
                ),
            ],
          ),
          SettingsSection(
            footer: Text(l10n.companionVoicePrivacy),
            children: [
              FormFieldGroup(
                children: [
                  FormFieldBlock(
                    label: 'API Key',
                    helper: l10n.companionVoiceKeyWhere(s.presetInfo.site),
                    child: _text(_presetKey, hint: 'sk-…', secret: true),
                  ),
                  if (s.presetInfo.clones && !widget.shared)
                    FormFieldBlock(
                      label: l10n.companionVoiceVoice,
                      child: SegmentedPill<bool>(
                        segments: [
                          PillSegment(false, l10n.companionClonePreset),
                          PillSegment(true, l10n.companionCloneMine),
                        ],
                        selected: s.cloneOn,
                        onChanged: (on) {
                          setState(() => _preview = null);
                          unawaited(_set(s.copyWith(cloneOn: on)));
                        },
                      ),
                    ),
                  if (s.cloning && !widget.shared)
                    FormFieldBlock(
                      label: l10n.companionCloneRecording,
                      helper: _recordingError == null ? l10n.companionCloneHelper : null,
                      error: _recordingError,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.cloneSample.isEmpty
                                  ? l10n.companionCloneNone
                                  : l10n.companionCloneReady(_recording ?? '…'),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.tonal(
                            onPressed: _picking ? null : () => unawaited(_pickRecording()),
                            child: Text(s.cloneSample.isEmpty ? l10n.companionClonePick : l10n.companionCloneReplace),
                          ),
                        ],
                      ),
                    )
                  else
                    FormFieldBlock(
                      label: s.presetInfo.clones ? l10n.companionVoicePresetVoice : l10n.companionVoiceVoice,
                      helper: l10n.companionVoiceVoiceCustomHelper,
                      below: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final voice in s.presetInfo.voices)
                            ChoiceChip(
                              label: Text(switch (voice.kind) {
                                'f' => '${voice.id} · ${l10n.companionVoiceFemale}',
                                'm' => '${voice.id} · ${l10n.companionVoiceMale}',
                                _ => voice.id,
                              }),
                              selected: _presetVoice.text.trim() == voice.id,
                              onSelected: (_) {
                                setState(() => _presetVoice.text = voice.id);
                                _edited();
                              },
                            ),
                        ],
                      ),
                      child: _text(_presetVoice, hint: s.presetInfo.voices.first.id),
                    ),
                  if (s.presetInfo.styled)
                    FormFieldBlock(
                      label: l10n.companionVoiceStyle,
                      helper: l10n.companionVoiceStyleHelper,
                      child: _text(_presetStyle, hint: companionVoiceStyleDefault, lines: 2),
                    ),
                ],
              ),
            ],
          ),
        ],
        if (!following && chosen == CompanionVoiceSource.openai)
          SettingsSection(
            title: l10n.companionVoiceApi,
            footer: Text(l10n.companionVoicePrivacy),
            children: [
              FormFieldGroup(
                children: [
                  FormFieldBlock(
                    label: l10n.companionVoiceBase,
                    helper: l10n.companionVoiceBaseHelper,
                    child: _text(_base, hint: 'https://api.openai.com/v1', url: true),
                  ),
                  FormFieldBlock(
                    label: 'API Key',
                    helper: l10n.companionVoiceKeyHelper,
                    child: _text(_key, hint: 'sk-…', secret: true),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceModel,
                    child: _text(_model, hint: 'gpt-4o-mini-tts'),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceVoice,
                    helper: l10n.companionVoiceVoiceHelper,
                    child: _text(_voice, hint: 'alloy'),
                  ),
                ],
              ),
            ],
          ),
        if (!following && chosen == CompanionVoiceSource.custom)
          SettingsSection(
            title: l10n.companionVoiceRequest,
            footer: Text(l10n.companionVoicePrivacy),
            children: [
              FormFieldGroup(
                children: [
                  FormFieldBlock(
                    label: l10n.companionVoiceUrl,
                    helper: l10n.companionVoiceUrlHelper,
                    child: _text(_url, hint: 'https://tts.example.com/speak', url: true),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceMethod,
                    child: SegmentedPill<bool>(
                      segments: const [PillSegment(true, 'POST'), PillSegment(false, 'GET')],
                      selected: s.customPost,
                      onChanged: (post) => unawaited(_set(s.copyWith(customPost: post))),
                    ),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceHeaders,
                    helper: l10n.companionVoiceHeadersHelper,
                    child: _text(_headers, hint: 'Authorization: Bearer sk-…', lines: 2),
                  ),
                  if (s.customPost)
                    FormFieldBlock(
                      label: l10n.companionVoiceBody,
                      helper: l10n.companionVoiceBodyHelper,
                      child: _text(_body, hint: '{"text": "{text}"}', lines: 3),
                    ),
                  FormFieldBlock(
                    label: l10n.companionVoiceField,
                    helper: l10n.companionVoiceFieldHelper,
                    child: _text(_field, hint: 'data.audio'),
                  ),
                ],
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset + 8, 4, SettingsMetrics.inset + 8, 24),
          child: Row(
            children: [
              FilledButton.tonal(
                onPressed: busy ? null : () => unawaited(_try(s)),
                child: Text(l10n.companionVoicePreview),
              ),
              const SizedBox(width: 12),
              if (status != null) Expanded(child: status),
            ],
          ),
        ),
      ],
    );
  }
}
