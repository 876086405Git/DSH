// 语音通话 in her room: what the person says goes to her the way a typed line
// does (the room's own send, in either mode, with everything she knows), and
// her reply comes back without its marks, as the words she says.

import 'dart:async';

import '../speech/call/voice_call.dart';

class CompanionCallConversation implements CallConversation {
  /// [_send] sends a line the way the room's composer does; [_stop] stops her reply.
  CompanionCallConversation(this._send, this._stop);

  final Future<bool> Function(String text) _send;
  final Future<void> Function() _stop;
  final _replies = StreamController<CallReply>.broadcast();
  bool _tracking = false;
  String _last = '';
  Timer? _idle;

  @override
  Stream<CallReply> get replies => _replies.stream;

  /// Her room answers approvals itself; nothing waits on the call.
  @override
  bool get waiting => false;

  @override
  Future<bool> send(String text) async {
    _tracking = true;
    _last = '';
    final ok = await _send(text);
    if (!ok) {
      _tracking = false;
      return false;
    }
    // A line that never gets an answer (it failed in the room): stop waiting.
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 90), () {
      if (_tracking && _last.isEmpty) done();
    });
    return true;
  }

  /// Her reply so far, as the room reads it.
  void reply(String words, {required bool running}) {
    if (!_tracking) return;
    if (words != _last && words.length >= _last.length) {
      _last = words;
      if (!_replies.isClosed) _replies.add(CallReply(words, done: false));
    }
    if (!running && words.isNotEmpty) done();
  }

  /// The turn is over (finished or failed).
  void done() {
    if (!_tracking) return;
    _tracking = false;
    _idle?.cancel();
    if (!_replies.isClosed) _replies.add(CallReply(_last, done: true));
  }

  @override
  Future<void> interrupt() async {
    _tracking = false;
    _idle?.cancel();
    await _stop();
  }

  @override
  void dispose() {
    _tracking = false;
    _idle?.cancel();
    unawaited(_replies.close());
  }
}
