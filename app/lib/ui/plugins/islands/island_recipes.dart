import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../plugins/seams/seat_models.dart';
import 'island_handle.dart' show IslandTiming;

/// How island.js pins the slot to the WebView (`assets/islands/island.css`).
enum IslandStretch {
  /// The slot's nearest scrolling ancestor (a settings page, a plugin page):
  /// what sits around the slot in it is taken out of the layout.
  scroller,

  /// The slot's single entry (a whole panel or tab body).
  child,

  /// The box around the slot: every entry of a list slot, stacked.
  parent,

  /// Left where it is (an overlay's entries position themselves).
  none,

  /// Several slots ([IslandRecipe.slots]) at once: the nearest box holding
  /// all of them, with everything between them taken out of the layout, so
  /// their entries stack in page order.
  common;

  static IslandStretch? tryParse(Object? v) => switch (v) {
    'scroller' => scroller,
    'child' => child,
    'parent' => parent,
    'none' => none,
    'common' => common,
    _ => null,
  };
}

/// How to reach a slot in DSH Web and how to show it: one entry of
/// `assets/islands/recipes.json`. Selectors live in island.js and only use
/// `data-slot`, roles, accessible names and the client's own data attributes.
@immutable
class IslandRecipe {
  const IslandRecipe({
    required this.forms,
    required this.open,
    this.stretch = IslandStretch.scroller,
    this.padX = 16,
    this.padY = 16,
    this.session = false,
    this.ready,
    this.slots,
  });

  final Set<IslandForm> forms;

  /// `settings`, `settings-general`, `settings-plugins`, `sidebar`,
  /// `plugin`, `plugin-row`, `plugin-detail`, `panel`, `rightbar`,
  /// `session-view`, `session` or `none`.
  final String open;
  final IslandStretch stretch;
  final double padX;
  final double padY;

  /// The slot only exists inside a conversation.
  final bool session;

  /// How long it may take to show before the seat falls back: `"ready"`
  /// names one of [IslandTiming]'s limits (`view`, `sheet`); null:
  /// [IslandTiming.ready].
  final Duration? ready;

  /// The DSH slots an island of an app-side key shows together (the chat
  /// page's 「插件」 sheet); null: just the key itself.
  final List<String>? slots;

  /// The slots whose official entries the bridge masks.
  List<String> slotsFor(String key) => slots ?? [key];
}

/// `assets/islands/recipes.json`: the recipe per slot, the official ids the
/// open bridge (`assets/web/dsh_web_open.js`) knows, and the names of the
/// official controls island.js clicks on the way.
@immutable
class IslandRecipeBook {
  const IslandRecipeBook({
    this.version = 1,
    this.release,
    this.labels = const {},
    this.officialSettings = const {},
    this.officialPanels = const {},
    this.officialRightbar = const {},
    this.slots = const {},
  });

