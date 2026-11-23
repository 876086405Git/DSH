// Writing on the forum — a reply, or a new topic with a category and a title.
// Markdown, like Discourse's own composer; pictures upload to the forum and go
// in as `upload://` links; 「分享码」 attaches a dsh-go share link that readers
// install with one tap.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../forum/discourse_client.dart';
import '../../forum/forum_models.dart';
import '../../forum/forum_share.dart';
import '../../forum/forum_state.dart';
import '../common/app_sheet.dart';
import '../common/capsule_chip.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// What is being written.
sealed class ForumComposeTarget {
  const ForumComposeTarget();

  String get draftKey;
}

final class ForumReplyTarget extends ForumComposeTarget {
  const ForumReplyTarget({required this.topicId, required this.topicTitle, this.replyTo});

  final int topicId;
  final String topicTitle;

  /// The post being answered (null: the topic itself).
  final ForumPost? replyTo;

  @override
  String get draftKey => 'reply:$topicId';
}

final class ForumNewTopicTarget extends ForumComposeTarget {
  const ForumNewTopicTarget({this.categoryId});

  final int? categoryId;

  @override
  String get draftKey => 'topic';
}

/// Unsent text, kept while the app runs (a sheet swiped away by accident
/// comes back with its words).
class ForumDraft {
  const ForumDraft({this.title = '', this.body = '', this.categoryId});

  final String title;
  final String body;
  final int? categoryId;

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;
}

class ForumDraftsController extends Notifier<Map<String, ForumDraft>> {
  @override
  Map<String, ForumDraft> build() => const {};

  void save(String key, ForumDraft draft) =>
      state = {...state, key: draft}..removeWhere((_, d) => d.isEmpty && d.categoryId == null);

  /// Drops [key]'s draft once [sent] (the entry stored at send time) is posted,
  /// unless a different draft took its place.
  void clearSent(String key, ForumDraft? sent) {
    final d = state[key];
    if (d?.title == sent?.title && d?.body == sent?.body && d?.categoryId == sent?.categoryId) {
      state = {...state}..remove(key);
    }
  }
}

final forumDraftsProvider = NotifierProvider<ForumDraftsController, Map<String, ForumDraft>>(ForumDraftsController.new);

/// A picked image: bytes and a file name. Null when the user backed out.
typedef ForumPickedImage = ({List<int> bytes, String name});

final forumImagePickerProvider = Provider<Future<ForumPickedImage?> Function()>((ref) {
  return () async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
      requestFullMetadata: false,
    );
    if (file == null) return null;
    return (bytes: await file.readAsBytes(), name: file.name);
  };
});

/// Opens the composer; returns what was posted (null when closed unsent).
Future<ForumPostResult?> showForumComposer(BuildContext context, ForumComposeTarget target) =>
    showAppSheet<ForumPostResult>(context, heightFactor: 0.92, builder: (_) => ForumComposerSheet(target: target));

class ForumComposerSheet extends ConsumerStatefulWidget {
  const ForumComposerSheet({super.key, required this.target});

  final ForumComposeTarget target;

  @override
  ConsumerState<ForumComposerSheet> createState() => _ForumComposerSheetState();
}

class _ForumComposerSheetState extends ConsumerState<ForumComposerSheet> {
  late final ForumDraft _draft = ref.read(forumDraftsProvider)[widget.target.draftKey] ?? const ForumDraft();
  late final _title = TextEditingController(text: _draft.title);
  late final _body = TextEditingController(text: _draft.body);
  final _bodyFocus = FocusNode();
  late int? _categoryId =
      _draft.categoryId ??
      switch (widget.target) {
        ForumNewTopicTarget(:final categoryId) => categoryId,
        ForumReplyTarget() => null,
      };
  bool _sending = false;
  bool _uploading = false;
  String? _notice;
  bool _noticeIsError = false;

  bool get _newTopic => widget.target is ForumNewTopicTarget;

  @override
  void initState() {
    super.initState();
    _title.addListener(_saveDraft);
    _body.addListener(_saveDraft);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _saveDraft() {
    ref
        .read(forumDraftsProvider.notifier)
        .save(widget.target.draftKey, ForumDraft(title: _title.text, body: _body.text, categoryId: _categoryId));
    if (_notice != null && !_uploading) setState(() => _notice = null);
  }

  void _say(String text, {bool error = false}) => setState(() {
    _notice = text;
    _noticeIsError = error;
  });

  /// Puts [markdown] on its own line at the cursor.
  void _insertBlock(String markdown) {
    final text = _body.text;
    final selection = _body.selection;
    final at = selection.isValid ? selection.start.clamp(0, text.length) : text.length;
    final before = text.substring(0, at);
    final after = text.substring(selection.isValid ? selection.end.clamp(at, text.length) : at);
    final lead = before.isEmpty || before.endsWith('\n') ? '' : '\n';
    final trail = after.startsWith('\n') ? '' : '\n';
    final inserted = '$lead$markdown$trail';
    _body.value = TextEditingValue(
      text: '$before$inserted$after',
      selection: TextSelection.collapsed(offset: before.length + inserted.length),
    );
  }

  Future<void> _attachImage() async {
    final picked = await ref.read(forumImagePickerProvider)();
    if (picked == null || !mounted) return;
    setState(() {
      _uploading = true;
      _notice = context.l10n.remoteForumUploadingImage;
      _noticeIsError = false;
    });
    try {
      final upload = await ref.read(forumApiProvider).upload(picked.bytes, picked.name);
      if (!mounted) return;
      _insertBlock(upload.markdown);
      setState(() {
        _uploading = false;
        _notice = null;
      });
    } on ForumException catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      _say(e.kind == ForumErrorKind.rejected ? e.message : context.l10n.remoteForumErrUploadImage, error: true);
    }
  }

