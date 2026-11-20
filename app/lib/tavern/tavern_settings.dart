// 酒馆设置: which model plays the characters and whether it thinks first
// (docs/design/roleplay.md §7). The built-in channel is DeepSeek with the
// app's own key (settings_state.dart); channels the person adds keep their
// keys in tavern_channels.dart, never here.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tavern_channels.dart';

/// [TavernSettings.auxiliary] for DeepSeek's flash with the app's key.
const tavernAuxiliaryDeepSeek = 'deepseek';

/// The DeepSeek models offered as choices, cheapest first; any other name
/// can be typed.
const tavernModels = ['deepseek-flash', 'deepseek-v4-pro'];

/// How a chat is laid out (docs/design/roleplay-ui.md §4): bubbles, full
/// width text under the speaker's name, or a stage with one paragraph at a
/// time (视觉小说).
enum TavernLayout { bubble, novel, visualNovel }

/// The story's text size (px), smallest first: a role-play reads more at a
/// time than a chat, so it starts a step below the app's 16. Any size in
/// [tavernTextSizeRange] can be typed.
const tavernTextSizes = [14.0, 15.0, 16.0, 18.0];
const tavernTextSizeRange = (min: 10.0, max: 32.0);

/// Its line spacing: 紧凑, 适中 (the app's), 宽松; or one typed.
const tavernLineHeights = [1.5, 1.65, 1.8];
const tavernLineHeightRange = (min: 1.0, max: 3.0);

/// The story's colours (tavern_ink.dart): 素 leaves the text as the app draws
/// it; the others colour what is said and what is done. [st] takes them from
/// an ST theme taken in (tavern_st_theme.dart); with none, 暖's.
enum TavernPalette { plain, ember, ocean, rose, st }

/// How fast 视觉小说 types out a page (docs/design/roleplay-ui.md §4); 立即
/// shows each page whole.
enum TavernTextSpeed {
  slow(16),
  normal(32),
  fast(64),
  instant(null);

  const TavernTextSpeed(this.charactersPerSecond);

  /// Null: no typing out.
  final double? charactersPerSecond;
}

/// 单回合费用提醒's lines, US dollars a turn; 0 is off. Any other amount in
/// the range can be typed.
const tavernCostAlerts = [0.0, 0.01, 0.05, 0.1, 0.5];
const tavernCostAlertRange = (min: 0.0, max: 100.0);

class TavernSettings {
  const TavernSettings({
    this.model = 'deepseek-flash',
    this.channel,
    this.channels = const [],
    this.auxiliary,
    this.thinking = false,
    this.layout = TavernLayout.bubble,
    this.textSize = 15,
    this.lineHeight = 1.5,
    this.palette = TavernPalette.ember,
    this.textSpeed = TavernTextSpeed.normal,
    this.showUsage = true,
    this.cardTheme = true,
    this.novelIndent = true,
    this.islands = true,
    this.islandNoScripts = false,
    this.islandOffline = false,
    this.canvas = false,
    this.lowPower = false,
    this.costAlert = 0,
    this.loaded = false,
  });

  /// DeepSeek's model, when the built-in channel is the one in use.
  final String model;

  /// The id of the channel in use, one of [channels]; null is DeepSeek's own.
  final String? channel;
  final List<TavernChannel> channels;

  /// Where the background requests (导演, picking who speaks in a group,
  /// secrets) go: null as the engine chooses (the main channel, DeepSeek's
  /// flash on DeepSeek), [tavernAuxiliaryDeepSeek] DeepSeek's flash with the
  /// app's key, else one of [channels]' ids.
  final String? auxiliary;
  final bool thinking;
  final TavernLayout layout;

  /// One of [tavernTextSizes] and [tavernLineHeights].
  final double textSize;
  final double lineHeight;
  final TavernPalette palette;
  final TavernTextSpeed textSpeed;

  /// A line of tokens under each reply, as the provider reported them.
  final bool showUsage;

  /// The card's own accent, name colours, layout and background
  /// (tavern_card_theme.dart); off, this page's settings everywhere.
  final bool cardTheme;

  /// 小说: each paragraph opens with two ideographic spaces, as fiction is set.
  final bool novelIndent;

  /// A message carrying HTML (an ```html block, <style>, <div>…) shows that
  /// part in a sandboxed web view of its own, as tall as it is (岛屿).
  final bool islands;

  /// Protections the user may turn on (security-as-options): the card's own
  /// scripts don't run in islands; islands load nothing from the network.
  final bool islandNoScripts;
  final bool islandOffline;

  /// 整页画布 (tavern_canvas.dart, a trial): the story in one web page with
  /// SillyTavern's structure, so a card's CSS reaches across messages. Not
  /// for 视觉小说; card scripts don't run there yet.
  final bool canvas;

