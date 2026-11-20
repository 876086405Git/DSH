// 舞台 › 会话 › 音乐和音效: the player for a card's music and sounds on the
// canvas (酒馆助手's 音频播放器): what each of its two players is on, play or
// pause, how it goes on, how loud, and whether the card may play at all.
// Shown only while the chat's canvas has something to play.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_canvas_audio.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../workspace/text_prompt.dart';

class TavernAudioSection extends ConsumerWidget {
  const TavernAudioSection({super.key, required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final players = ref.watch(tavernCanvasAudioProvider(chatId));
    final audio = ref.read(tavernCanvasAudioProvider(chatId).notifier);
    final shown = [
      for (final type in tavernAudioChannels)
        if (players[type] case final now? when now.any) (type, now),
    ];
    // No canvas page up: nothing to play on.
    if (players.isEmpty) return const SizedBox.shrink();
    return SettingsSection(
      title: l10n.tavernAudio,
      margin: const EdgeInsets.only(bottom: 12),
      children: [
        for (final (type, now) in shown) ...[
          SettingsTile(
            key: ValueKey('tavern-audio-$type'),
            icon: AppIcons.audio,
            tinted: false,
            title: type == 'bgm' ? l10n.tavernAudioBgm : l10n.tavernAudioAmbient,
            subtitle: now.title.isEmpty ? l10n.tavernAudioNothing : now.title,
            // The glyph, not its 48 tap box, ends where the switches below end.
            trailing: IconButton(
              key: ValueKey('tavern-audio-$type-toggle'),
              tooltip: now.playing ? l10n.tavernAudioPause : l10n.tavernAudioPlay,
              icon: Transform.translate(
                offset: Offset(Directionality.of(context) == TextDirection.rtl ? -12 : 12, 0),
                child: Icon(now.playing ? AppIcons.mediaPause : AppIcons.mediaPlay),
              ),
              onPressed: now.enabled && now.tracks > 0 ? () => unawaited(audio.toggle(type)) : null,
            ),
          ),
          SettingsSegmentTile<String>(
            key: ValueKey('tavern-audio-$type-mode'),
            title: l10n.tavernAudioMode,
            tinted: false,
            segments: [
              PillSegment('repeat_one', l10n.tavernAudioModeOne),
              PillSegment('repeat_all', l10n.tavernAudioModeAll),
              PillSegment('shuffle', l10n.tavernAudioModeShuffle),
              PillSegment('play_one_and_stop', l10n.tavernAudioModeOnce),
            ],
            selected: now.mode,
            onChanged: (mode) => unawaited(audio.settle(type, {'mode': mode})),
          ),
          _Volume(
            key: ValueKey('tavern-audio-$type-volume'),
            volume: now.volume.toDouble(),
            onChanged: (volume) => unawaited(audio.settle(type, {'volume': volume.round()})),
          ),
          SettingsSwitchTile(
            key: ValueKey('tavern-audio-$type-allow'),
            title: l10n.tavernAudioAllow,
            value: now.enabled,
            onChanged: (on) => unawaited(audio.settle(type, {'enabled': on})),
          ),
        ],
        SettingsTile(
          key: const ValueKey('tavern-audio-add'),
          icon: AppIcons.add,
          tinted: false,
          title: l10n.tavernAudioAdd,
          chevron: false,
          onTap: () => unawaited(_add(context, audio)),
        ),
      ],
    );
  }

  /// A track of the person's own, by its link, to the music list.
  Future<void> _add(BuildContext context, TavernCanvasAudio audio) async {
    final l10n = context.l10n;
    final url = await showTextPrompt(
      context,
      title: l10n.tavernAudioAddTitle,
      hint: 'https://',
      caption: l10n.tavernAudioAddNote,
      confirm: l10n.tavernAudioAddConfirm,
      keyboardType: TextInputType.url,
      validate: (text) => switch (Uri.tryParse(text.trim())) {
        final Uri uri when (uri.isScheme('http') || uri.isScheme('https')) && uri.host.isNotEmpty => null,
        _ => l10n.tavernAudioAddInvalid,
      },
    );
    if (url == null || url.isEmpty) return;
    await audio.append('bgm', url);
  }
}

/// How loud, 0–100, as every slider in settings is drawn (title and percent above, the track
/// from text edge to text edge): follows the finger, said to the page when let go.
class _Volume extends StatefulWidget {
  const _Volume({super.key, required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  State<_Volume> createState() => _VolumeState();
}

class _VolumeState extends State<_Volume> {
  double? _dragging;

  @override
  Widget build(BuildContext context) => SettingsSliderTile(
    title: context.l10n.tavernAudioVolume,
    value: (_dragging ?? widget.volume) / 100,
    onChanged: (v) => setState(() => _dragging = v * 100),
    onChangeEnd: (v) {
      setState(() => _dragging = null);
      widget.onChanged(v * 100);
    },
  );
}
