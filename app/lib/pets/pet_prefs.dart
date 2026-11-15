// 宠物设置 (docs/design/pets.md §2.1, §7), kept in SharedPreferences like the
// other appearance settings: which pet (or none), its size, quiet mode, where
// it stands, and 「藏起来 1 小时」. The overlay keeps its own switches natively.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../performance/performance_state.dart';
import 'pet_library.dart';
import 'pet_state.dart';

/// The pets that ship with the app, in picker order.
const builtInPets = ['deepy-whale', 'whale-girl'];

/// The default pet.
const defaultPetId = 'deepy-whale';

/// Explicit choice for the existing Android overlay. Pixel remains the default.
enum PetOverlayRenderer {
  pixel,
  companion;

  static PetOverlayRenderer fromName(String? value) => values.asNameMap()[value] ?? pixel;
}

/// 「取景」 for the companion in the overlay, as the stage reads `floatZoom`
/// and `floatY` (app/assets/companion/stage.js): her model stands 2 tall
/// around 0, the camera looks at `y` and magnifies by `zoom`.
enum PetOverlayFraming {
  /// The whole of her, with a little room around ([PetPrefs]' defaults).
  full(zoom: 0.9, y: 0),

  /// Twice as close and looking half-way up: her upper half fills what the
  /// whole of her did. A first guess from the numbers above, not tuned on a phone.
  half(zoom: 1.8, y: 0.5);

  const PetOverlayFraming({required this.zoom, required this.y});

  final double zoom;
  final double y;

  /// The preset [prefs] holds; anything else (set some other way) reads as [full].
  static PetOverlayFraming of(PetPrefs prefs) =>
      prefs.floatZoom == half.zoom && prefs.floatY == half.y ? half : full;
}

@immutable
class PetPrefs {
  const PetPrefs({
    this.packId = defaultPetId,
    this.packExplicit = true,
    this.size = PetSize.medium,
    this.customHeight = 30,
    this.quiet = false,
    this.position = defaultPosition,
    this.hiddenUntil,
    this.overlayRenderer = PetOverlayRenderer.pixel,
    this.floatZoom = 0.9,
    this.floatY = 0,
    this.loaded = false,
  });

  /// Where a new pet stands: a quarter along its perch, clear of the
  /// jump-to-bottom key on the right.
  static const defaultPosition = 0.25;

  /// The chosen pet, or [noPetId] (「不显示」).
  final String packId;
  final bool packExplicit;
  final PetSize size;

  /// 自定义's body height, dp, within [PetSize.customMin]–[PetSize.customMax].
  /// Kept while a preset is chosen, so going back to 自定义 finds it again.
  final double customHeight;

  /// The body height to draw at, dp.
  double get bodyHeight => size == PetSize.custom ? customHeight : size.bodyHeight;

  /// 「安静模式」: moves only, no bubbles.
  final bool quiet;

  /// Where its foot stands along its perch, as a share of the perch's width.
  final double position;

  /// 「藏起来 1 小时」 until then.
  final DateTime? hiddenUntil;
  final PetOverlayRenderer overlayRenderer;
  final double floatZoom;
  final double floatY;
  final bool loaded;

  bool get enabled => packId != noPetId;

  bool hiddenAt(DateTime now) => hiddenUntil != null && hiddenUntil!.isAfter(now);

  PetPrefs copyWith({
    String? packId,
    bool? packExplicit,
    PetSize? size,
    double? customHeight,
    bool? quiet,
    double? position,
    DateTime? hiddenUntil,
    bool clearHidden = false,
    PetOverlayRenderer? overlayRenderer,
    double? floatZoom,
    double? floatY,
    bool? loaded,
  }) => PetPrefs(
    packId: packId ?? this.packId,
    packExplicit: packExplicit ?? this.packExplicit,
    size: size ?? this.size,
    customHeight: customHeight ?? this.customHeight,
    quiet: quiet ?? this.quiet,
    position: position ?? this.position,
    hiddenUntil: clearHidden ? null : (hiddenUntil ?? this.hiddenUntil),
    overlayRenderer: overlayRenderer ?? this.overlayRenderer,
    floatZoom: floatZoom ?? this.floatZoom,
    floatY: floatY ?? this.floatY,
    loaded: loaded ?? this.loaded,
  );

  @override
  bool operator ==(Object other) =>
      other is PetPrefs &&
      other.packId == packId &&
      other.packExplicit == packExplicit &&
      other.size == size &&
      other.customHeight == customHeight &&
      other.quiet == quiet &&
      other.position == position &&
      other.hiddenUntil == hiddenUntil &&
      other.overlayRenderer == overlayRenderer &&
      other.floatZoom == floatZoom &&
      other.floatY == floatY &&
      other.loaded == loaded;

  @override
  int get hashCode => Object.hash(packId, packExplicit, size, customHeight, quiet, position, hiddenUntil,
      overlayRenderer, floatZoom, floatY, loaded);
}

class PetPrefsController extends Notifier<PetPrefs> {
  static const keys = (
    pack: 'pet.pack',
    size: 'pet.size',
    customHeight: 'pet.custom_height',
    quiet: 'pet.quiet',
    position: 'pet.position',
    hidden: 'pet.hidden_until',
    renderer: 'pet.overlay_renderer',
    framing: 'pet.overlay_framing',
  );

  late Future<void> _loaded;

