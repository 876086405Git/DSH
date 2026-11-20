// 掷骰 (docs/design/roleplay-ui.md §6, §11): pick the dice, roll, and put
// what came up into the composer. The number tumbles a moment before it
// settles (not with reduced motion), with a light tap when it does.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:dsh_tavern/dsh_tavern.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_dice.dart';
import '../../tavern/tavern_preview.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart';
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../common/fluid_bits.dart';
import '../common/sheet_title_bar.dart';
import '../engine_settings/field_sheets.dart' show SheetCard, StepKey;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// The line to put in the composer, or null when closed without one. With
/// [chatId] and a real tavern, the engine rolls (its result is kept, and
/// asked for again rather than thrown again when not settled).
Future<String?> showTavernDice(BuildContext context, {String? chatId}) =>
    showAppSheet<String>(context, isScrollControlled: true, builder: (_) => TavernDiceSheet(chatId: chatId));

/// The line a roll goes into the chat as: 🎲 2d6+1 掷出 9（3 + 5 + 1）.
String tavernRollLine(L10n l10n, TavernRoll roll) =>
    l10n.tavernDiceLine(roll.dice.notation, roll.total, switch (roll.working) {
      final working? => l10n.tavernDiceWorking(working),
      null => '',
    });

class TavernDiceSheet extends ConsumerStatefulWidget {
  const TavernDiceSheet({super.key, this.chatId});

  /// The chat the roll is for: the engine rolls it (STAGE1-APP-INTEGRATION
  /// §4). None, or the preview: rolled here, as before.
  final String? chatId;

  /// How long the number tumbles before it settles.
  static const tumble = Duration(milliseconds: 560);
  static const _tick = Duration(milliseconds: 70);

  @override
  ConsumerState<TavernDiceSheet> createState() => _TavernDiceSheetState();
}

class _TavernDiceSheetState extends ConsumerState<TavernDiceSheet> {
  TavernRoll? _roll;

  /// What the big number says: a passing face while tumbling, else the total.
  String? _shown;
  Timer? _tumble;

  /// Waiting for the engine's result.
  bool _waiting = false;

  /// A word under the dice: not settled, refused, why.
  String? _note;

  /// The roll asked for whose result is not known yet: asked again as it
  /// is (再查一次), or let go (放弃这次); no new throw meanwhile.
  TavernRollIntent? _pending;

  bool get _onEngine => widget.chatId != null && ref.read(tavernProvider) is! TavernPreview;

  @override
  void initState() {
    super.initState();
    if (_onEngine) unawaited(_loadPending());
  }

  Future<void> _loadPending() async {
    final pending = await tavernRollIntent(widget.chatId!);
    if (!mounted || pending == null) return;
    setState(() {
      _pending = pending;
      _note = context.l10n.tavernDicePending;
    });
  }

  @override
  void dispose() {
    _tumble?.cancel();
    super.dispose();
  }

  bool get _rolling => _tumble != null || _waiting;

  void _choose(TavernDice dice) {
    // A roll still out lands as the dice it was asked with, not as these.
    if (_rolling) return;
    ref.read(tavernDiceProvider.notifier).set(dice);
    // A new choice: what was rolled before no longer goes with it.
    _tumble?.cancel();
    setState(() {
      _tumble = null;
      _roll = null;
      _shown = null;
    });
  }

  void _throw() {
    final dice = ref.read(tavernDiceProvider);
    if (_onEngine) {
      final intent = TavernRollIntent(chatId: widget.chatId!, actionId: tavernNewId(), dice: dice.notation);
      unawaited(_ask(intent, dice, keep: true));
      return;
    }
    final random = ref.read(tavernDiceRandomProvider);
    final roll = dice.roll(random);
    _tumble?.cancel();
    void land() {
      _tumble?.cancel();
      setState(() {
        _tumble = null;
        _roll = roll;
        _shown = '${roll.total}';
      });
      unawaited(HapticFeedback.lightImpact());
    }

    if (AppMotion.reduced(context)) {
      land();
      return;
    }
    var left = TavernDiceSheet.tumble.inMilliseconds ~/ TavernDiceSheet._tick.inMilliseconds;
    setState(() {
      _tumble = Timer.periodic(TavernDiceSheet._tick, (_) {
        if (!mounted) return;
        if (--left <= 0) {
          land();
        } else {
          setState(() => _shown = '${dice.lowest + random.nextInt(dice.highest - dice.lowest + 1)}');
        }
      });
    });
  }

