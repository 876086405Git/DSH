// The open-source licences page: every bundled third-party notice is registered once,
// with the copyright line and licence THIRD_PARTY_NOTICES.md gives it.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/ui/common/third_party_licenses.dart';
import 'package:dsh_app/ui/settings/font_licenses.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Package name → a line its entry must carry, also found in THIRD_PARTY_NOTICES.md.
const _expected = <String, String>{
  'Google ML Kit Text Recognition (Chinese)': 'com.google.mlkit:text-recognition-chinese:16.0.1',
  'PiPilot': 'Copyright (c) 2026 CikeSeven',
  'Unicode Character Database (15.0.0)': 'Copyright © 1991-2026 Unicode, Inc.',
  'DeepSeek Harness': 'Copyright (c) 2026 DeepSeek',
  'Phase': 'Copyright (c) 2026 CikeSeven',
  'DS Bot': 'Copyright 2026 Fei2411 and the DS Bot contributors',
  'ds-harness-remote': 'Copyright (c) 2026 DSH Remote contributors',
  'DSHA': 'Copyright (c) 2026 qiannianhuanxiang',
  'Libraries.dev': 'Copyright (c) 2026 Jakub Antalik',
  'Paper Shaders': 'Copyright (c) Paper Design, Inc.',
  'Shizuku-API': 'Copyright (c) 2021 RikkaW',
  'tawcroot (tawc)': 'Copyright (c) 2026 Sophie Winter',
  'libadb-android': 'Copyright 2021 Muntashir Al-Islam',
  'spake2-android': 'Copyright 2021 Muntashir Al-Islam',
  'Conscrypt': 'Copyright 2016 The Android Open Source Project',
  'Bouncy Castle': 'Copyright (c) 2000-2023 The Legion of the Bouncy Castle Inc.',
  'XZ for Java': 'Copyright (C) The XZ for Java authors and contributors',
  'AndroidX WebKit': 'The Android Open Source Project',
  'ONNX Runtime': 'Copyright (c) Microsoft Corporation',
  'Silero VAD': 'Copyright (c) 2020-present Silero Team',
  'smart-turn': 'Copyright (c) 2024–2025, Daily',
  'flutter_webrtc': 'Copyright (c) 2015 Howard Yang',
  'WebRTC': 'Copyright (c) 2011, The WebRTC project authors',
  'AudioSwitch': 'Copyright 2020 Twilio, inc.',
  'Phosphor Icons': 'Copyright (c) 2023 Phosphor Icons',
  'Material Icons': 'Google',
  'discourse-emojis': 'Joffrey Jaffeux',
  'JetBrains Mono': 'Copyright 2020 The JetBrains Mono Project Authors',
  'jQuery': 'Copyright OpenJS Foundation and other contributors, https://openjsf.org/',
  'Lodash': 'Copyright OpenJS Foundation and other contributors <https://openjsf.org/>',
  'Streaming Zipformer zh-en (sherpa-onnx)': 'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20',
};

