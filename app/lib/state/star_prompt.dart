// The star prompt (docs/design/star-prompt.md): after half an hour with the
// app in front, the whale girl asks for a star on GitHub, in a dialog, when
// the person is idle in the chat; 「下次再说」 asks again at 2, 5, 10 and 20
// hours of use, each time in other words (the last says it is the last), and
// that is all.
//
// Off unless the build says `--dart-define=DSH_STAR_PROMPT=true`: off, nothing
// here runs (no counting, no preferences). What is kept on the phone, in one
// SharedPreferences entry, is only what the rules need; whether the person did
// star the project is never known nor asked.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../phone/phone_channel.dart' show PhoneTaskStatus;
import '../pets/pet_signals.dart' show petFocusProvider, petPendingProvider;
import '../update/update_config.dart' show updateRepo;
import 'draft_store.dart';
import 'notify_state.dart' show appForegroundProvider, chatOnScreenProvider;
import 'phone_state.dart' show phoneChannelProvider;
import 'sessions_state.dart' show currentSessionProvider;
import 'voice_state.dart';

/// The release switch: `--dart-define=DSH_STAR_PROMPT=true` on the public build.
const starPromptEnabled = bool.fromEnvironment('DSH_STAR_PROMPT');

/// The switch as the app reads it (tests turn it on).
final starPromptGateProvider = Provider<bool>((ref) => starPromptEnabled);

/// Where 「去 GitHub 点 Star」 goes: the public repository's page (its releases
/// are the app's updates).
final starProjectPage = Uri.https('github.com', '/$updateRepo');

/// The numbers behind the prompt, with their reasons in the design note.
abstract final class StarPromptRules {
  /// The time in front at which each ask comes (after 「下次再说」 or back for
  /// the ones before it); each has its own words, the last says it is the last.
  static const asks = [
    Duration(minutes: 30),
    Duration(hours: 2),
    Duration(hours: 5),
    Duration(hours: 10),
    Duration(hours: 20),
  ];

  /// At least this much more time in front after an ask before the next: one
  /// that came up late doesn't bring the next right after it.
  static const gap = Duration(hours: 1);

  /// Asked this often at most, ever.
  static int get maxShows => asks.length;

  /// How often time in front is written down (and the prompt looks again).
  static const tick = Duration(minutes: 1);

  /// Due and quiet this long before it comes up: the screen has settled.
  static const settle = Duration(seconds: 3);

  /// Phone control just ended: the person is checking what it did.
  static const phoneCooldown = Duration(minutes: 2);
}

/// What the phone keeps for the prompt.
@immutable
class StarPromptRecord {
  const StarPromptRecord({this.used = Duration.zero, this.shows = 0, this.askedAt, this.finished = false});

  /// Time with the app in front (resumed), all launches together.
  final Duration used;

  /// How often the dialog came up.
  final int shows;

  /// [used] when it last came up.
  final Duration? askedAt;

  /// 「去 GitHub 点 Star」, 「已经点过啦」 or the settings row: never again.
  final bool finished;

  /// The time in front at which it asks next; null: never again.
  Duration? get nextAt {
    if (finished || shows >= StarPromptRules.maxShows) return null;
    final at = StarPromptRules.asks[shows];
    final soonest = switch (askedAt) {
      final asked? => asked + StarPromptRules.gap,
      null => Duration.zero,
    };
    return at > soonest ? at : soonest;
  }

  bool get due => switch (nextAt) {
    final at? => used >= at,
    null => false,
  };

  /// Nothing more to ask: time is no longer counted.
  bool get over => nextAt == null;

  StarPromptRecord copyWith({Duration? used, int? shows, Duration? askedAt, bool? finished}) => StarPromptRecord(
    used: used ?? this.used,
    shows: shows ?? this.shows,
    askedAt: askedAt ?? this.askedAt,
    finished: finished ?? this.finished,
  );

  Map<String, Object?> toJson() => {
    'v': 2,
    'usedMs': used.inMilliseconds,
    'shows': shows,
    'askedAtMs': ?askedAt?.inMilliseconds,
    'finished': finished,
  };

