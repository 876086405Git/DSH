// 设置 › 系统权限: the list first run walks, all of it, by feature, with where
// each item stands; a row that isn't on opens the same step first run shows.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../../state/android_features.dart';
import '../access/access_text.dart';
import '../access/access_widgets.dart';
import '../access/system_access_route.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// ```
///   系统权限
///   各项功能用到的系统权限
///   读写手机里的文件
///   ╭ ▢ 允许访问文件                已开启 ╮
///   手机操控
///   ╭ ▢ 打开无障碍                未开启 › ╮
///   │ ▢ 允许通知                  已开启   │
///   ╰ ▢ 允许后台弹出界面          已去设置 › ╯   (vivo, Xiaomi)
///   …
/// ```
///
/// An item two features need (通知) shows under both, with one state.
class SystemAccessPage extends ConsumerStatefulWidget {
  const SystemAccessPage({super.key});

  @override
  ConsumerState<SystemAccessPage> createState() => _SystemAccessPageState();
}

class _SystemAccessPageState extends ConsumerState<SystemAccessPage> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Back from system settings: read everything again.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(ref.read(accessReadingsProvider.notifier).refresh()));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(accessReadingsProvider.notifier).refresh());
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final readings = ref.watch(accessReadingsProvider).value;
    final visited = ref.watch(accessVisitedProvider);
    final os = ref.watch(operatingSystemProvider);
    return AppPage.list(
      title: l10n.accessPageTitle,
      subtitle: Text(
        os == 'ohos'
            ? l10n.harmonyAccessSubtitle
            : os == 'ios'
            ? l10n.iosAccessSubtitle
            : l10n.accessPageSubtitle,
      ),
      children: [
        if (readings != null)
          for (final feature in accessFeaturesFor(os))
            if ([
                  for (final item in accessItemsFor(feature, readings.vendor))
                    if (accessStateOf(item, readings, visited) case final state?)
                      AccessItemTile(
                        item: item,
                        state: state,
                        vendor: readings.vendor,
                        onTap: () => unawaited(openAccessItem(context, item)),
                      ),
                ]
                case final rows when rows.isNotEmpty)
              SettingsSection(
                key: ValueKey('access-section-${feature.name}'),
                title: feature.title(l10n),
                children: rows,
              ),
      ],
    );
  }
}
