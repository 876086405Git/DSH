// A text field's own 粘贴, from its long-press menu or Ctrl+V. Flutter shows the item
// whenever the system says the clipboard holds something, which a plain HarmonyOS package
// may ask, but its Clipboard.getData then asks for a permission the package doesn't have
// and answers null, so the item does nothing. The framework reads through its own channel
// and offers no other way in, so that one message is answered here, through the system's
// paste button. Nothing reads without a person pressing 粘贴: no one else calls it on
// HarmonyOS ([FieldPaste] and the rest go to [PasteReader] directly).

import 'package:flutter/services.dart';

import 'paste_reader.dart';

/// [inner] on any OS but HarmonyOS.
BinaryMessenger clipboardMessengerFor(String os, BinaryMessenger inner) =>
    os == 'ohos' ? PasteButtonMessenger(inner) : inner;

class PasteButtonMessenger implements BinaryMessenger {
  PasteButtonMessenger(this._inner, {Future<PasteResult> Function()? read}) : _read = read ?? _readOnce;

  final BinaryMessenger _inner;
  final Future<PasteResult> Function() _read;

  static final _reader = PasteReader(ohos: true);
  static Future<PasteResult> _readOnce() => _reader.begin().finish();

  static const _codec = JSONMethodCodec();

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    if (channel == SystemChannels.platform.name && message != null) {
      if (_codec.decodeMethodCall(message).method == 'Clipboard.getData') return _answer();
    }
    return _inner.send(channel, message);
  }

  // Nothing to paste comes back as Flutter's own null, which leaves the field alone. The
  // native toast says why when it could; a text field has nowhere of its own to say it.
  Future<ByteData?> _answer() async {
    final text = (await _read()).text;
    return _codec.encodeSuccessEnvelope(text == null ? null : <String, Object?>{'text': text});
  }

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data, PlatformMessageResponseCallback? callback) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);

  @override
  void setMessageHandler(String channel, MessageHandler? handler) => _inner.setMessageHandler(channel, handler);
}