  /// Null for anything that isn't a record this app wrote. One from the
  /// earlier prompt (v1) keeps only whether it was finished (the settings row).
  static StarPromptRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    if (json['v'] == 1) return StarPromptRecord(finished: json['finished'] == true);
    if (json['v'] != 2) return null;
    int count(Object? v) => v is int && v > 0 ? v : 0;
    final asked = json['askedAtMs'];
    return StarPromptRecord(
      used: Duration(milliseconds: count(json['usedMs'])),
      shows: count(json['shows']),
      askedAt: asked is int && asked >= 0 ? Duration(milliseconds: asked) : null,
      finished: json['finished'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StarPromptRecord &&
      other.used == used &&
      other.shows == shows &&
      other.askedAt == askedAt &&
      other.finished == finished;

  @override
  int get hashCode => Object.hash(used, shows, askedAt, finished);

  @override
  String toString() => 'StarPromptRecord(${toJson()})';
}

// ── Storage ──────────────────────────────────────────────────────────────────

/// Where the record lives (tests swap in one that fails).
abstract interface class StarPromptStore {
  /// The stored record; null when there is none (or it is unreadable as a
  /// record). Throws when the preferences cannot be read at all.
  Future<StarPromptRecord?> read();

  Future<void> write(StarPromptRecord record);
}

class PrefsStarPromptStore implements StarPromptStore {
  const PrefsStarPromptStore();

  static const key = 'star_prompt';

  @override
  Future<StarPromptRecord?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    try {
      return StarPromptRecord.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(StarPromptRecord record) async =>
      (await SharedPreferences.getInstance()).setString(key, jsonEncode(record.toJson()));
}

final starPromptStoreProvider = Provider<StarPromptStore>((ref) => const PrefsStarPromptStore());

/// The prompt's clock: time since it was first read, never going back, so a
/// changed phone clock adds or takes nothing (tests move it by hand).
final starPromptClockProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
});

/// The record, loaded once; every change is written back. With the switch on
/// it counts time in front: from resumed to anything else, written down every
/// [StarPromptRules.tick] and on leaving. A read that fails starts a fresh
/// record kept for this run only, so nothing stored earlier (「已经点过啦」
/// above all) is overwritten; a write that fails keeps the change for this run.
class StarPromptController extends Notifier<StarPromptRecord> {
  late Future<void> _loaded;
  bool _persist = true;
  bool _ready = false;

  /// The clock when time in front last went into the record; null while away.
  Duration? _since;
  Timer? _tick;

  Duration get _now => ref.read(starPromptClockProvider)();

  @override
  StarPromptRecord build() {
    _loaded = _load();
    if (ref.read(starPromptGateProvider)) _watch();
    return const StarPromptRecord();
  }

  /// The stored record is in (or known unreadable).
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    final store = ref.read(starPromptStoreProvider);
    StarPromptRecord? stored;
    try {
      stored = await store.read();
    } catch (_) {
      _persist = false;
    }
    if (!ref.mounted) return;
    _ready = true;
    // Time counted while it loaded is applied on top.
    if (stored != null) state = stored;
  }

  void _watch() {
    AppLifecycleListener? lifecycle = AppLifecycleListener(onStateChange: (s) => _front(_inFront(s)));
    void stop() {
      lifecycle?.dispose();
      lifecycle = null;
      _tick?.cancel();
      _since = null;
    }

    ref.onDispose(stop);
    listenSelf((_, record) {
      if (record.over) stop();
    });
    _front(_inFront(WidgetsBinding.instance.lifecycleState));
  }

  static bool _inFront(AppLifecycleState? state) => state == null || state == AppLifecycleState.resumed;

  void _front(bool front) {
    if (front) {
      _since ??= _now;
      _tick ??= Timer.periodic(StarPromptRules.tick, (_) => _note());
    } else {
      _note();
      _since = null;
      _tick?.cancel();
      _tick = null;
    }
  }

  /// The time in front since the last note goes into the record.
  void _note() {
    final since = _since;
    if (since == null) return;
    final now = _now;
    _since = now;
    unawaited(_apply((r) => r.over ? r : r.copyWith(used: r.used + (now - since))));
  }

  Future<void> _write(StarPromptRecord record) async {
    if (!_persist) return;
    try {
      await ref.read(starPromptStoreProvider).write(record);
    } catch (_) {
      // Kept for this run only.
    }
  }

  Future<void> _apply(StarPromptRecord Function(StarPromptRecord) change) async {
    await _loaded;
    if (!ref.mounted) return;
    final next = change(state);
    if (next == state) return;
    state = next;
    await _write(next);
  }

  /// Whether the dialog may come up now.
  bool get due => _ready && state.due;

