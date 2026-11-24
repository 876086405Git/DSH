import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/media/gallery.dart';
import 'package:dsh_app/media/video.dart';
import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/ui/chat/media/media_video_viewer.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _item = MediaItem(path: '/host/movie.mp4', mime: 'video/mp4');
const _handle = MediaVideoHandle(texture: 17, width: 1920, height: 1080, durationMs: 5000);

class _Files extends ArtifactFiles {
  _Files({this.local = false}) : super(connection: null, channel: const FilesChannel());
  final bool local;
  int reads = 0;
  int external = 0;
  @override
  bool get isLocal => local;
  @override
  Future<File> materialize(
    String sessionId,
    Artifact artifact, {
    void Function(double?)? onProgress,
    int maxBytes = maxRemoteArtifactBytes,
  }) async {
    reads++;
    onProgress?.call(0.5);
    return File('/phone/movie.mp4');
  }

  @override
  Future<void> open(
    String sessionId,
    Artifact artifact, {
    bool chooser = false,
    void Function(double?)? onProgress,
  }) async {
    external++;
  }
}

class _Video extends MediaVideoChannel {
  int posters = 0;
  int plays = 0;
  int pauses = 0;
  int closes = 0;
  int opens = 0;
  int position = 0;
  int duration = 5000;
  int seeks = 0;
  bool playing = false;
  bool failOpen = false;
  String failCode = 'failed';
  Completer<MediaVideoHandle>? delayedOpen;
  @override
  Future<Uint8List?> poster(String path) async {
    posters++;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<MediaVideoHandle> open(String path) async {
    opens++;
    if (failOpen) throw PlatformException(code: failCode);
    return delayedOpen == null ? _handle : delayedOpen!.future;
  }

  @override
  Future<void> play(int texture) async {
    plays++;
    playing = true;
  }

  @override
  Future<void> pause(int texture) async {
    pauses++;
    playing = false;
  }

  @override
  Future<void> close(int texture) async {
    closes++;
    playing = false;
  }

  @override
  Future<void> seek(int texture, int positionMs) async {
    seeks++;
    position = positionMs;
  }

  @override
  Future<MediaVideoState> state(int texture) async =>
      MediaVideoState(positionMs: position, durationMs: duration, playing: playing);
}

Future<void> _pumpViewer(WidgetTester tester, _Files files, MediaVideoChannel video) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaVideoViewerPage(
        sessionId: 's1',
        item: _item,
        files: files,
        video: video,
        gallery: const MediaChannel(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing native video decoder is reported as unsupported', () async {
    const video = MediaVideoChannel(MethodChannel('dsh/test-unregistered-video'));
    await expectLater(
      video.open('/phone/movie.mp4'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported')),
    );
    expect(await video.poster('/phone/movie.mp4'), isNull);
  });

  test('channel rejects URL and relative paths without platform invocation', () async {
    const video = MediaVideoChannel();
    for (final path in [
      'https://example.com/movie.mp4',
      'file:///tmp/movie.mp4',
      'content://media/1',
      'relative.mp4',
    ]) {
      expect(() => video.poster(path), throwsArgumentError);
      await expectLater(video.open(path), throwsArgumentError);
    }
  });

  test('channel forwards local texture controls, seek and state', () async {
    const channel = MethodChannel('test/video');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'open' => {'texture': 17, 'width': 1920, 'height': 1080, 'durationMs': 5000},
        'state' => {'positionMs': 1200, 'durationMs': 5000, 'playing': true},
        _ => null,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const video = MediaVideoChannel(channel);
    final handle = await video.open('/phone/movie.mp4');
    expect(handle.aspectRatio, 1920 / 1080);
    expect(handle.rotation, 0);
    await video.play(handle.texture);
    await video.seek(handle.texture, 1200);
    expect((await video.state(handle.texture)).positionMs, 1200);
    await video.pause(handle.texture);
    await video.close(handle.texture);
    expect(calls.map((c) => c.method), ['open', 'play', 'seek', 'state', 'pause', 'close']);
    expect(calls[2].arguments, {'texture': 17, 'positionMs': 1200});
  });

  test('remote scrolling never materializes or extracts a poster', () async {
    final files = _Files();
    final video = _Video();
    expect(await mediaVideoThumbnail(files, video, 's1', _item), isNull);
    expect(files.reads, 0);
    expect(video.posters, 0);
    final poster = await cacheMediaVideoThumbnail(files, video, 's1', _item, materialized: File('/phone/movie.mp4'));
    expect(poster, isA<MemoryImage>());
    expect(await mediaVideoThumbnail(files, video, 's1', _item), same(poster));
    expect(files.reads, 0);
    expect(video.posters, 1);
    // Same path on another Host snapshot must not see the first Host's poster.
    expect(await mediaVideoThumbnail(_Files(), video, 's1', _item), isNull);
  });

  test('local thumbnails materialize once and deduplicate extraction', () async {
    final files = _Files(local: true);
    final video = _Video();
    final one = mediaVideoThumbnail(files, video, 's1', _item);
    final two = mediaVideoThumbnail(files, video, 's1', _item);
    expect(await one, same(await two));
    expect(files.reads, 1);
    expect(video.posters, 1);
  });

  test('concurrent local video cards serialize decoder requests without dropping posters', () async {
    const channel = MethodChannel('test/concurrent-video-posters');
    var active = 0;
    var maximum = 0;
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      active++;
      calls++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return Uint8List.fromList([1, 2, 3]);
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    final files = _Files(local: true);
    final posters = await Future.wait([
      for (var i = 0; i < 3; i++)
        mediaVideoThumbnail(files, const MediaVideoChannel(channel), 's1', MediaItem(path: '/host/movie-$i.mp4')),
    ]);
    expect(posters, everyElement(isA<MemoryImage>()));
    expect(calls, 3);
    expect(maximum, 1);
    expect(files.reads, 3);
  });

  test('poster queue continues after an extraction failure', () async {
    const channel = MethodChannel('test/poster-error-queue');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (++calls == 1) throw PlatformException(code: 'timeout');
      return Uint8List.fromList([1]);
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    const video = MediaVideoChannel(channel);
    final failed = video.poster('/phone/one.mp4');
    final next = video.poster('/phone/two.mp4');
    await expectLater(failed, throwsA(isA<PlatformException>()));
    expect(await next, isNotNull);
    expect(calls, 2);
  });

  test('video gallery save sends path not complete video bytes', () async {
    const channel = MethodChannel('test/gallery-video');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return 'Movies/DSH Go/movie.mp4';
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    expect(
      await const MediaChannel(channel).saveVideoFile('/phone/movie.mp4', name: 'movie.mp4'),
      'Movies/DSH Go/movie.mp4',
    );
    expect(captured!.method, 'saveVideoFile');
    expect(captured!.arguments, {'path': '/phone/movie.mp4', 'name': 'movie.mp4'});
  });

  test('time labels clamp negative position', () {
    expect(mediaVideoTime(-1), '0:00');
    expect(mediaVideoTime(65_999), '1:05');
  });

  testWidgets('90 degree video rotation keeps display ratio and swaps the texture constraints', (tester) async {
    const channel = MethodChannel('test/video-rotation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'open' => {'texture': 17, 'width': 1080, 'height': 1920, 'durationMs': 5000, 'rotation': 90},
        'state' => {'positionMs': 0, 'durationMs': 5000, 'playing': false},
        _ => null,
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );
    await _pumpViewer(tester, _Files(), const MediaVideoChannel(channel));
    final texture = find.byType(Texture);
    final rotated = find.ancestor(of: texture, matching: find.byType(RotatedBox));
    final display = find.ancestor(of: texture, matching: find.byType(AspectRatio));
    expect(tester.widget<RotatedBox>(rotated).quarterTurns, 1);
    expect(tester.widget<AspectRatio>(display).aspectRatio, 1080 / 1920);
    final displaySize = tester.getSize(rotated);
    final textureSize = tester.getSize(texture);
    expect(textureSize.width, closeTo(displaySize.height, 0.001));
    expect(textureSize.height, closeTo(displaySize.width, 0.001));
    expect(textureSize.width / textureSize.height, closeTo(1920 / 1080, 0.000001));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('late prepared player is released after viewer disposal', (tester) async {
    final files = _Files();
    final video = _Video()..delayedOpen = Completer<MediaVideoHandle>();
    await _pumpViewer(tester, files, video);
    expect(video.opens, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    video.delayedOpen!.complete(_handle);
    await tester.pump();
    expect(video.closes, 1);
    expect(video.plays, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported native playback offers saving or opening elsewhere without a futile retry', (tester) async {
    final files = _Files();
    final video = _Video()
      ..failOpen = true
      ..failCode = 'unsupported';
    await _pumpViewer(tester, files, video);
    expect(find.text(appL10n.mediaVideoUnsupported), findsOneWidget);
    expect(find.text(appL10n.commonRetry), findsNothing);
    await tester.tap(find.text(appL10n.mediaOpenElsewhere));
    await tester.pump();
    expect(files.external, 1);
  });

  testWidgets('temporary playback failure can retry', (tester) async {
    final files = _Files();
    final video = _Video()..failOpen = true;
    await _pumpViewer(tester, files, video);
    expect(find.text(appL10n.mediaVideoCannotPlay), findsOneWidget);
    video.failOpen = false;
    await tester.tap(find.text(appL10n.commonRetry));
    await tester.pump();
    await tester.pump();
    expect(video.opens, 2);
    expect(files.reads, 1);
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.closes, 1);
  });

  testWidgets('playback ticks and slider drags update the controls without rebuilding the viewer', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final video = _Video();
    await _pumpViewer(tester, _Files(), video);
    final slider = find.byType(Slider);
    double position() => tester.widget<Slider>(slider).value;
    var pages = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is MediaVideoViewerPage) pages++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);

    for (var tick = 1; tick <= 19; tick++) {
      video.position = tick * 100;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(position(), video.position.toDouble());
    }
    final playbackBuilds = pages;
    final center = tester.getCenter(slider);
    final drag = await tester.startGesture(center);
    await drag.moveBy(const Offset(32, 0));
    await tester.pump();
    pages = 0;
    for (var i = 0; i < 20; i++) {
      final old = position();
      await drag.moveBy(const Offset(3, 0));
      await tester.pump();
      expect(position(), greaterThan(old));
    }
    final dragBuilds = pages;
    final thumb = position();
    video
      ..position = 800
      ..duration = 7000
      ..playing = false;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(position(), thumb);
    expect(tester.widget<Slider>(slider).max, 7000);
    expect(find.byIcon(AppIcons.mediaPlay), findsOneWidget);
    expect(video.seeks, 0);
    await drag.up();
    await tester.pump();
    await tester.pump();
    expect(video.seeks, 1);
    expect(position(), video.position.toDouble());
    video.position = video.duration;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.mediaPlay));
    await tester.pump();
    expect(video.seeks, 2);
    expect(video.position, 0);
    expect(video.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect([playbackBuilds, dragBuilds], [0, 0]);
  });

  testWidgets('background transition pauses and disposal releases playback', (tester) async {
    final files = _Files();
    final video = _Video();
    await _pumpViewer(tester, files, video);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(video.pauses, greaterThan(0));
    expect(find.byIcon(AppIcons.mediaPlay), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(video.closes, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