  Future<void> _attachShareCode() async {
    final pick = await ref.read(forumShareCodePickerProvider)(context);
    if (!mounted) return;
    final link = pick.link;
    if (link == null) {
      if (pick.reason case final reason?) _say(reason);
      return;
    }
    _insertBlock(shareLinkMarkdown(link));
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    final body = _body.text.trim();
    if (_newTopic && title.isEmpty) return _say(context.l10n.remoteForumTitleRequired, error: true);
    final choices = ref.read(forumSiteProvider).value?.topLevel.where((c) => c.canCreateTopic) ?? const [];
    if (_newTopic && _categoryId == null && choices.isNotEmpty) {
      return _say(context.l10n.remoteForumCategoryRequired, error: true);
    }
    if (body.isEmpty) return _say(context.l10n.remoteForumBodyRequired, error: true);
    setState(() {
      _sending = true;
      _notice = null;
    });
    final api = ref.read(forumApiProvider);
    // Read before awaiting: the sheet may be closed by the time the post lands.
    final drafts = ref.read(forumDraftsProvider.notifier);
    final draftKey = widget.target.draftKey;
    final sent = ref.read(forumDraftsProvider)[draftKey];
    try {
      final result = switch (widget.target) {
        ForumReplyTarget(:final topicId, :final replyTo) => await api.reply(
          topicId: topicId,
          raw: body,
          replyToPostNumber: replyTo?.postNumber,
        ),
        ForumNewTopicTarget() => await api.createTopic(title: title, raw: body, categoryId: _categoryId),
      };
      drafts.clearSent(draftKey, sent);
      if (mounted) Navigator.of(context).pop(result);
    } on ForumException catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _say(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final target = widget.target;
    final site = ref.watch(forumSiteProvider).value;
    final categories = [
      for (final c in site?.topLevel ?? const <ForumCategory>[])
        if (c.canCreateTopic) c,
    ];
    final replyTo = target is ForumReplyTarget ? target.replyTo : null;
    final context2 = switch (target) {
      ForumReplyTarget(:final topicTitle) when replyTo != null => l10n.remoteForumReplyCaption(
        replyTo.user.username,
        topicTitle,
      ),
      ForumReplyTarget(:final topicTitle) => topicTitle,
      ForumNewTopicTarget() => null,
    };
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(_newTopic ? l10n.remoteForumNewTopic : l10n.commonReply),
          if (context2 != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 8),
              child: Text(
                context2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ),
          if (_newTopic) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
              child: TextField(
                controller: _title,
                autofocus: _title.text.isEmpty,
                maxLength: 255,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _bodyFocus.requestFocus(),
                style: theme.textTheme.titleMedium,
                decoration: InputDecoration(
                  hintText: l10n.remoteForumTitle,
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(kSheetGutter, 6, kSheetGutter, 6),
                children: [
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: CapsuleChoiceChip(
                        label: c.name,
                        selected: _categoryId == c.id,
                        onSelected: () {
                          setState(() => _categoryId = c.id);
                          _saveDraft();
                        },
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, indent: kSheetGutter, endIndent: kSheetGutter, color: theme.colorScheme.outlineVariant),
          ],
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
              child: TextField(
                controller: _body,
                focusNode: _bodyFocus,
                autofocus: !_newTopic,
                expands: true,
                maxLines: null,
                minLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                style: theme.textTheme.bodyLarge,
                decoration: InputDecoration(
                  hintText: l10n.remoteForumComposerHint,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          if (_notice case final notice?)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 8),
              child: Row(
                children: [
                  if (_uploading) ...[
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      notice,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _noticeIsError ? colors.danger : colors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ForumComposerToolbar(
            sendLabel: _newTopic ? l10n.remoteForumPublish : l10n.commonSend,
            sending: _sending,
            uploading: _uploading,
            onImage: () => unawaited(_attachImage()),
            onShareCode: () => unawaited(_attachShareCode()),
            onSend: () => unawaited(_send()),
          ),
          SizedBox(height: inset > 0 ? 8 : MediaQuery.paddingOf(context).bottom + 8),
        ],
      ),
    );
  }
}

/// The composer's bottom row: 图片 · 分享码 on the left, the send button on
/// the right; all 40 tall, [kSheetGutter] from both edges.
class ForumComposerToolbar extends StatelessWidget {
  const ForumComposerToolbar({
    super.key,
    required this.sendLabel,
    required this.onImage,
    required this.onShareCode,
    required this.onSend,
    this.sending = false,
    this.uploading = false,
  });

  final String sendLabel;
  final VoidCallback onImage;
  final VoidCallback onShareCode;
  final VoidCallback onSend;
  final bool sending;
  final bool uploading;

  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = scheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.08 : 0.05);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
      child: Row(
        children: [
          Tooltip(
            message: l10n.remoteForumImage,
            child: SizedBox.square(
              key: const ValueKey('forum-composer-image'),
              dimension: height,
              child: Material(
                color: quiet,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: uploading ? null : onImage,
                  child: Icon(AppIcons.addImage, size: 20, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            key: const ValueKey('forum-composer-share'),
            height: height,
            child: Material(
              color: quiet,
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onShareCode,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.qrCode, size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        l10n.remoteForumAttachShareCode,
                        style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            key: const ValueKey('forum-composer-send'),
            height: height,
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(80, height),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: const StadiumBorder(),
              ),
              onPressed: sending || uploading ? null : onSend,
              child: sending
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                    )
                  : Text(sendLabel),
            ),
          ),
        ],
      ),
    );
  }
}