  /// The dialog came up (written at once: a kill while it is up counts as
  /// 「下次再说」).
  Future<void> shown() {
    _note();
    return _apply((r) => r.copyWith(shows: r.shows + 1, askedAt: r.used));
  }

  /// 「去 GitHub 点 Star」, 「已经点过啦」 or the settings row: never again.
  Future<void> finish() => _apply((r) => r.copyWith(finished: true));
}

final starPromptProvider = NotifierProvider<StarPromptController, StarPromptRecord>(StarPromptController.new);

// ── Is the person idle ───────────────────────────────────────────────────────

/// What could be interrupted, apart from what only the page knows (the
/// keyboard, the drawer): the host adds those.
@immutable
class StarPromptScene {
  const StarPromptScene({
    this.onScreen = true,
    this.running = false,
    this.waiting = false,
    this.phoneActive = false,
    this.phoneLastActive,
    this.voice = false,
    this.composing = false,
  });

  /// The app is in front, the chat is the top route (no page, sheet or
  /// dialog over it), the drawer is closed.
  final bool onScreen;

  /// The conversation on screen is busy: a turn runs.
  final bool running;

  /// An approval or a question waits on the person.
  final bool waiting;

  /// Phone control runs.
  final bool phoneActive;

  /// When phone control was last seen running ([starPromptClockProvider]).
  final Duration? phoneLastActive;

  /// Dictation is on.
  final bool voice;

  /// The keyboard is up, or the composer holds something unsent.
  final bool composing;

  /// Phone control runs, or ended moments ago.
  bool phoneAt(Duration now) {
    final last = phoneLastActive;
    return phoneActive || (last != null && now - last < StarPromptRules.phoneCooldown);
  }

  /// Nothing the dialog would interrupt.
  bool quietAt(Duration now) => onScreen && !running && !waiting && !phoneAt(now) && !voice && !composing;

  @override
  String toString() =>
      'StarPromptScene(onScreen: $onScreen, running: $running, waiting: $waiting, phone: $phoneActive '
      '($phoneLastActive), voice: $voice, composing: $composing)';
}

/// Phone control as the native side reports it: a task now, and when one was
/// last seen. Nothing without a native side.
class PhoneTaskSeenController extends Notifier<({bool active, Duration? lastActive})> {
  @override
  ({bool active, Duration? lastActive}) build() {
    final channel = ref.watch(phoneChannelProvider);
    StreamSubscription<Object?>? sub;
    var disposed = false;
    ref.onDispose(() {
      disposed = true;
      unawaited(sub?.cancel());
    });
    unawaited(() async {
      try {
        final status = await channel.status();
        // Listening with no native side reports an error: only once it answered.
        if (disposed || !status.ready) return;
        _apply(status.task);
        sub = channel.statusChanges.listen((s) => _apply(s.task), onError: (_) {});
      } catch (_) {
        // No platform channels at all.
      }
    }());
    return (active: false, lastActive: null);
  }

  void _apply(PhoneTaskStatus task) {
    if (!ref.mounted) return;
    if (task.active || state.active) {
      state = (active: task.active, lastActive: ref.read(starPromptClockProvider)());
    }
  }
}

final phoneTaskSeenProvider = NotifierProvider<PhoneTaskSeenController, ({bool active, Duration? lastActive})>(
  PhoneTaskSeenController.new,
);

/// The scene from app state. Watching it keeps its sources alive, so the
/// host holds it while the switch is on.
final starPromptSceneProvider = Provider<StarPromptScene>((ref) {
  final phone = ref.watch(phoneTaskSeenProvider);
  final session = ref.watch(currentSessionProvider);
  final draft = ref.watch(draftStoreProvider.select((s) => s.drafts[session ?? 'new']));
  return StarPromptScene(
    onScreen: ref.watch(appForegroundProvider) && ref.watch(chatOnScreenProvider),
    running: ref.watch(petFocusProvider)?.running ?? false,
    waiting: ref.watch(petPendingProvider).isNotEmpty,
    phoneActive: phone.active,
    phoneLastActive: phone.lastActive,
    voice: ref.watch(voiceInputActiveProvider),
    composing: draft != null && (draft.text.trimLeft().isNotEmpty || draft.attachments.isNotEmpty),
  );
});

// ── Opening GitHub ───────────────────────────────────────────────────────────

/// Opens a page in the browser; false when none would (tests record it).
final starLinkOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false),
);
