// What a call shows behind its light (CallBackdrop): deep water (always drawn,
// the others sit on it), the person's own picture softened and darkened so the
// words stay readable, or her — 伙伴小屋's character, alone on the water,
// mouthing the call's voice. Chosen from the call page's 背景 key or 设置 › 语音.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../companion/companion_float.dart';
import '../../../companion/companion_pack.dart';
import '../../../companion/companion_state.dart';
import '../../../l10n/l10n.dart';
import '../../../speech/speech_audio.dart';
import '../../../speech/speech_settings.dart';
import '../../../state/voice_settings.dart';
import '../../common/app_sheet.dart';
import '../../companion/companion_stage.dart';
import '../../companion/companion_voice_page.dart';
import '../../settings/settings_widgets.dart';
import '../../settings/voice_settings_page.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

/// The largest picture kept for a backdrop.
const _maxBytes = 30 * 1024 * 1024;

/// Where a picked picture is kept, replacing the one before. Null when cancelled.
final callBackdropPickerProvider = Provider<Future<String?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile(type: FileType.image);
    if (picked == null) return null;
    final size = picked.lengthSync();
    if (size != null && size > _maxBytes) throw const FileSystemException('too large');
    final folder = Directory('${(await getApplicationSupportDirectory()).path}/call');
    await folder.create(recursive: true);
    final ext = (picked.extension ?? 'jpg').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    // A new name each time: the image cache never shows the old one.
    final file = File('${folder.path}/backdrop-${DateTime.now().millisecondsSinceEpoch}.$ext');
    final sink = file.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    await for (final old in folder.list()) {
      if (old is File && old.path != file.path && old.uri.pathSegments.last.startsWith('backdrop-')) {
        await old.delete().catchError((Object _) => old);
      }
    }
    return file.path;
  },
);

/// Her pack is there to be shown (null: yes; otherwise why not).
bool companionReady(AsyncValue<String?> availability) =>
    availability is AsyncData<String?> && availability.value == null;

// ── Layers ─────────────────────────────────────────────────────────────────

/// The person's picture: covering, softened, darkened toward the bottom.
class ImageBackdrop extends StatelessWidget {
  const ImageBackdrop({super.key, required this.path, required this.blur});

  final String path;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final image = Image.file(
      File(path),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (blur)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.clamp),
            child: image,
          )
        else
          image,
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x99040814), Color(0x66040814), Color(0xE6040814)],
              stops: [0, 0.45, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Her, on the water, without her room. [controller] takes the call's mood
/// and mouth; [onFailed] when she can't be shown (the call falls back to the water).
class CompanionBackdrop extends ConsumerStatefulWidget {
  const CompanionBackdrop({super.key, required this.controller, required this.onReady, required this.onFailed});

  final CompanionStageController controller;
  final VoidCallback onReady;
  final VoidCallback onFailed;

  @override
  ConsumerState<CompanionBackdrop> createState() => _CompanionBackdropState();
}

class _CompanionBackdropState extends ConsumerState<CompanionBackdrop> {
  CompanionPackStore? _store;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final store = await ref.read(companionFloatStoreProvider)();
      if (!await store.installed()) {
        widget.onFailed();
        return;
      }
      if (mounted) setState(() => _store = store);
    } catch (_) {
      widget.onFailed();
    }
  }

  late final _events = CompanionStageEvents(
    onReady: () {
      if (!mounted) return;
      setState(() => _ready = true);
      widget.onReady();
    },
    onFailed: (_) => widget.onFailed(),
    onTouch: (_, _) {},
    onWake: () {},
    onMood: (_) {},
    onObject: (_) {},
    onActivity: (_) {},
  );

  @override
  Widget build(BuildContext context) {
    final store = _store;
    if (store == null) return const SizedBox.expand();
    return AnimatedOpacity(
      opacity: _ready ? 1 : 0,
      duration: AppMotion.of(context, AppMotion.slow),
      curve: AppMotion.enter,
      child: IgnorePointer(
        child: CompanionStage(store: store, controller: widget.controller, events: _events, bare: true),
      ),
    );
  }
}

// ── Choosing ───────────────────────────────────────────────────────────────

/// The three backdrops side by side; picking one applies it at once.
/// [inCall]: opened from a call, which also offers her voice and the
/// recognition; [beforeVoice] runs before her voice's page opens.
Future<void> showCallBackdropSheet(BuildContext context, {bool inCall = false, VoidCallback? beforeVoice}) =>
    showAppSheet<void>(
      context,
      isScrollControlled: true,
      // Scrolls on a short screen (a phone on its side): the in-call rows are below the fold there.
      builder: (sheet) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: _BackdropChooser(inCall: inCall, beforeVoice: beforeVoice),
        ),
      ),
    );

class _BackdropChooser extends ConsumerStatefulWidget {
  const _BackdropChooser({required this.inCall, this.beforeVoice});

  final bool inCall;
  final VoidCallback? beforeVoice;

  @override
  ConsumerState<_BackdropChooser> createState() => _BackdropChooserState();
}

class _BackdropChooserState extends ConsumerState<_BackdropChooser> {
  bool _picking = false;
  String? _error;

  Future<void> _set(CallSettings next) => ref.read(callSettingsProvider.notifier).update(next);