  /// 省电渲染: the cards' web pages (整页画布 and islands) without their blur
  /// and with endless animations played once (tavern_page_perf.dart).
  final bool lowPower;

  /// 单回合费用提醒: a turn whose reply cost more than this (US dollars, at
  /// DeepSeek's list prices) is said to over the composer. One of
  /// [tavernCostAlerts]; 0 is off.
  final double costAlert;
  final bool loaded;

  /// The added channel in use; null when it is DeepSeek's own.
  TavernChannel? get activeChannel {
    for (final c in channels) {
      if (c.id == channel) return c;
    }
    return null;
  }

  /// The model the next reply comes from.
  String get activeModel => activeChannel?.model ?? model;

  /// The request speaks DeepSeek's API, so 思考 applies.
  bool get deepseekApi => activeChannel?.deepseek ?? true;

  /// The added channel the background requests use, when one is chosen.
  TavernChannel? get auxiliaryChannel {
    for (final c in channels) {
      if (c.id == auxiliary) return c;
    }
    return null;
  }

  TavernSettings copyWith({
    String? model,
    Object? channel = _keep,
    List<TavernChannel>? channels,
    Object? auxiliary = _keep,
    bool? thinking,
    TavernLayout? layout,
    double? textSize,
    double? lineHeight,
    TavernPalette? palette,
    TavernTextSpeed? textSpeed,
    bool? showUsage,
    bool? cardTheme,
    bool? novelIndent,
    bool? islands,
    bool? islandNoScripts,
    bool? islandOffline,
    bool? canvas,
    bool? lowPower,
    double? costAlert,
  }) => TavernSettings(
    model: model ?? this.model,
    channel: identical(channel, _keep) ? this.channel : channel as String?,
    channels: channels ?? this.channels,
    auxiliary: identical(auxiliary, _keep) ? this.auxiliary : auxiliary as String?,
    thinking: thinking ?? this.thinking,
    layout: layout ?? this.layout,
    textSize: textSize ?? this.textSize,
    lineHeight: lineHeight ?? this.lineHeight,
    palette: palette ?? this.palette,
    textSpeed: textSpeed ?? this.textSpeed,
    showUsage: showUsage ?? this.showUsage,
    cardTheme: cardTheme ?? this.cardTheme,
    novelIndent: novelIndent ?? this.novelIndent,
    islands: islands ?? this.islands,
    islandNoScripts: islandNoScripts ?? this.islandNoScripts,
    islandOffline: islandOffline ?? this.islandOffline,
    canvas: canvas ?? this.canvas,
    lowPower: lowPower ?? this.lowPower,
    costAlert: costAlert ?? this.costAlert,
    loaded: true,
  );

  static const _keep = Object();
}

class TavernSettingsController extends Notifier<TavernSettings> {
  static const modelKey = 'tavern.model';
  static const channelKey = 'tavern.channel';
  static const channelsKey = 'tavern.channels';
  static const auxiliaryKey = 'tavern.auxiliary';
  static const thinkingKey = 'tavern.thinking';
  static const layoutKey = 'tavern.layout';
  static const textSizeKey = 'tavern.textSize';
  static const lineHeightKey = 'tavern.lineHeight';
  static const paletteKey = 'tavern.palette';
  static const textSpeedKey = 'tavern.textSpeed';
  static const showUsageKey = 'tavern.showUsage';
  static const cardThemeKey = 'tavern.cardTheme';
  static const novelIndentKey = 'tavern.novelIndent';
  static const islandsKey = 'tavern.islands';
  static const islandNoScriptsKey = 'tavern.islandNoScripts';
  static const islandOfflineKey = 'tavern.islandOffline';
  static const canvasKey = 'tavern.canvas';
  static const lowPowerKey = 'tavern.lowPower';
  static const costAlertKey = 'tavern.costAlert';

  @override
  TavernSettings build() {
    unawaited(_load());
    return const TavernSettings();
  }