  /// The engine rolls [intent] (kept first when new): the number tumbles
  /// until its result is in, at least as long as a throw here does, then
  /// lands on the engine's faces. Not settled, it waits to be asked again.
  Future<void> _ask(TavernRollIntent intent, TavernDice dice, {bool keep = false}) async {
    final l10n = context.l10n;
    final random = ref.read(tavernDiceRandomProvider);
    final reduced = AppMotion.reduced(context);
    final tavern = ref.read(tavernProvider);
    _tumble?.cancel();
    setState(() {
      _waiting = true;
      _note = null;
      _roll = null;
      _shown = null;
      if (!reduced) {
        _tumble = Timer.periodic(TavernDiceSheet._tick, (_) {
          if (mounted) setState(() => _shown = '${dice.lowest + random.nextInt(dice.highest - dice.lowest + 1)}');
        });
      }
    });
    final shortest = Future<void>.delayed(reduced ? Duration.zero : TavernDiceSheet.tumble);
    TavernRoll? landed;
    String? note;
    var pending = false;
    try {
      // Not sent unless kept: a roll the app could not keep could not be
      // asked about again.
      if (keep) await tavernKeepRollIntent(intent);
      final receipt = await intent.submit(tavern);
      switch (receipt.committed) {
        case true:
          landed = TavernRoll(dice, [
            for (final v in (receipt.result?['values'] as List<Object?>?) ?? const <Object?>[])
              if (v is num) v.toInt(),
          ]);
          await tavernForgetRollIntent(intent.chatId);
        case null:
          pending = true;
          note = l10n.tavernDiceUnsettled;
        case false:
          await tavernForgetRollIntent(intent.chatId);
          note = l10n.tavernDiceFailed('${receipt.error?['message'] ?? receipt.status}');
      }
    } on TavernToolException catch (e) {
      if (e.code == TavernToolErrorCode.storageFailure) {
        pending = true;
        note = l10n.tavernDiceNotSaved(e.message);
      } else {
        await tavernForgetRollIntent(intent.chatId);
        note = switch (e.code) {
          TavernToolErrorCode.busy => l10n.tavernDiceBusy,
          TavernToolErrorCode.policyDisabled => l10n.tavernDiceOff,
          _ => l10n.tavernDiceFailed(e.message),
        };
      }
    } on Exception catch (e) {
      // Keeping it failed (the app's storage), before anything was sent.
      note = l10n.tavernDiceNotSaved('$e');
    }
    await shortest;
    if (!mounted) return;
    _tumble?.cancel();
    setState(() {
      _tumble = null;
      _waiting = false;
      _note = note;
      _pending = pending ? intent : null;
      _roll = landed;
      _shown = landed == null ? null : '${landed.total}';
    });
    if (landed != null) unawaited(HapticFeedback.lightImpact());
  }

