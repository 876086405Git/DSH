# Native image galleries

## Scope

- Pinch between fit and 8x; double-tap around the touched point to 2.5x and back.
- Swipe at fit to turn pages. While enlarged, dragging pans only; a pinch must not start a page turn.
- A gallery is one composer tray, user message, rendered Markdown body, tool result, generated batch, plugin gallery or forum body. Markdown workspace and web/data images are separate groups. Forum quotes/details form their own groups. Standalone workspace file previews remain single-image.
- Attachments keep original bytes, Hero transitions, close/save buttons and their long-press menu. Taps while enlarged do not close attachments. Generated/plugin images retain tap-to-toggle controls.
- Standalone workspace image pages retain file actions, the 32 MiB remote preview limit and a watch for the selected file. Revisiting a file invalidates its decoded image cache, including updates received while another page was selected.
- Workspace-file images inside chat replies and deliverable cards keep the first successful read per host/session/turn/path. Inline image, thumbnail, full-screen preview and file/share actions use the same immutable content. The next turn reads the current source again; merely scrolling or reopening the old turn does not. This is a read-time snapshot, not a reconstruction of an overwritten file that was never read.
- Snapshot bytes are content-addressed (identical content is stored once), limited to 20 MiB per image and 128 MiB overall, with least-recently-used content reclaimed first. Small durable references prevent an evicted old turn from silently reading the current source instead. Session deletion removes its references and unshared content. Snapshots do not alter the original files. Old conversations without a previously captured snapshot cannot recover past file contents.
- PDF zoom, wallpaper/icon editors and WebView content are unchanged.

## Automated checks

From `app/`, with the repository's Flutter/Dart versions and test fonts installed:

```sh
flutter analyze --no-pub
flutter test --no-pub \
  test/chat/image_gallery_test.dart \
  test/chat/attachment_gallery_test.dart \
  test/chat/reply_gallery_test.dart \
  test/chat/workspace_gallery_refresh_test.dart \
  test/chat/image_snapshots_test.dart \
  test/chat/image_snapshot_export_test.dart \
  test/chat/turn_image_snapshot_test.dart \
  test/chat/turn_artifact_paths_test.dart \
  test/chat/stream_rebuild_guard_test.dart \
  test/chat/image_viewer_theme_test.dart \
  test/chat/inline_image_provider_test.dart \
  test/chat/tool_images_test.dart \
  test/chat/markdown_render_test.dart \
  test/chat/attachments_test.dart \
  test/media/media_card_test.dart \
  test/plugins/view/plugin_view_figures_test.dart \
  test/files/file_preview_test.dart \
  test/forum/forum_image_gallery_test.dart \
  test/state/session_deletion_test.dart \
  test/state/drawer_delete_test.dart
```

Set `DSH_TEST_FONT_DIR` if Noto CJK fonts are installed somewhere other than the test harness's default. Widget tests must use a tester engine matching the host architecture. From the repository root, also run `python3 app/tool/guide_sync.py --check`.

## Original workspace validation record

The following results were recorded in the original workspace before porting to main; they are not validation of the port.

- Flutter 3.47.7 / Dart 3.13.5, Linux ARM64 tester: `flutter analyze --no-pub` passed with no issues. Guide sync and `git diff --check` passed.
- The original 13-file gallery matrix (before the snapshot tests were added) passed 137 tests with `--concurrency=2 --name '^(?!golden figures)'`; this includes all 23 new gallery tests and the real decoded-image regression (4x4 PNG replaced by 7x3 PNG while another file is watched).
- The three existing `golden figures` cases were also exercised by the earlier unfiltered matrix and failed: dark/light/narrow-large differ by 43/43/56 pixels (reported 0.01%), visible on fixture thumbnail edges. Baselines were not updated. Their root cause has not been reproduced against an isolated pre-change baseline; the unfiltered screenshot suite is not green.
- APK build, installation and physical touchscreen checks were not run. The commands above are focused checks, not the complete application test suite.

## Android acceptance (requires a rebuilt APK)

1. Attach three different pictures and a text file. Open picture two in the composer, while sending, after sending and in an offline replay. Swipe both ways: only this message's pictures belong to the gallery; page/name/save bytes follow the selected picture.
2. Double-tap a detail, pan horizontally/vertically, then pinch to fit. Zooming must not close the page or change the image. At fit, swiping changes pages; first/last pages do not wrap. Close explicitly and check the originating picture is still visible.
3. Test a reply with two workspace pictures, two web/data pictures, repeated URLs, HTML images, fenced/inline image-looking code and an unsupported/SVG image. Only rendered previewable pictures belong to their own group's ordered snapshot, not another reply's images.
4. Open a tool's second picture, a generated batch and a plugin gallery. Keep original source labels, generation actions and no save/share when plugin bytes are unavailable. A missing/loading attachment must not prevent swiping back to a good page.
5. Open workspace image A, swipe to B, overwrite A at the same path, then return to A. Check the visible pixels, not only file-read counts. Modify/delete/recreate the selected file and check refresh/error recovery. On a remote host, files exceeding 32 MiB must still show the size-limit action.
6. Open two forum pictures and check full-resolution URLs, fallback to `src`, quoted/detail galleries, error pages and close. Check light/dark themes, portrait/landscape safe areas and a large system font.

7. In a chat turn, display and deliver an image. Overwrite it at the same path in the next turn and display/deliver it again. Check visible pixels in both replies, thumbnails, full-screen pages and share cards: the first turn stays old, the second shows new. Scroll away/back and reopen the app; check both again. Unchanged bytes must share one snapshot file. With a small injected cache budget, reclaimed history must report missing rather than show the current file. Repeat with a remote host, then delete a session and check only unshared snapshot content is removed.

Do not treat Linux widget results as installed-APK or physical touchscreen verification.