const _mit = 'Permission is hereby granted, free of charge';
const _apache = 'Apache License\n                           Version 2.0, January 2004';
const _lgpl = 'GNU LESSER GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007';
const _gpl = 'GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<LicenseEntryWithLineBreaks> entries;

  setUpAll(() async {
    LicenseRegistry.reset();
    registerThirdPartyLicenses();
    registerFontLicenses();
    entries = (await LicenseRegistry.licenses.toList()).cast<LicenseEntryWithLineBreaks>();
  });
  tearDownAll(LicenseRegistry.reset);

  String textOf(String package) => entries.singleWhere((e) => e.packages.contains(package)).text;

  group('on HarmonyOS', () {
    late List<LicenseEntryWithLineBreaks> harmony;
    const gradle = [
      'Google ML Kit Text Recognition (Chinese)',
      'Shizuku-API',
      'libadb-android',
      'spake2-android',
      'Conscrypt',
      'Bouncy Castle',
      'XZ for Java',
      'AndroidX WebKit',
      'ONNX Runtime',
      'Silero VAD',
      'smart-turn',
      'tawcroot (tawc)',
      'flutter_webrtc',
      'AudioSwitch',
      'WebRTC',
      'Streaming Zipformer zh-en (sherpa-onnx)',
    ];

    setUp(() async {
      LicenseRegistry.reset();
      registerThirdPartyLicenses(os: 'ohos');
      harmony = (await LicenseRegistry.licenses.toList()).cast<LicenseEntryWithLineBreaks>();
    });
    tearDown(() async {
      LicenseRegistry.reset();
      registerThirdPartyLicenses();
      registerFontLicenses();
    });

    test('what Gradle bundles for the APK isn\'t listed, and what the HAP carries is', () {
      final names = {for (final entry in harmony) ...entry.packages};
      for (final name in gradle) {
        expect(names, isNot(contains(name)), reason: name);
      }
      expect(names, containsAll(['Node.js', 'HarmonyOS runtime packages', 'DS Bot', 'Libraries.dev', 'Phosphor Icons']));
    });

    test('Node says whose it is and its terms; each package once', () {
      final node = harmony.singleWhere((e) => e.packages.contains('Node.js')).text;
      expect(node, contains('Copyright Node.js contributors'));
      expect(node, contains(_mit));
      final names = [for (final entry in harmony) ...entry.packages];
      expect(names.toSet(), hasLength(names.length));
    });

    test('the packages\' texts it points at are in the source', () {
      final runtime = harmony.singleWhere((e) => e.packages.contains('HarmonyOS runtime packages')).text;
      expect(runtime, contains('runtime/ohos/licenses/texts'));
      expect(Directory('../runtime/ohos/licenses/texts').existsSync(), isTrue);
    });
  });

  test('WebRTC entry exposes the complete upstream asset without truncation', () {
    final file = File('assets/licenses/webrtc-150.7871.04.md');
    final bundle = file.readAsStringSync();
    expect(
      sha256.convert(file.readAsBytesSync()).toString(),
      'd1f9382c6878ac024155fd6d44a5977329108bb8b0a01cea40e4a2f1d7de252e',
    );
    expect(textOf('WebRTC'), endsWith(bundle));
    expect(RegExp(r'^# ', multiLine: true).allMatches(bundle).length, 30);
    expect(bundle, contains('# boringssl'));
    expect(bundle, contains('# zlib'));
  });

  test('ML Kit carries its SDK terms rather than sample-code Apache terms', () {
    final notice = textOf('Google ML Kit Text Recognition (Chinese)');
    expect(notice, contains('https://developers.google.com/ml-kit/terms'));
    expect(notice, contains('https://developers.google.com/ml-kit/android-data-disclosure'));
    expect(notice, contains('previously accumulated SDK statistics'));
    expect(notice, isNot(contains(_apache)));
  });

  test('each package is registered exactly once', () {
    final names = [for (final entry in entries) ...entry.packages];
    final repeated = {
      for (final name in names)
        if (names.where((n) => n == name).length > 1) name,
    };
    expect(repeated, isEmpty);
  });

  test('every bundled third-party notice is listed', () {
    final names = {for (final entry in entries) ...entry.packages};
    expect(names, _expected.keys.toSet());
  });

  test('attribution and identity lines agree with THIRD_PARTY_NOTICES.md', () {
    final notices = File('../THIRD_PARTY_NOTICES.md').readAsStringSync();
    for (final MapEntry(key: package, value: line) in _expected.entries) {
      expect(textOf(package), contains(line), reason: package);
      expect(notices, contains(line), reason: package);
    }
  });

  test('each entry carries its own licence text', () {
    for (final package in [
      'PiPilot',
      'DeepSeek Harness',
      'ds-harness-remote',
      'DSHA',
      'Shizuku-API',
      'Phosphor Icons',
      'discourse-emojis',
    ]) {
      expect(textOf(package), contains(_mit), reason: package);
      expect(textOf(package), isNot(contains('Apache License')), reason: package);
    }
    for (final package in [
      'DS Bot',
      'libadb-android',
      'Conscrypt',
      'AndroidX WebKit',
      'flutter_webrtc',
      'AudioSwitch',
      'Material Icons',
    ]) {
      expect(textOf(package), contains(_apache), reason: package);
    }
    expect(textOf('spake2-android'), allOf(contains(_lgpl), contains(_gpl)));
    expect(
      textOf('Phase'),
      allOf(contains("with the author's permission"), contains('Copyright (c) 2026 CikeSeven'), contains(_mit)),
    );
    expect(textOf('Bouncy Castle'), contains(_mit));
    expect(textOf('flutter_webrtc'), contains(_mit));
    expect(textOf('WebRTC'), allOf(contains('Neither the name of Google'), contains('Additional IP Rights Grant')));
    expect(textOf('XZ for Java'), contains('Permission to use, copy, modify, and/or distribute'));
    expect(textOf('JetBrains Mono'), contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(textOf('Unicode Character Database (15.0.0)'), File('tool/unicode-15.0-LICENSE.txt').readAsStringSync());
    // The canvas libraries: their own LICENSE files, as published (npm tarball integrity in
    // THIRD_PARTY_NOTICES.md), and the shipped builds those files go with.
    for (final (package, license, build, licenseSha, buildSha) in [
      (
        'jQuery',
        'assets/licenses/jquery-3.7.1-LICENSE.txt',
        'assets/tavern/jquery-3.7.1.min.js',
        'd4db9ebe6f29f5168eac45ad713f055623ac5d0dcd5ba92da23d650ae012020d',
        'fc9a93dd241f6b045cbff0481cf4e1901becd0e12fb45166a8f17f95823f0b1a',
      ),
      (
        'Lodash',
        'assets/licenses/lodash-4.17.21-LICENSE.txt',
        'assets/tavern/lodash-4.17.21.min.js',
        'f71e8ed126b46346494aad5486874cd8f0aafe95092ed67d2e3cb6110f939abc',
        'a9705dfc47c0763380d851ab1801be6f76019f6b67e40e9b873f8b4a0603f7a9',
      ),
    ]) {
      expect(textOf(package), File(license).readAsStringSync(), reason: package);
      expect(textOf(package), contains(_mit), reason: package);
      expect(sha256.convert(File(license).readAsBytesSync()).toString(), licenseSha, reason: license);
      expect(sha256.convert(File(build).readAsBytesSync()).toString(), buildSha, reason: build);
    }
  });
}
