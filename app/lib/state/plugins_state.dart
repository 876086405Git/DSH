import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../runtime/runtime_state.dart';
import '../share_code/share_net.dart';
import '../update/version.dart';
import '../usage/usage_stats.dart';
import 'android_features.dart';
import 'app_info.dart';
import 'connection_state.dart';
import 'market_sidecar.dart';

export 'market_sidecar.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'runtime_capabilities_state.dart';
import 'engine_error_text.dart';
import 'hosts_state.dart';

part 'plugins/plugin_market.dart';
part 'plugins/installed_plugins.dart';
part 'plugins/plugin_failures.dart';
part 'plugins/plugin_install_queue.dart';

/// Plugin management and the plugin market for the active host.
///
/// Writes go through `pluginManager/*` (the only write path DSH has, the same
/// on every host). The market is a format-1 index read by the app itself, so
/// it works on hosts without the experimental `pluginMarket` bundle and over
/// the relay.

/// Default market: dshfind's format-1 index (attribution "数据来自 dshfind").
const dshfindIndexUrl = 'https://api.dshfind.com/market/dsh-index.json';

/// Profile `dsh web` runs with; the app starts every host it drives that way.
const pluginProfile = 'web';

/// Install command for hosts the app cannot install on (relay).
String pluginInstallCommand(String spec) => 'dsh plugin --profile $pluginProfile add $spec';
