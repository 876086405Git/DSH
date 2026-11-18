import 'package:flutter/services.dart';

const first = MethodChannel('dsh/first');
const second = MethodChannel('dsh/second');
const events = EventChannel('dsh/events');

Future<void> calls() async {
  await first.invokeMethod<String>('read');
  await first.invokeMapMethod<String, String>('readAll');
  await second.invokeListMethod<String>('list');
  await const MethodChannel('flutter/platform').invokeMethod<void>('SystemSound.play');
  events.receiveBroadcastStream();
}

void callback() {
  first.setMethodCallHandler((call) async {
    if (call.method == 'fromNative') return true;
    return null;
  });
}

// first.invokeMethod('comment-must-not-appear');
const text = "first.invokeMethod('string-must-not-appear')";