  @override
  PetPrefs build() {
    ref.listen(performanceDefaultsProvider.select((p) => p.petEnabled), (_, next) {
      if (!state.packExplicit) state = state.copyWith(packId: next ? defaultPetId : noPetId);
    });
    _loaded = _load();
    return const PetPrefs(packExplicit: false);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      await performanceReady(ref);
      if (!ref.mounted) return;
      final pack = prefs.getString(keys.pack);
      // A brought pet stays chosen; removing it here picks the default
      // (UserPetsController.remove).
      final explicit = pack == noPetId || builtInPets.contains(pack) || (pack != null && isUserPet(pack));
      final hidden = prefs.getInt(keys.hidden);
      var zoom = 0.9, y = 0.0;
      try {
        final framing = jsonDecode(prefs.getString(keys.framing) ?? '{}');
        if (framing is Map) {
          final z = framing['zoom'], offset = framing['y'];
          if (z is num && z.isFinite && z > 0 && z <= 4) zoom = z.toDouble();
          if (offset is num && offset.isFinite && offset >= -1 && offset <= 1) y = offset.toDouble();
        }
      } on FormatException {
        // A corrupt framing preference cannot change the renderer default.
      }
      state = PetPrefs(
        packId: explicit
            ? pack!
            : ref.read(performanceDefaultsProvider).petEnabled
            ? defaultPetId
            : noPetId,
        packExplicit: explicit,
        size: PetSize.fromName(prefs.getString(keys.size)),
        customHeight: _customHeight(prefs.getDouble(keys.customHeight)),
        quiet: prefs.getBool(keys.quiet) ?? false,
        position: (prefs.getDouble(keys.position) ?? PetPrefs.defaultPosition).clamp(0.0, 1.0),
        hiddenUntil: hidden == null ? null : DateTime.fromMillisecondsSinceEpoch(hidden),
        overlayRenderer: PetOverlayRenderer.fromName(prefs.getString(keys.renderer)),
        floatZoom: zoom,
        floatY: y,
        loaded: true,
      );
    } catch (_) {
      // No preferences backend (tests): defaults.
      if (ref.mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Applies once the stored values are in, so a late load can't undo a change.
  Future<void> _save(PetPrefs Function(PetPrefs) apply, Future<void> Function(SharedPreferences) write) async {
    await _loaded;
    if (!ref.mounted) return;
    state = apply(state);
    try {
      await write(await SharedPreferences.getInstance());
    } catch (_) {
      // Kept for this run only.
    }
  }

  /// A pet, or [noPetId]. Choosing one also brings a hidden pet back.
  Future<void> setPack(String id) =>
      _save((s) => s.copyWith(packId: id, packExplicit: true, clearHidden: true), (p) async {
        await p.setString(keys.pack, id);
        await p.remove(keys.hidden);
      });

  /// The pet changed for the person, not by them (theirs is being removed):
  /// unlike [setPack], 「藏起来 1 小时」 stays as it was.
  Future<void> replacePack(String id) =>
      _save((s) => s.copyWith(packId: id, packExplicit: true), (p) => p.setString(keys.pack, id));

  /// First run's 「桌宠与悬浮窗」 was picked: the default pet, unless a pet
  /// (or 「不显示」) was chosen already. Without it a light phone, whose
  /// default is no pet, would turn on 「App 外显示」 with nothing to show.
  Future<void> adoptDefault() async {
    await _loaded;
    if (!ref.mounted || state.packExplicit) return;
    await setPack(defaultPetId);
  }

  Future<void> setSize(PetSize v) => _save((s) => s.copyWith(size: v), (p) => p.setString(keys.size, v.name));

  /// 自定义's height, dp; clamped to its range.
  Future<void> setCustomHeight(double dp) {
    final h = _customHeight(dp);
    return _save((s) => s.copyWith(customHeight: h), (p) => p.setDouble(keys.customHeight, h));
  }

  static double _customHeight(double? dp) =>
      dp == null || !dp.isFinite ? 30 : dp.clamp(PetSize.customMin, PetSize.customMax).toDouble();
  Future<void> setQuiet(bool v) => _save((s) => s.copyWith(quiet: v), (p) => p.setBool(keys.quiet, v));
  Future<void> setOverlayRenderer(PetOverlayRenderer value) =>
      _save((s) => s.copyWith(overlayRenderer: value), (p) => p.setString(keys.renderer, value.name));

  /// Model-relative framing, kept together in one preference. The default is
  /// full-body; it does not inherit the room's camera or gestures.
  Future<void> setOverlayFraming({required double zoom, required double y}) {
    if (!zoom.isFinite || zoom <= 0 || zoom > 4 || !y.isFinite || y < -1 || y > 1) {
      throw ArgumentError('Invalid companion framing');
    }
    return _save((s) => s.copyWith(floatZoom: zoom, floatY: y),
        (p) => p.setString(keys.framing, jsonEncode({'zoom': zoom, 'y': y})));
  }
  Future<void> setPosition(double v) {
    final x = v.clamp(0.0, 1.0);
    return _save((s) => s.copyWith(position: x), (p) => p.setDouble(keys.position, x));
  }

  /// 「藏起来 1 小时」.
  Future<void> hideUntil(DateTime until) =>
      _save((s) => s.copyWith(hiddenUntil: until), (p) => p.setInt(keys.hidden, until.millisecondsSinceEpoch));

  Future<void> unhide() => _save((s) => s.copyWith(clearHidden: true), (p) => p.remove(keys.hidden));
}

final petPrefsProvider = NotifierProvider<PetPrefsController, PetPrefs>(PetPrefsController.new);