  Future<void> _load() async {
    var loaded = const TavernSettings(loaded: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final model = prefs.getString(modelKey)?.trim() ?? '';
      final keys = ref.read(tavernChannelKeysProvider);
      final channels = [
        for (final c in TavernChannel.listFromJson(prefs.getString(channelsKey)))
          c.copyWith(headers: await _headersOf(keys, c.id)),
      ];
      final channel = prefs.getString(channelKey);
      final auxiliary = prefs.getString(auxiliaryKey);
      loaded = TavernSettings(
        model: model.isEmpty ? tavernModels.first : model,
        channel: channels.any((c) => c.id == channel) ? channel : null,
        channels: channels,
        auxiliary: auxiliary == tavernAuxiliaryDeepSeek || channels.any((c) => c.id == auxiliary) ? auxiliary : null,
        thinking: prefs.getBool(thinkingKey) ?? false,
        layout: TavernLayout.values.asNameMap()[prefs.getString(layoutKey)] ?? TavernLayout.bubble,
        textSize: _within(prefs.getDouble(textSizeKey), tavernTextSizeRange, 15),
        lineHeight: _within(prefs.getDouble(lineHeightKey), tavernLineHeightRange, 1.5),
        palette: TavernPalette.values.asNameMap()[prefs.getString(paletteKey)] ?? TavernPalette.ember,
        textSpeed: TavernTextSpeed.values.asNameMap()[prefs.getString(textSpeedKey)] ?? TavernTextSpeed.normal,
        showUsage: prefs.getBool(showUsageKey) ?? true,
        cardTheme: prefs.getBool(cardThemeKey) ?? true,
        novelIndent: prefs.getBool(novelIndentKey) ?? true,
        islands: prefs.getBool(islandsKey) ?? true,
        islandNoScripts: prefs.getBool(islandNoScriptsKey) ?? false,
        islandOffline: prefs.getBool(islandOfflineKey) ?? false,
        canvas: prefs.getBool(canvasKey) ?? false,
        lowPower: prefs.getBool(lowPowerKey) ?? false,
        costAlert: _within(prefs.getDouble(costAlertKey), tavernCostAlertRange, 0),
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): the defaults.
    }
    if (!state.loaded) state = loaded;
  }

  Future<void> setModel(String model) async {
    state = state.copyWith(model: model);
    await _save((prefs) => prefs.setString(modelKey, model));
  }

  /// Uses [id]'s channel from now on; null goes back to DeepSeek's own.
  Future<void> setChannel(String? id) async {
    state = state.copyWith(channel: id);
    await _save((prefs) => id == null ? prefs.remove(channelKey) : prefs.setString(channelKey, id));
  }

  /// Background requests to [id] ([TavernSettings.auxiliary]); null leaves
  /// them to the engine.
  Future<void> setAuxiliary(String? id) async {
    state = state.copyWith(auxiliary: id);
    await _save((prefs) => id == null ? prefs.remove(auxiliaryKey) : prefs.setString(auxiliaryKey, id));
  }

  /// Adds [channel], or replaces the one with its id. [key] replaces its key
  /// when given; empty removes it (an endpoint that needs none).
  Future<void> saveChannel(TavernChannel channel, {String? key}) async {
    final keys = ref.read(tavernChannelKeysProvider);
    // A key cleared clears the headers too: they are written after it.
    if (key != null) {
      key.isEmpty ? await keys.delete(channel.id) : await keys.write(channel.id, key);
    }
    await keys.writeHeaders(channel.id, channel.headers);
    final channels = [...state.channels];
    final at = channels.indexWhere((c) => c.id == channel.id);
    at < 0 ? channels.add(channel) : channels[at] = channel;
    state = state.copyWith(channels: channels);
    await _save((prefs) => prefs.setString(channelsKey, TavernChannel.listToJson(channels)));
  }

  /// Removes [id]'s channel and its key; DeepSeek's own takes over if it was in use.
  Future<void> deleteChannel(String id) async {
    final channels = [...state.channels]..removeWhere((c) => c.id == id);
    if (state.channel == id) await setChannel(null);
    if (state.auxiliary == id) await setAuxiliary(null);
    state = state.copyWith(channels: channels);
    await _save((prefs) => prefs.setString(channelsKey, TavernChannel.listToJson(channels)));
    await ref.read(tavernChannelKeysProvider).delete(id);
  }

  Future<void> setThinking(bool thinking) async {
    state = state.copyWith(thinking: thinking);
    await _save((prefs) => prefs.setBool(thinkingKey, thinking));
  }

  Future<void> setLayout(TavernLayout layout) async {
    state = state.copyWith(layout: layout);
    await _save((prefs) => prefs.setString(layoutKey, layout.name));
  }

  Future<void> setTextSize(double size) async {
    state = state.copyWith(textSize: size);
    await _save((prefs) => prefs.setDouble(textSizeKey, size));
  }

  Future<void> setLineHeight(double height) async {
    state = state.copyWith(lineHeight: height);
    await _save((prefs) => prefs.setDouble(lineHeightKey, height));
  }

  Future<void> setPalette(TavernPalette palette) async {
    state = state.copyWith(palette: palette);
    await _save((prefs) => prefs.setString(paletteKey, palette.name));
  }

  Future<void> setTextSpeed(TavernTextSpeed speed) async {
    state = state.copyWith(textSpeed: speed);
    await _save((prefs) => prefs.setString(textSpeedKey, speed.name));
  }

  Future<void> setShowUsage(bool show) async {
    state = state.copyWith(showUsage: show);
    await _save((prefs) => prefs.setBool(showUsageKey, show));
  }