  /// Parses the book; entries it can't read are skipped (a newer app's
  /// recipes on an older one degrade to "no island", never to an error).
  factory IslandRecipeBook.parse(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return const IslandRecipeBook();
    }
    if (json is! Map) return const IslandRecipeBook();
    final labels = <String, List<String>>{};
    if (json['labels'] case final Map raw) {
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is String && value is List) labels[key] = [...value.whereType<String>()];
      }
    }
    Set<String> strings(Object? v) => v is List ? {...v.whereType<String>()} : const {};
    final official = json['official'] is Map ? json['official'] as Map : const {};
    final slots = <String, IslandRecipe>{};
    if (json['slots'] case final Map raw) {
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is! String || value is! Map) continue;
        final forms = <IslandForm>{
          if (value['forms'] case final List f)
            for (final name in f) ?IslandForm.values.where((v) => v.name == name).firstOrNull,
        };
        final open = value['open'];
        final stretch = IslandStretch.tryParse(value['stretch']) ?? IslandStretch.scroller;
        if (forms.isEmpty || open is! String) continue;
        final pad = value['pad'];
        double padAt(int i) => pad is List && pad.length > i && pad[i] is num ? (pad[i] as num).toDouble() : 16;
        final together = value['slots'] is List ? [...(value['slots'] as List).whereType<String>()] : null;
        slots[key] = IslandRecipe(
          forms: forms,
          open: open,
          stretch: stretch,
          padX: padAt(0),
          padY: padAt(1),
          session: value['session'] == true,
          ready: IslandTiming.named(value['ready']),
          slots: together == null || together.isEmpty ? null : List.unmodifiable(together),
        );
      }
    }
    final version = json['version'];
    final release = json['release'];
    return IslandRecipeBook(
      version: version is int ? version : 1,
      release: release is String ? release : null,
      labels: labels,
      officialSettings: strings(official['settings']),
      officialPanels: strings(official['panels']),
      officialRightbar: strings(official['rightbar']),
      slots: slots,
    );
  }

  final int version;

  /// The DSH release the recipes were checked against.
  final String? release;
  final Map<String, List<String>> labels;
  final Set<String> officialSettings;
  final Set<String> officialPanels;
  final Set<String> officialRightbar;
  final Map<String, IslandRecipe> slots;

  IslandRecipe? recipeFor(String slot) => slots[slot];

  /// This book with [extra] recipes on top (the PoC's test slots).
  IslandRecipeBook withSlots(Map<String, IslandRecipe> extra) => IslandRecipeBook(
    version: version,
    release: release,
    labels: labels,
    officialSettings: officialSettings,
    officialPanels: officialPanels,
    officialRightbar: officialRightbar,
    slots: {...slots, ...extra},
  );

  /// Whether [spec] can be an island at all: a recipe for its slot and form,
  /// and a conversation when the slot needs one. Probes need no recipe.
  bool supports(IslandSpec spec, {List<String> labels = const []}) =>
      spec.form == IslandForm.probe || targetFor(spec, labels: labels) != null;

  /// What island.js's navigate() gets for [spec] (`{session?, web?, then?}`),
  /// or null when there is no way there: no recipe, a form the slot doesn't
  /// take, no conversation for a conversation slot, nothing to find a
  /// third-party entry by. [labels] are the occupant's registered labels
  /// (zh and en), used where the official client has no ids on screen.
  Map<String, Object?>? targetFor(IslandSpec spec, {List<String> labels = const []}) {
    if (spec.form == IslandForm.probe) return const {};
    final recipe = slots[spec.slot];
    if (recipe == null || !recipe.forms.contains(spec.form)) return null;
    final session = spec.sessionId;
    if (recipe.session && (session == null || session.isEmpty)) return null;
    final cell = spec.cell ?? '';
    final names = [
      for (final l in labels)
        if (l.replaceAll(RegExp(r'\s+'), ' ').trim() case final clean when clean.isNotEmpty) clean,
    ];
    Map<String, Object?> at({Map<String, Object?>? web, Map<String, Object?>? then}) => {
      if (recipe.session) 'session': session,
      'web': ?web,
      'then': ?then,
    };
    switch (recipe.open) {
      case 'settings':
        if (cell.isEmpty) return at(web: {'settings': 'general'});
        if (officialSettings.contains(cell)) return at(web: {'settings': cell});
        if (names.isEmpty) return null;
        return at(web: {'settings': true}, then: {'settings': names});
      case 'sidebar':
        if (spec.package == null || spec.package!.isEmpty || cell.isEmpty) return null;
        return at(web: {'sidebar': true}, then: {'sidebar': true});
      case 'settings-plugins':
        if (spec.package == null || spec.package!.isEmpty || cell.isEmpty) return null;
        return at(web: {'settings': 'plugins'}, then: {'settingsPlugin': cell});
      case 'plugin-detail':
        final package = spec.package;
        if (package == null || package.isEmpty || cell.isEmpty) return null;
        return at(web: {'panel': 'plugins'}, then: {'plugin': package});
      case 'settings-general':
        return at(web: {'settings': 'general'});
      case 'plugin':
        final package = cell.isNotEmpty ? cell : spec.package;
        if (package == null || package.isEmpty) return null;
        return at(web: {'panel': 'plugins'}, then: {'plugin': package});
      case 'plugin-row':
        final hash = cell.indexOf('#');
        if (hash <= 0 || hash == cell.length - 1) return null;
        return at(
          web: {'panel': 'plugins'},
          then: {'plugin': cell.substring(0, hash), 'row': cell.substring(hash + 1)},
        );
      case 'panel':
        if (officialPanels.contains(cell)) return at(web: {'panel': cell});
        if (names.isEmpty) return null;
        return at(then: {'panel': names});
      case 'rightbar':
        if (officialRightbar.contains(cell)) return at(web: {'rightbar': cell});
        // dsh-go-bridge opens a tab by its id (the cell); labels are the
        // fallback on hosts without it.
        if (cell.isEmpty) return null;
        return at(then: {'rightbar': names});
      case 'session-view':
        // A view has no id on screen: island.js finds its tab (or its row
        // under 「更多会话视图」) by name, then confirms by the id: the one
        // the client stores for the conversation once it is picked.
        if (cell.isEmpty || names.isEmpty) return null;
        return at(
          then: {
            'view': {'id': cell, 'names': names},
          },
        );
      case 'session':
        return at();
      case 'none':
        return at();
    }
    return null;
  }
}
