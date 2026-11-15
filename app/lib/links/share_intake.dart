// What other apps share to dsh-go through the system
// share sheet — text, photos, files. Native side:
// android/.../share/ShareActivity.kt (the share-sheet target) and
// share/SharePlugin.kt (MethodChannel `dsh/share`), which copies the files
// into the app cache first (photos scaled like the composer's own picker).
//
// Where a share goes is decided in lib/ui/shell/system_entry_host.dart: a
// lone `.dshgo` file or a share link to the share-code importer, a hosted
// conversation link to its replay, everything else into a new conversation's
// composer (lib/state/compose_inbox.dart).

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../share_code/share_codec.dart' show shareFileExtension, shareFileMime;
import '../share_code/share_link.dart';
import '../share_hosted/hosted_link.dart' show findHostedUrl;
import 'native_inbox.dart';

/// One shared file, copied into the app cache (readable with dart:io).
class SharedFile {
  const SharedFile({required this.path, required this.name, this.mime, this.size});

  final String path;

  /// As the sender named it (a photo scaled on the way in is a `.jpg`).
  final String name;
  final String? mime;
  final int? size;

  /// A share-code file: the importer opens it.
  bool get isShareCode => name.toLowerCase().endsWith('.$shareFileExtension') || mime == shareFileMime;
}

enum ShareSkipReason { tooLarge, unreadable, tooMany }

/// A shared item that did not come through.
class SkippedShare {
  const SkippedShare(this.reason, [this.name]);

  final ShareSkipReason reason;

  /// Null when the sender gave no name (or it wasn't read).
  final String? name;
}

/// One arrival from the share sheet.
class IncomingShare {
  const IncomingShare({this.text, this.subject, this.files = const [], this.skipped = const []});

  /// EXTRA_TEXT (several joined by a blank line).
  final String? text;

  /// EXTRA_SUBJECT: a browser's page title, a mail subject.
  final String? subject;
  final List<SharedFile> files;
  final List<SkippedShare> skipped;

  bool get isEmpty => (text == null || text!.trim().isEmpty) && files.isEmpty && skipped.isEmpty;

  /// A lone `.dshgo` file: imported, not chatted about.
  SharedFile? get shareCodeFile =>
      files.length == 1 && skipped.isEmpty && files.single.isShareCode ? files.single : null;

  /// A hosted conversation link inside shared text (forwarded from a chat
  /// app): opens its replay.
  Uri? get hostedLink {
    final body = text;
    if (body == null || files.isNotEmpty || skipped.isNotEmpty) return null;
    return findHostedUrl(body);
  }

  /// A share link inside shared text (a 分享码 forwarded from a chat app).
  ShareLink? get shareLink {
    final body = text;
    if (body == null || files.isNotEmpty || skipped.isNotEmpty) return null;
    // A forwarded Chinese sentence may put punctuation right next to its
    // link. Split only the extraction copy; the original chat text stays intact.
    final input = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
        ? body.replaceAll(RegExp(r'[。！？；，、（）【】「」“”‘’]'), ' ')
        : body;
    return ShareLink.find(input);
  }

  /// What goes into the composer: the text, and over a bare link the page
  /// title it came with. A subject alone (a file's name, a mail subject next
  /// to an attachment) is left out.
  String get composedText {
    final body = text?.trim() ?? '';
    final title = subject?.trim() ?? '';
    if (body.isEmpty) return '';
    if (title.isEmpty || body.contains(title) || !_isBareLink(body)) {
      return body;
    }
    return '$title\n$body';
  }

  static bool _isBareLink(String text) {
    if (text.contains(RegExp(r'\s'))) return false;
    final uri = Uri.tryParse(text);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
  }

  /// One `share` call's arguments; null for anything malformed or empty.
  static IncomingShare? parse(Object? raw) {
    if (raw is! Map) return null;
    String? string(Object? v) => v is String && v.isNotEmpty ? v : null;
    final files = <SharedFile>[
      for (final f in raw['files'] is List ? raw['files'] as List : const [])
        if (f is Map && string(f['path']) != null && string(f['name']) != null)
          SharedFile(
            path: f['path'] as String,
            name: f['name'] as String,
            mime: string(f['mime']),
            size: f['size'] is int ? f['size'] as int : null,
          ),
    ];
    final skipped = <SkippedShare>[
      for (final s in raw['skipped'] is List ? raw['skipped'] as List : const [])
        if (s is Map)
          SkippedShare(switch (s['reason']) {
            'too_large' => ShareSkipReason.tooLarge,
            'too_many' => ShareSkipReason.tooMany,
            _ => ShareSkipReason.unreadable,
          }, string(s['name'])),
    ];
    final share = IncomingShare(
      text: string(raw['text']),
      subject: string(raw['subject']),
      files: files,
      skipped: skipped,
    );
    return share.isEmpty ? null : share;
  }
}

/// The native bridge: a stream of shares.
class ShareIntake extends NativeInbox<IncomingShare> {
  ShareIntake({MethodChannel? channel})
    : super(channel ?? const MethodChannel('dsh/share'), method: 'share', parse: IncomingShare.parse);

  Stream<IncomingShare> get shares => stream;
}

final shareIntakeProvider = Provider<ShareIntake>((ref) {
  final intake = ShareIntake();
  ref.onDispose(intake.dispose);
  return intake;
});
