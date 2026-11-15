import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'dev/frame_probe.dart';
import 'diagnostics/app_error_log.dart';
import 'launch/launch_state.dart';
import 'links/page_links.dart' show registerPageLink, tavernPageLink;
import 'runtime/local_paths.dart';
import 'state/locale_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/fx/metal/metal_shader.dart';
import 'ui/fx/waves/distortion_wave.dart';
import 'ui/settings/font_licenses.dart';
import 'ui/tavern/tavern_home_page.dart';
import 'ui/theme/theme.dart';

Future<void> main() => runWithFrameProbe(_startApp);

Future<void> _startApp() async {
  if (!frameProbeEnabled) SteadyFrameBinding();
  WidgetsFlutterBinding.ensureInitialized();
  appErrorCapture.install();
  // The first frame is already in the chosen language (设置 → 语言), and is the launch
  // window's own picture (启动画面, lib/launch/launch_state.dart).
  await Future.wait([AppLanguageController.load(), LaunchController.begin(), LocalPaths.load()]);
  // MIT / OFL notices must ship with the APK, not just the sources.
  registerThirdPartyLicenses();
  registerFontLicenses();
  // dshgo://open/tavern: the page lives in ui/, which links/ does not import.
  registerPageLink(tavernPageLink, () => const TavernHomePage());
  // The effects' shaders load now, so the first wave or metal word is not a plain fallback.
  unawaited(DistortionWave.precache());
  unawaited(MetalShader.load());
  // Edge-to-edge with transparent system bars; pages refine the icon brightness
  // through AnnotatedRegion(dshSystemOverlay(...)).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(dshSystemOverlay(PlatformDispatcher.instance.platformBrightness));
  runApp(const ProviderScope(child: DshApp()));
}