  /// 放弃这次: the roll not settled is let go; its result, whatever it was,
  /// is not used here.
  Future<void> _forgetPending() async {
    final chat = widget.chatId;
    if (chat != null) await tavernForgetRollIntent(chat);
    if (mounted) {
      setState(() {
        _pending = null;
        _note = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final dice = ref.watch(tavernDiceProvider);
    final pending = _pending;
    final roll = _roll;
    // While it tumbles, nothing is settled yet.
    final settled = _rolling ? null : roll;
    final working = settled?.working;
    final big = AppType.tabular(theme.textTheme.displaySmall!.copyWith(fontWeight: FontWeight.w600));
    final label = theme.textTheme.bodyLarge;
    final value = AppType.tabular(theme.textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w600));

    Widget stepper({
      required String title,
      required String shown,
      required String fewer,
      required String more,
      required VoidCallback? onFewer,
      required VoidCallback? onMore,
      required String name,
    }) => Row(
      children: [
        Expanded(child: Text(title, style: label)),
        StepKey(key: ValueKey('tavern-dice-$name-down'), icon: AppIcons.decrement, tooltip: fewer, onPressed: onFewer),
        SizedBox(
          width: 56,
          child: Text(shown, key: ValueKey('tavern-dice-$name'), textAlign: TextAlign.center, style: value),
        ),
        StepKey(key: ValueKey('tavern-dice-$name-up'), icon: AppIcons.increment, tooltip: more, onPressed: onMore),
      ],
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitleBar(l10n.tavernDice),
            Padding(
              padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // What came up.
                  SheetCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                    child: Semantics(
                      liveRegion: true,
                      label: settled == null ? dice.notation : tavernRollLine(l10n, settled),
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 56,
                            child: Center(
                              child: _shown == null
                                  ? Text(dice.notation, style: big.copyWith(color: dsh.textTertiary))
                                  : RollingCount(_shown!, key: const ValueKey('tavern-dice-total'), style: big),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            settled == null ? ' ' : (working == null ? dice.notation : '${dice.notation} · $working'),
                            key: const ValueKey('tavern-dice-working'),
                            textAlign: TextAlign.center,
                            style: AppType.tabular(
                              theme.textTheme.bodyMedium!.copyWith(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_note case final note?)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        note,
                        key: const ValueKey('tavern-dice-note'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
                      ),
                    ),
                  if (pending != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          key: const ValueKey('tavern-dice-forget'),
                          onPressed: _rolling ? null : () => unawaited(_forgetPending()),
                          child: Text(l10n.tavernDiceForget),
                        ),
                        TextButton(
                          key: const ValueKey('tavern-dice-recheck'),
                          onPressed: _rolling
                              ? null
                              : () => unawaited(_ask(pending, TavernDice.parse(pending.dice) ?? dice)),
                          child: Text(l10n.tavernDiceRecheck),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  // Centred under the result, as its number is.
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sides in tavernDiceSides)
                        CapsuleChoiceChip(
                          key: ValueKey('tavern-dice-d$sides'),
                          label: 'd$sides',
                          selected: dice.sides == sides,
                          onSelected: () => _choose(dice.copyWith(sides: sides)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  stepper(
                    name: 'count',
                    title: l10n.tavernDiceCount,
                    shown: '${dice.count}',
                    fewer: l10n.tavernDiceFewer,
                    more: l10n.tavernDiceMore,
                    onFewer: dice.count > 1 ? () => _choose(dice.copyWith(count: dice.count - 1)) : null,
                    onMore: dice.count < tavernDiceMaxCount
                        ? () => _choose(dice.copyWith(count: dice.count + 1))
                        : null,
                  ),
                  const SizedBox(height: 12),
                  stepper(
                    name: 'modifier',
                    title: l10n.tavernDiceModifier,
                    shown: dice.modifier > 0 ? '+${dice.modifier}' : '${dice.modifier}',
                    fewer: l10n.tavernDiceModifierDown,
                    more: l10n.tavernDiceModifierUp,
                    onFewer: dice.modifier > -tavernDiceMaxModifier
                        ? () => _choose(dice.copyWith(modifier: dice.modifier - 1))
                        : null,
                    onMore: dice.modifier < tavernDiceMaxModifier
                        ? () => _choose(dice.copyWith(modifier: dice.modifier + 1))
                        : null,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: roll == null
                            ? FilledButton(
                                key: const ValueKey('tavern-dice-roll'),
                                onPressed: _rolling || pending != null ? null : _throw,
                                child: Text(l10n.tavernDiceRoll),
                              )
                            : OutlinedButton(
                                key: const ValueKey('tavern-dice-roll'),
                                onPressed: _rolling || pending != null ? null : _throw,
                                child: Text(l10n.tavernDiceAgain),
                              ),
                      ),
                      if (roll != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('tavern-dice-use'),
                            onPressed: _rolling ? null : () => Navigator.of(context).pop(tavernRollLine(l10n, roll)),
                            child: Text(l10n.tavernDiceUse),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
