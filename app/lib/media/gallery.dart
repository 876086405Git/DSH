// 「保存到相册」: pictures from a conversation into the
// phone's gallery through `media/MediaPlugin.kt` (MediaStore on Android 10+,
// the public Pictures folder before).

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../l10n/l10n.dart';
import '../state/attachments.dart' show inlineImageType;

/// The native side (`dsh/media`).
class MediaChannel {
  const MediaChannel([this.channel = const MethodChannel('dsh/media')]);

  final MethodChannel channel;

  /// Saves [bytes] (PNG, JPEG, GIF or WebP, of type [mime]) into the
  /// gallery's DSH Go album as [name]; returns where it landed
  /// (`Pictures/DSH Go/chart.png`).
  Future<String> saveImage(Uint8List bytes, {required String name, required String mime}) async =>
      await channel.invokeMethod<String>('saveImage', {'bytes': bytes, 'name': name, 'mime': mime}) ??
      'Pictures/DSH Go/$name';

  /// Streams an already materialized local video into the gallery.
  Future<String> saveVideoFile(String path, {required String name}) async =>
      await channel.invokeMethod<String>('saveVideoFile', {'path': path, 'name': name}) ??
      'Movies/DSH Go/$name';

  /// The app's page in system settings (storage was refused for good).
  Future<bool> openSettings() async => await channel.invokeMethod<bool>('openSettings') ?? false;
}

final mediaChannelProvider = Provider<MediaChannel>((ref) => const MediaChannel());

/// Why a picture did not reach the gallery.
class GallerySaveException implements Exception {
  const GallerySaveException(this.code);

  /// `permission` (storage refused), `unsupported` (not a picture Flutter
  /// can read), `download` (a web image did not come), `failed`, `cancelled`
  /// (the person backed out of HarmonyOS's album window: nothing to say).
  final String code;

  @override
  String toString() => 'GallerySaveException($code)';
}

/// The extension a gallery file of [mime] gets.
String galleryExtension(String mime) => switch (mime) {
  'image/jpeg' => 'jpg',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  _ => 'png',
};

/// The name a picture gets in the gallery: [name] (a file name or path as
/// the conversation shows it) with the extension of [mime], or
/// `DSH_20261024_153012.png` when there is none worth keeping.
String galleryFileName(String? name, String mime, {DateTime? now}) {
  var base = (name ?? '').trim();
  final slash = base.lastIndexOf(RegExp(r'[/\\]'));
  if (slash >= 0) base = base.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  base = base.replaceAll(RegExp(r'[\x00-\x1f\\:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  // A bare 「图片」 placeholder or nothing at all: a dated name instead.
  if (base.isEmpty ||
      base == '图片' || // l10n:keep the Chinese placeholder, whatever the app language
      base == appL10n.fileImageName ||
      base.startsWith('.')) {
    final t = now ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    base =
        'DSH_${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
  if (base.length > 80) {
    var end = 80;
    final lead = base.codeUnitAt(end - 1);
    final trail = base.codeUnitAt(end);
    // Preserve the code-unit budget without creating an unpaired surrogate.
    if (lead >= 0xd800 && lead <= 0xdbff && trail >= 0xdc00 && trail <= 0xdfff) end--;
    base = base.substring(0, end).trim();
  }
  return '$base.${galleryExtension(mime)}';
}

/// [bytes] ready for the gallery: kept as they are when they are PNG, JPEG,
/// GIF or WebP; anything else Flutter can decode (BMP, an ICO…) becomes PNG.
Future<({Uint8List bytes, String mime})> galleryImage(Uint8List bytes) async {
  if (inlineImageType(bytes) case final mime?) {
    return (bytes: bytes, mime: mime);
  }
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (png == null) throw const GallerySaveException('unsupported');
    return (bytes: png.buffer.asUint8List(), mime: 'image/png');
  } on GallerySaveException {
    rethrow;
  } catch (_) {
    throw const GallerySaveException('unsupported');
  }
}

/// The bytes behind [provider]: memory and file images as stored, web images
/// downloaded again ([client] for tests), anything else drawn once and
/// encoded as PNG. A resized provider gives its source's bytes.
Future<Uint8List> imageProviderBytes(ImageProvider provider, {http.Client? client}) async {
  switch (provider) {
    case ResizeImage(:final imageProvider):
      return imageProviderBytes(imageProvider, client: client);
    case MemoryImage(:final bytes):
      return bytes;
    case FileImage(:final file):
      try {
        return await file.readAsBytes();
      } on FileSystemException {
        throw const GallerySaveException('failed');
      }
    case NetworkImage(:final url, :final headers):
      final http.Response response;
      try {
        final get = client?.get ?? http.get;
        response = await get(Uri.parse(url), headers: headers);
      } catch (_) {
        throw const GallerySaveException('download');
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw const GallerySaveException('download');
      }
      return response.bodyBytes;
    default:
      return _render(provider);
  }
}

/// [provider] resolved once and encoded as PNG.
Future<Uint8List> _render(ImageProvider provider) async {
  final stream = provider.resolve(ImageConfiguration.empty);
  final info = await _first(stream);
  try {
    final png = await info.image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) throw const GallerySaveException('unsupported');
    return png.buffer.asUint8List();
  } finally {
    info.dispose();
  }
}

/// The first frame [stream] delivers (the listener owns its clone).
Future<ImageInfo> _first(ImageStream stream) {
  final done = Completer<ImageInfo>();
  late final ImageStreamListener listener;
  void stop() => scheduleMicrotask(() => stream.removeListener(listener));
  listener = ImageStreamListener(
    (info, _) {
      if (done.isCompleted) {
        info.dispose();
        return;
      }
      done.complete(info);
      stop();
    },
    onError: (_, _) {
      if (!done.isCompleted) {
        done.completeError(const GallerySaveException('unsupported'));
      }
      stop();
    },
  );
  stream.addListener(listener);
  return done.future;
}

/// Puts [raw] into the gallery as [name]; returns where it landed.
Future<String> saveToGallery(MediaChannel channel, Uint8List raw, {String? name}) async {
  if (raw.isEmpty) throw const GallerySaveException('unsupported');
  final image = await galleryImage(raw);
  try {
    return await channel.saveImage(image.bytes, name: galleryFileName(name, image.mime), mime: image.mime);
  } on PlatformException catch (e) {
    throw GallerySaveException(switch (e.code) {
      'permission' => 'permission',
      'invalid' => 'unsupported',
      'cancelled' => 'cancelled',
      _ => 'failed',
    });
  } on MissingPluginException {
    throw const GallerySaveException('failed');
  }
}
