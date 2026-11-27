import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'app_sheet.dart';
import 'sheet_title_bar.dart';

Future<void> showUsagePrivacyNotice(BuildContext context, {required String platform}) => showAppSheet<void>(
  context,
  heightFactor: 0.76,
  builder: (context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('usage-privacy-notice'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetTitleBar(l10n.shellUsagePrivacyNotice, maxLines: null),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 24),
            children: [
              for (final (title, body) in [
                (l10n.shellUsageTermsTitle, l10n.shellUsageTermsBody),
                (l10n.shellUsageDisclaimerTitle, l10n.shellUsageDisclaimerBody),
                (l10n.shellUsagePrivacyTitle, l10n.shellUsagePrivacyBody),
              ]) ...[
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(body, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
              ],
              if (platform != 'ohos') Text(l10n.shellUsagePrivacyStats, style: theme.textTheme.bodyMedium),
              if (platform == 'android') ...[
                const SizedBox(height: 8),
                Text(l10n.shellUsagePrivacyAndroid, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
      ],
    );
  },
);
