// A number the person steps down and up — a prompt's depth, a lorebook
// entry's chance — between [min] and [max], each tap saved by the caller.
// Tapping the number itself types one.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'tavern_number_tile.dart';

/// − value +. Keys: `$keyName-down`, `$keyName-value`, `$keyName-up`.
class TavernStepper extends StatelessWidget {
  const TavernStepper({
    super.key,
    required this.keyName,
    required this.value,
    required this.onChanged,
    this.min = 0,
    required this.max,
    this.step = 1,
    this.suffix = '',
    this.label,
  });

  /// The typing dialog's title: the row's own title, when the caller has one.
  final String? label;

  final String keyName;
  final int value;
  final int min;
  final int max;
  final int step;

  /// After the number: `%`, say.
  final String suffix;
  final ValueChanged<int> onChanged;

  Future<void> _type(BuildContext context) async {
    final number = await showTavernNumberPrompt(
      context,
      title: label ?? context.l10n.tavernNumberType,
      min: min,
      max: max,
      initial: value,
      integer: true,
    );
    if (number != null && number != value) onChanged(number.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('$keyName-down'),
          icon: const Icon(AppIcons.decrement, size: 18),
          onPressed: value > min ? () => onChanged((value - step).clamp(min, max)) : null,
        ),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => unawaited(_type(context)),
          child: SizedBox(
            width: 48,
            height: 40,
            child: Center(
              child: Text(
                '$value$suffix',
                key: ValueKey('$keyName-value'),
                textAlign: TextAlign.center,
                style: AppType.tabular(theme.textTheme.titleMedium!),
              ),
            ),
          ),
        ),
        IconButton(
          key: ValueKey('$keyName-up'),
          icon: const Icon(AppIcons.increment, size: 18),
          onPressed: value < max ? () => onChanged((value + step).clamp(min, max)) : null,
        ),
      ],
    );
  }
}
