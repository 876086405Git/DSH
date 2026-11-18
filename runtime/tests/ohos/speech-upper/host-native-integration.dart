import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:flutter/services.dart';
import 'package:dsh_client/dsh_client.dart';
import 'host-speech-tests.dart' show FixtureSpeech, output, settle, bridgeSpeech;

class Native {
  Native(this.process, this.stderrFile) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['ready'] == true) { identity = row['inputSha256']; bridgeUrl = row['bridgeUrl']; bridgeSha256 = row['bridgeSha256']; ready.complete(); return; }
      if (row['event'] is Map) {
        final event = row['event'] as Map;
        events.add(event);
        unawaited(MethodChannel.inbound['dsh/speech']?.call(MethodCall(event['method'] as String, event['args'])));
        return;
      }
      final pending = replies.remove(row['reply']);
      if (row.containsKey('error')) {
        pending?.completeError(PlatformException(code: row['error'] as String, message: row['message'] as String?));
      } else { pending?.complete(row['value']); }
    }, onError: ready.completeError);
    process.stderr.listen(stderrFile.add);
    MethodChannel.outbound['dsh/speech'] = (call) => request(call.method, call.arguments as Map?);
  }
  final Process process;
  final IOSink stderrFile;
  final ready = Completer<void>();
  final replies = <int, Completer<Object?>>{};
  final events = <Map>[];
  Object? identity;
  String? bridgeUrl, bridgeSha256;
  int sequence = 0;
  Future<Object?> request(String method, [Map? args]) {
    final id = ++sequence, pending = Completer<Object?>();
    replies[id] = pending;
    process.stdin.writeln(jsonEncode({'id': id, 'method': method, if (args != null) 'args': args}));
    return pending.future;
  }
  Future<void> close() async {
    await request('fixture/shutdown');
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 3));
    if (code != 0) throw StateError('native fixture exited $code');
    await stderrFile.close(); MethodChannel.outbound.remove('dsh/speech');
  }
}

Future<Map<String, Object?>> run(String mode, List<String> args) async {
  final process = await Process.start(args[0], ['--jitless', args[1], args[2], mode, if (args.length == 6) args[5]],
    environment: {'OHOS_TYPESCRIPT_PREFIX': args[3]});
  final stderr = File('${args[4]}/native-$mode.stderr.log').openWrite();
  final native = Native(process, stderr); await native.ready.future.timeout(const Duration(seconds: 5));
  final audio = SpeechAudio();
  final connection = native.bridgeUrl == null ? null : DshConnection(Uri.parse(native.bridgeUrl!));
  final speech = FixtureSpeech(() => Stream.fromIterable([Uint8List.fromList([1, 2, 3]), Uint8List.fromList([4, 5, 6])]));
  final out = output(() async => connection == null ? speech : await bridgeSpeech(connection), audio), events = <SpeechOutEvent>[];
  final terminal = Completer<void>();
  final sub = out.events.listen((event) {
    events.add(event);
    if ((event is SpeechOutFailed || event is SpeechOutDone) && !terminal.isCompleted) terminal.complete();
  });
  try {
    out..add('真实Dart与真实鸿蒙方法体之间的预检和字节通道。')..finish();
    var wroteBeforeProviderEof = false;
    if (mode == 'pending-start') {
      for (;;) {
        final status = await native.request('fixture/status') as Map;
        if ((status['nativeCalls'] as List).contains('start')) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      out.stop(); await native.request('fixture/release-start');
    }
    if (connection != null && (mode == 'normal' || mode == 'bridge-cancel')) {
      for (;;) {
        final status = await native.request('fixture/status') as Map;
        if ((status['methodCalls'] as List).any((row) => row['method'] == 'write')) {
          wroteBeforeProviderEof = status['pcmEof'] == false; break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (mode == 'bridge-cancel') out.stop();
      else await native.request('fixture/release-audio');
    }
    await terminal.future.timeout(const Duration(seconds: 5));
    await settle();
    final status = await native.request('fixture/status') as Map;
    if (mode == 'bridge-cancel') {
      for (;;) {
        final now = await native.request('fixture/status') as Map;
        if ((now['providerAborts'] as int) > 0) { status.addAll(now); break; }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
    final buffers = (status['renderers'] as List).expand((r) => (r as Map)['committed'] as List).expand((b) => b as List).toList();
    final requests = connection == null ? speech.asked.length : status['providerRequests'] as int;
    final pass = mode == 'normal'
      ? requests == 1 && events.whereType<SpeechOutFailed>().isEmpty && (connection == null || wroteBeforeProviderEof) &&
          events.whereType<SpeechOutDone>().length == 1 && jsonEncode(buffers) == '[1,2,3,4,5,6,0,0]'
      : mode == 'bridge-cancel' ? requests == 1 && wroteBeforeProviderEof && status['providerAborts'] > 0 &&
          status['pcmEof'] == false && events.whereType<SpeechOutDone>().length == 1
      : requests == 0 && (mode == 'pending-start' ? events.whereType<SpeechOutDone>().length == 1 : events.whereType<SpeechOutFailed>().length == 1);
    return {'pass': pass, 'synthesisCalls': requests, 'wroteBeforeProviderEof': wroteBeforeProviderEof,
      'dartEvents': events.map((e) => e.runtimeType.toString()).toList(), 'nativeStatus': status,
      'inputSha256': native.identity, if (connection != null) 'actualBridgeSha256': native.bridgeSha256};
  } finally {
    out.stop(); await native.request('fixture/release-start'); await settle();
    await sub.cancel(); audio.dispose(); connection?.close(force: true); await native.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 5 && args.length != 6) throw ArgumentError('node native-rpc.mjs sourceRoot tsPrefix outputDir [actualBridgeSpeechJs]');
  Directory(args[4]).createSync(recursive: true);
  var failed = 0;
  final modes = ['create-fail', 'start-fail', 'format-mismatch', 'pending-start', 'normal', if (args.length == 6) 'bridge-cancel'];
  for (final mode in modes) {
    try {
      final result = await run(mode, args).timeout(const Duration(seconds: 12));
      if (result['pass'] != true) failed++;
      print(jsonEncode({'mode': mode, ...result}));
    } catch (error, stack) { failed++; print(jsonEncode({'mode': mode, 'pass': false, 'error': '$error', 'stack': '$stack'})); }
  }
  print(jsonEncode({'scope': 'actual Dart + actual 1216 ETS methods; JSON MethodChannel seam + fixture AudioRenderer OS only',
    'tests': modes.length, 'failed': failed, 'actualBridgeWithLocalProviderFixture': args.length == 6}));
  exitCode = failed == 0 ? 0 : 1;
}
