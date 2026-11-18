# iOS guest Dart contract tests

This small Flutter package imports the production `app/lib/runtime/ios_guest.dart`
directly, without resolving the full application dependency graph. Run from this
directory with a compatible Flutter SDK:

```sh
flutter pub get
flutter test --no-pub --reporter expanded
```

Use `flutter pub get --offline` when the SDK and required packages are already
cached. Tests verify the new suspension fields, earlier payload compatibility,
immutable response values, read-error representation, the uninstalled/paused
state and the non-iOS platform guard. They do not execute an iOS method channel.

The separate `../crash-channel.sh` macOS fixture compiles the production Swift
channel, rootfs installer and startup snapshot with a transport-only Flutter
shim and a native-gate contract fake. To cover a fresh install, pass the already
downloaded, pinned Alpine archive as its sole argument. The archive is verified
before installation and the fixture does not choose or download another archive.
Native crash/locking behavior and real Apple device behavior require their own
integration tests.
