// Shared setup for the pet tests: the shipped packs read straight from disk,
// sheets decoded ahead (decoding needs real async), and a chat-bottom
// harness: a page with a list stand-in, the run strip, the composer and the
// pet stage over them, as on the chat page.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/pets/pet_mood.dart';
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/run_info.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

export '../chat/support/harness.dart' show testApp, usePhoneView, testTheme;

/// A shipped pack, from `assets/pets/<id>/pack.json`.
PetPack diskPack(String id) =>
    PetPack.parse(jsonDecode(File('assets/pets/$id/pack.json').readAsStringSync()) as Map<String, Object?>);

final deepy = diskPack('deepy-whale');
final girl = diskPack('whale-girl');

/// Decodes [anims] of [pack] (default: every animation it may play in a test).
Future<void> warmSheets(WidgetTester tester, PetPack pack, [Iterable<PetAnimation>? anims]) async {
  final all = anims ?? pack.animations.values;
  // Off for every other test (flutter_test_config.dart); the pet's own draw.
  PetSheets.enabled = true;
  PetSheets.instance.pin(pack, pack.animFor(PetStateName.idle));
  await tester.runAsync(() async {
    for (final anim in all) {
      final image = await PetSheets.instance.load(pack, anim, rootBundle);
      image.dispose();
    }
  });
}

/// A fixed clock the test moves by hand.
class TestClock {
  TestClock([DateTime? start]) : now = start ?? DateTime(2026, 10, 25, 15);

  DateTime now;

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}

/// Riverpod overrides that keep the pet off the network: [pack] already
/// loaded, fixed [signals], prefs with [size] / [position], the given clock.
List<Override> petOverrides({
  required PetPack pack,
  required TestClock clock,
  PetSignals? signals,
  PetSize size = PetSize.medium,
  double position = PetPrefs.defaultPosition,
  bool quiet = false,
}) => [
  petClockProvider.overrideWithValue(clock.call),
  petPackProvider.overrideWith((ref, id) async => id == pack.id ? pack : diskPack(id)),
  petPrefsProvider.overrideWith(
    () => FixedPetPrefs(PetPrefs(packId: pack.id, size: size, position: position, quiet: quiet, loaded: true)),
  ),
  testSignalsProvider.overrideWith(() => TestSignals(signals ?? PetSignals(lastInteraction: clock.now))),
  // As the app's own signals do: the last touch on the page counts.
  petSignalsProvider.overrideWith((ref) {
    final s = ref.watch(testSignalsProvider);
    final touched = ref.watch(petInteractionProvider);
    return PetSignals(
      focus: s.focus,
      viewed: s.viewed,
      runs: s.runs,
      pending: s.pending,
      carrying: s.carrying,
      quiet: s.quiet,
      lastInteraction: touched.isAfter(s.lastInteraction) ? touched : s.lastInteraction,
    );
  }),
];

/// The pet's signals, set by hand.
class TestSignals extends Notifier<PetSignals> {
  TestSignals(this.initial);

  final PetSignals initial;

  @override
  PetSignals build() => initial;

  void set(PetSignals value) => state = value;
}

final testSignalsProvider = NotifierProvider<TestSignals, PetSignals>(
  () => TestSignals(PetSignals(lastInteraction: DateTime(2026))),
);

/// Prefs that start as given and keep changes in memory.
class FixedPetPrefs extends PetPrefsController {
  FixedPetPrefs(this.initial);

  final PetPrefs initial;

  @override
  PetPrefs build() => initial;

  @override
  Future<void> setPack(String id) async => state = state.copyWith(packId: id, clearHidden: true);

  @override
  Future<void> replacePack(String id) async => state = state.copyWith(packId: id, packExplicit: true);

  @override
  Future<void> setSize(PetSize v) async => state = state.copyWith(size: v);

  @override
  Future<void> setCustomHeight(double dp) async => state = state.copyWith(customHeight: dp);

  @override
  Future<void> setQuiet(bool v) async => state = state.copyWith(quiet: v);

  @override
  Future<void> setPosition(double v) async => state = state.copyWith(position: v.clamp(0.0, 1.0));

  @override
  Future<void> hideUntil(DateTime until) async => state = state.copyWith(hiddenUntil: until);

  @override
  Future<void> unhide() async => state = state.copyWith(clearHidden: true);
}

