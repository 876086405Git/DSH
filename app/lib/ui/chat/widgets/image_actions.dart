// Pictures in a conversation. Long-press one for 「保存到相册」 / 「分享」; the
// full-screen viewer has the same save key.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/l10n.dart';
import '../../../media/gallery.dart';
import '../../common/brief_notice.dart';
import '../../shell/page_frame.dart' show GlassIconButton;
import '../../theme/app_icons.dart';
import 'message_menu.dart';

/// Reads the bytes of the picture to save or share (as stored where it can:
/// a re-encode only when nothing else is at hand).
typedef ImageBytes = Future<Uint8List> Function();

/// The toast for a picture that did not reach the gallery.
String gallerySaveErrorText(String code) => switch (code) {
  'permission' => wordsForIos ? appL10n.iosPhotosDenied : appL10n.chatImageStorageDenied,
  'unsupported' => appL10n.chatImageCannotSave,
  'download' => appL10n.chatImageDownloadFailed,
  _ => appL10n.chatImageSaveFailed,
};

/// 「保存到相册」: reads the picture with [load], puts it in the gallery's
/// DSH album as [name] and says so (「已保存到相册」). Refused storage offers
/// 「去设置」. True once saved.
Future<bool> saveImageToGallery(BuildContext context, ImageBytes load, {String? name}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final media = ProviderScope.containerOf(context, listen: false).read(mediaChannelProvider);
  String? failure;
  try {
    await saveToGallery(media, await load(), name: name);
  } on GallerySaveException catch (e) {
    failure = e.code;
  } catch (_) {
    failure = 'failed';
  }
  if (failure == null) {
    HapticFeedback.lightImpact();
    messenger?.showBriefNotice(l10n.chatImageSavedToPhotos);
    return true;
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(gallerySaveErrorText(failure)),
        persist: false,
        action: failure == 'permission'
            ? SnackBarAction(label: l10n.chatGoToSettings, onPressed: media.openSettings)
            : null,
      ),
    );
  return false;
}

/// 「分享」 a picture: the Android share sheet with it as a file named
/// [name].
Future<void> shareImageFile(BuildContext context, ImageBytes load, {String? name}) async {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final image = await galleryImage(await load());
    final file = galleryFileName(name, image.mime);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(image.bytes, mimeType: image.mime, name: file)],
        fileNameOverrides: [file],
      ),
    );
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.chatShareFailed)));
  }
}

/// Long-press on a picture in a message: its menu, then the chosen action.
/// [image] is the thumbnail to show; [load] gives the bytes to keep.
Future<void> showImageActions(
  BuildContext context, {
  required ImageProvider image,
  required ImageBytes load,
  String? name,
}) async {
  final action = await showImageMenu(context, image: image, name: name);
  if (action == null || !context.mounted) return;
  switch (action) {
    case ImageAction.save:
      await saveImageToGallery(context, load, name: name);
    case ImageAction.share:
      await shareImageFile(context, load, name: name);
  }
}

/// The image viewer's 「保存到相册」 key: a glass round key, the same size as
/// the viewer's close key opposite it, that shows a tick for a moment once
/// the picture is saved.
class GallerySaveButton extends StatefulWidget {
  const GallerySaveButton({super.key, required this.load, this.name, this.grouped = true});

  final ImageBytes load;
  final String? name;

  /// As [GlassIconButton.grouped]: match the key it sits opposite.
  final bool grouped;

  @override
  State<GallerySaveButton> createState() => _GallerySaveButtonState();
}

class _GallerySaveButtonState extends State<GallerySaveButton> {
  bool _busy = false;
  bool _saved = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    _busy = true;
    final saved = await saveImageToGallery(context, widget.load, name: widget.name);
    _busy = false;
    if (!mounted || !saved) return;
    setState(() => _saved = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _saved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return GlassIconButton(
      icon: _saved ? AppIcons.done : ImageAction.save.icon,
      tooltip: _saved ? l10n.commonSaved : ImageAction.save.label,
      grouped: widget.grouped,
      onPressed: _save,
    );
  }
}
