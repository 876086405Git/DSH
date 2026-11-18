import Flutter
import Security
import WidgetKit

final class IOSCompanionWidget {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/companion_widget", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, reply in
      guard call.method == "update" else { reply(FlutterMethodNotImplemented); return }
      guard let values = call.arguments as? [String: Any] else {
        reply(FlutterError(code: "widget_arguments", message: "Invalid widget snapshot", details: nil)); return
      }
      var snapshot = CompanionSnapshotStore.load()
      snapshot.update(values)
      let status = CompanionSnapshotStore.save(snapshot)
      guard status == errSecSuccess else {
        reply(FlutterError(code: "widget_storage", message: "Widget snapshot could not be saved", details: status)); return
      }
      WidgetCenter.shared.reloadTimelines(ofKind: CompanionSnapshotStore.kind)
      reply(nil)
    }
  }
}