/// A running-strip activity for the harness.
final stripActivity = RunActivity(
  kind: ActivityKind.tool,
  title: '跑',
  detail: 'flutter test test/auth',
  detailIsCode: true,
  since: DateTime(2026, 10, 25, 14, 59, 50),
  turnStart: DateTime(2026, 10, 25, 14, 59, 13),
);

/// Which bars the harness shows (tests flip them through the container).
class HarnessConfig {
  const HarnessConfig({
    this.strip = false,
    this.dock = false,
    this.cover = false,
    this.avoid = false,
    this.aside = false,
  });

  /// A phone on its side typing: the bars fold toward the composer.
  final bool aside;
  final bool strip;
  final bool dock;
  final bool cover;
  final bool avoid;
}

class HarnessConfigController extends Notifier<HarnessConfig> {
  HarnessConfigController([this.initial = const HarnessConfig()]);

  final HarnessConfig initial;

  @override
  HarnessConfig build() => initial;

  void set(HarnessConfig value) => state = value;
}

final harnessConfigProvider = NotifierProvider<HarnessConfigController, HarnessConfig>(HarnessConfigController.new);

/// The bottom of the chat page as a test sees it: a list stand-in behind
/// (taking every tap that falls through), then the column above the
/// composer, inside a [PetStage].
class ChatBottomHarness extends ConsumerWidget {
  const ChatBottomHarness({super.key, this.onListTap, this.onComposerTap, this.composerController});

  final ValueChanged<Offset>? onListTap;
  final VoidCallback? onComposerTap;
  final TextEditingController? composerController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(harnessConfigProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: AppBackdrop(
        child: PetStage(
          aside: config.aside,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => onListTap?.call(d.globalPosition),
                  child: const _ListStandIn(),
                ),
              ),
              if (config.avoid)
                const Positioned(
                  right: 12,
                  bottom: 96 + 12,
                  child: PetAvoid(child: SizedBox.square(key: ValueKey('jump'), dimension: 44)),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (config.dock)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 6),
                                child: PetPerch(
                                  kind: PerchKind.dock,
                                  child: GlassSurface(
                                    key: ValueKey('dock'),
                                    tier: GlassTier.chrome,
                                    stadium: true,
                                    child: SizedBox(height: 36),
                                  ),
                                ),
                              ),
                            if (config.strip)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: PetPerch(
                                  kind: PerchKind.strip,
                                  // As ActivityStripSlot does: the whale
                                  // steps aside while the pet stands here.
                                  child: Builder(
                                    builder: (context) => ValueListenableBuilder<PerchKind?>(
                                      valueListenable: PetPerchScope.maybeOf(context)!.occupied,
                                      builder: (context, occupied, _) => ActivityStrip(
                                        key: const ValueKey('strip'),
                                        activity: stripActivity,
                                        todoProgress: false,
                                        whale: occupied != PerchKind.strip,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            PetCover(
                              active: config.cover,
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: onComposerTap,
                                child: Composer(
                                  controller: composerController ?? TextEditingController(),
                                  connected: true,
                                  running: false,
                                  onSend: () {},
                                  onStop: () {},
                                  leading: AttachButton(onPressed: () {}),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
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

/// A few lines of conversation so goldens show the pet over real content.
class _ListStandIn extends StatelessWidget {
  const _ListStandIn();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('改好了。登录按钮在请求返回前会保持禁用，重复点击不会再发出第二次请求。', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 12),
          Text('测试 12 项全部通过。', style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// The pet layer's state (foot, perch, hop).
PetLayerState petLayer(WidgetTester tester) => tester.state<PetLayerState>(find.byType(PetLayer));

/// The pet's canvas on screen.
Rect petCanvas(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('pet-body')));

/// Logical px per art px at [size] on the test view.
double petScaleOn(WidgetTester tester, PetPack pack, [PetSize size = PetSize.medium]) {
  final dpr = tester.view.devicePixelRatio;
  int k(PetSize s) => (s.bodyHeight * dpr / pack.contentBox.height).round().clamp(1, 1 << 20);
  final small = k(PetSize.small);
  final medium = [small + 1, k(PetSize.medium)].reduce((a, b) => a > b ? a : b);
  final large = [medium + 1, k(PetSize.large)].reduce((a, b) => a > b ? a : b);
  return switch (size) {
        PetSize.small => small,
        PetSize.medium => medium,
        PetSize.large || PetSize.custom => large,
      } /
      dpr;
}

/// A local conversation target.
PetTarget target(String id) => PetTarget(HostRef.local, id);
