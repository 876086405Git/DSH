// The avatar and label a theme pack puts above a message.

import 'package:flutter/material.dart';

import '../../../themes/theme_library.dart' show themeAvatarDecodeWidth;
import '../../theme/theme.dart';

/// The pack's label and 24dp avatar for one side of the chat, 4 above the
/// message: the avatar on the outer edge, the label beside it. Null (no room
/// taken) when the pack sets neither; a built-in pack has no image folder,
/// so it never draws an avatar.
Widget? themeRoleTag(BuildContext context, DshThemeStyle style, {required bool user}) {
  final components = style.components;
  final label = style.localized(user ? components.userLabel : components.assistantLabel);
  final avatarName = user ? components.userAvatar : components.assistantAvatar;
  final avatarFile = style.assetFile(avatarName);
  if (label == null && avatarFile == null) return null;
  final avatar = avatarFile == null
      ? null
      : ClipOval(
          child: Image.file(
            avatarFile,
            key: style.assetKey(avatarName!),
            width: 24,
            height: 24,
            cacheWidth: themeAvatarDecodeWidth,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        );
  final text = label == null
      ? null
      : Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
          ),
        );
  final gap = avatar != null && text != null ? const SizedBox(width: 6) : null;
  return Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(mainAxisSize: MainAxisSize.min, children: user ? [?text, ?gap, ?avatar] : [?avatar, ?gap, ?text]),
  );
}