  Future<void> setCardTheme(bool use) async {
    state = state.copyWith(cardTheme: use);
    await _save((prefs) => prefs.setBool(cardThemeKey, use));
  }

  Future<void> setNovelIndent(bool indent) async {
    state = state.copyWith(novelIndent: indent);
    await _save((prefs) => prefs.setBool(novelIndentKey, indent));
  }

  Future<void> setIslands(bool on) async {
    state = state.copyWith(islands: on);
    await _save((prefs) => prefs.setBool(islandsKey, on));
  }

  Future<void> setIslandNoScripts(bool on) async {
    state = state.copyWith(islandNoScripts: on);
    await _save((prefs) => prefs.setBool(islandNoScriptsKey, on));
  }

  Future<void> setIslandOffline(bool on) async {
    state = state.copyWith(islandOffline: on);
    await _save((prefs) => prefs.setBool(islandOfflineKey, on));
  }

  Future<void> setCanvas(bool on) async {
    state = state.copyWith(canvas: on);
    await _save((prefs) => prefs.setBool(canvasKey, on));
  }

  Future<void> setLowPower(bool on) async {
    state = state.copyWith(lowPower: on);
    await _save((prefs) => prefs.setBool(lowPowerKey, on));
  }

  Future<void> setCostAlert(double usd) async {
    state = state.copyWith(costAlert: usd);
    await _save((prefs) => prefs.setDouble(costAlertKey, usd));
  }

  /// [id]'s headers; none when the secure storage cannot be read (the
  /// channel then fails at its endpoint, rather than every setting going and
  /// DeepSeek's own being used instead).
  static Future<Map<String, String>> _headersOf(TavernChannelKeys keys, String id) async {
    try {
      return await keys.readHeaders(id);
    } on Exception {
      return const {};
    }
  }

  /// [stored] when it is within [range]; else [fallback].
  static double _within(double? stored, ({double min, double max}) range, double fallback) =>
      stored != null && stored >= range.min && stored <= range.max ? stored : fallback;

  Future<void> _save(Future<bool> Function(SharedPreferences prefs) write) async {
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {}
  }
}

final tavernSettingsProvider = NotifierProvider<TavernSettingsController, TavernSettings>(TavernSettingsController.new);

/// One chat's own layout, over 酒馆设置's; null follows the setting.
class TavernChatLayoutController extends Notifier<TavernLayout?> {
  TavernChatLayoutController(this.chatId);

  final String chatId;
  var _chosen = false;

  String get _key => 'tavern.layout.$chatId';

  @override
  TavernLayout? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      if (!_chosen && ref.mounted) state = TavernLayout.values.asNameMap()[stored];
    } catch (_) {}
  }

  Future<void> set(TavernLayout? layout) async {
    _chosen = true;
    state = layout;
    try {
      final prefs = await SharedPreferences.getInstance();
      layout == null ? await prefs.remove(_key) : await prefs.setString(_key, layout.name);
    } catch (_) {}
  }
}

final tavernChatLayoutProvider = NotifierProvider.autoDispose.family<TavernChatLayoutController, TavernLayout?, String>(
  TavernChatLayoutController.new,
);

/// How a character's chats show what the card writes (docs/design/
/// roleplay-roadmap.md P1, 渲染级别): as text, HTML in islands of its own
/// within each message, or the whole story on one page (整页画布).
enum TavernRender { text, islands, canvas }

/// A character's own [TavernRender], over 酒馆设置 › 显示; null follows those.
/// Its chats with others (a group) follow the settings.
class TavernCharacterRenderController extends Notifier<TavernRender?> {
  TavernCharacterRenderController(this.characterId);

  final String characterId;
  var _chosen = false;

  static String keyFor(String characterId) => 'tavern.render.$characterId';

  @override
  TavernRender? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(keyFor(characterId));
      if (!_chosen && ref.mounted) state = TavernRender.values.asNameMap()[stored];
    } catch (_) {}
  }

  Future<void> set(TavernRender? render) async {
    _chosen = true;
    state = render;
    try {
      final prefs = await SharedPreferences.getInstance();
      render == null
          ? await prefs.remove(keyFor(characterId))
          : await prefs.setString(keyFor(characterId), render.name);
    } catch (_) {}
  }
}

final tavernCharacterRenderProvider = NotifierProvider.autoDispose
    .family<TavernCharacterRenderController, TavernRender?, String>(TavernCharacterRenderController.new);

/// What [settings] come to as one [TavernRender]: the canvas over islands.
TavernRender tavernRenderOf(TavernSettings settings) => settings.canvas
    ? TavernRender.canvas
    : settings.islands
    ? TavernRender.islands
    : TavernRender.text;
