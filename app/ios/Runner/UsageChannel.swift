import Flutter

// dsh/usage, after android/.../usage/UsagePlugin.kt: facts shared by every phone of a kind,
// never the model or an identifier. The share host's report (usageProblem in
// lib/usage/usage_ledger.dart, services/share-worker/src/usage.ts) only takes Android's ABI
// names, so a report with these is dropped on the phone and nothing is sent from iOS. They
// are the real values on purpose: no Android figures just to get through the check.

final class UsageChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/usage", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "device" else { return result(FlutterMethodNotImplemented) }
      var device: [String: Any] = [
        "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        "abi": AppFacts.abi,
        "maker": "apple",
      ]
      if let name = AppFacts.versionName { device["versionName"] = name }
      if let code = AppFacts.versionCode { device["versionCode"] = code }
      result(device)
    }
  }
}