  Future<void> _pick(CallSettings now) async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final path = await ref.read(callBackdropPickerProvider)();
      if (path != null) await _set(ref.read(callSettingsProvider).copyWith(backdrop: CallBackdrop.image, image: path));
    } on Object {
      if (mounted) setState(() => _error = context.l10n.speechBackdropPickFailed);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final settings = ref.watch(callSettingsProvider);
    final her = companionReady(ref.watch(companionFloatAvailabilityProvider));
    final name = ref.watch(companionNameProvider);
    final hasImage = settings.image.isNotEmpty && File(settings.image).existsSync();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.inCall ? l10n.speechCallSettings : l10n.speechBackdropTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: _Card(
                  key: const ValueKey('backdrop-sea'),
                  label: l10n.speechBackdropSea,
                  selected: settings.backdrop == CallBackdrop.sea,
                  onTap: () => unawaited(_set(settings.copyWith(backdrop: CallBackdrop.sea))),
                  preview: const _SeaSwatch(),
                ),
              ),
              Expanded(
                child: _Card(
                  key: const ValueKey('backdrop-image'),
                  label: hasImage ? l10n.speechBackdropImage : l10n.speechBackdropImagePick,
                  selected: settings.backdrop == CallBackdrop.image && hasImage,
                  busy: _picking,
                  onTap: _picking
                      ? null
                      : hasImage && settings.backdrop != CallBackdrop.image
                      ? () => unawaited(_set(settings.copyWith(backdrop: CallBackdrop.image)))
                      : () => unawaited(_pick(settings)),
                  preview: hasImage
                      ? Image.file(File(settings.image), fit: BoxFit.cover, gaplessPlayback: true)
                      : const _Placeholder(icon: AppIcons.addImage),
                ),
              ),
              Expanded(
                child: _Card(
                  key: const ValueKey('backdrop-companion'),
                  label: (name ?? '').trim().isEmpty ? l10n.speechBackdropCompanion : name!.trim(),
                  selected: settings.backdrop == CallBackdrop.companion,
                  onTap: her ? () => unawaited(_set(settings.copyWith(backdrop: CallBackdrop.companion))) : null,
                  preview: const _Placeholder(icon: AppIcons.companionVoice),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _error ??
                (her
                    ? (hasImage ? l10n.speechBackdropHintChange : l10n.speechBackdropHint)
                    : l10n.speechBackdropNoCompanion),
            style: theme.textTheme.bodySmall?.copyWith(
              color: _error != null ? theme.colorScheme.error : DshColors.of(context).textTertiary,
            ),
          ),
          if (hasImage && settings.backdrop == CallBackdrop.image) ...[
            const SizedBox(height: 4),
            TextButton(
              key: const ValueKey('backdrop-replace'),
              onPressed: _picking ? null : () => unawaited(_pick(settings)),
              child: Text(l10n.speechBackdropReplace),
            ),
          ],
          const SizedBox(height: 20),
          Text(l10n.speechCallVisual, style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          SegmentedPill<CallVisual>(
            key: const ValueKey('call-visual'),
            segments: [
              PillSegment(CallVisual.glass, l10n.speechCallVisualGlass),
              PillSegment(CallVisual.ring, l10n.speechCallVisualRing),
              PillSegment(CallVisual.mono, l10n.speechCallVisualMono),
            ],
            selected: settings.visual,
            onChanged: (visual) => unawaited(_set(settings.copyWith(visual: visual))),
          ),
          if (widget.inCall) ...[
            const SizedBox(height: 20),
            Text(l10n.speechCallPause, style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            SegmentedPill<CallPause>(
              key: const ValueKey('call-pause'),
              segments: callPauseSegments(l10n),
              selected: settings.pause,
              onChanged: (pause) =>
                  unawaited(ref.read(callSettingsProvider.notifier).edit((saved) => saved.copyWith(pause: pause))),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.speechCallPauseHint,
              style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
            const SizedBox(height: 20),
            Text(l10n.speechCallSpeechSection, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SheetGroup(
              margin: EdgeInsets.zero,
              children: [
                SettingsTile(
                  key: const ValueKey('call-voice'),
                  title: l10n.speechCallVoice,
                  value: Text(speechVoiceLabel(l10n, ref.watch(speechVoiceSettingsProvider))),
                  onTap: () {
                    widget.beforeVoice?.call();
                    unawaited(
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => const CompanionVoicePage(shared: true))),
                    );
                  },
                ),
                SettingsTile(
                  key: const ValueKey('call-recognition'),
                  title: l10n.voiceModeSection,
                  value: Text(voiceModeLabel(l10n, ref.watch(voiceSettingsProvider))),
                  onTap: () => unawaited(
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceSettingsPage())),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.speechCallSpeechHint,
              style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.preview,
    this.busy = false,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget preview;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ring = theme.colorScheme.primary;
    final enabled = onTap != null || busy;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: AppMotion.of(context, AppMotion.quick),
          child: Column(
            children: [
              AnimatedContainer(
                duration: AppMotion.of(context, AppMotion.standard),
                curve: AppMotion.std,
                height: 150,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: selected ? ring : Colors.transparent, width: 2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      preview,
                      if (busy)
                        const ColoredBox(
                          color: Color(0x66000000),
                          child: Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: selected ? ring : theme.colorScheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A still of the water for its card.
class _SeaSwatch extends StatelessWidget {
  const _SeaSwatch();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF10265A), Color(0xFF071330), Color(0xFF02050D)],
      ),
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.15),
          radius: 0.42,
          colors: [Color(0xFFB9E9FF), Color(0xFF4D6BFE), Color(0x004D6BFE)],
          stops: [0, 0.45, 1],
        ),
      ),
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1B2440), Color(0xFF0B1022)],
      ),
    ),
    child: Center(child: Icon(icon, color: Colors.white70, size: 28)),
  );
}

/// 快 / 适中 / 耐心, for 停顿多久算说完 here and in the settings.
List<PillSegment<CallPause>> callPauseSegments(L10n l10n) => [
  PillSegment(CallPause.quick, l10n.speechCallPauseQuick),
  PillSegment(CallPause.normal, l10n.speechCallPauseNormal),
  PillSegment(CallPause.patient, l10n.speechCallPausePatient),
];
