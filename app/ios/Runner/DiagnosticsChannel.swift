import Flutter
import Speech
import UIKit

// dsh/diagnostics, after android/.../diagnostics/DiagnosticsPlugin.kt and
// ohos/.../DiagnosticsPlugin.ets: facts only the platform knows, for the bundle a person
// sends with a bug report. Nothing here reads user content, keys or tokens. `engineLog` has no
// lines: the engine's log only lives in memory here (`getLogs` on dsh/runtime), with no file
// that outlives the app for this to read.

final class DiagnosticsChannel {
  private static let megabyte: UInt64 = 1024 * 1024

  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/diagnostics", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "info": Self.info(result)
      case "engineLog": result([String]())
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// UIKit and the recognizer here on the main thread, the disk off it.
  private static func info(_ result: @escaping FlutterResult) {
    let device: [String: Any] = [
      "platform": "ios",
      "manufacturer": "Apple",
      "brand": "Apple",
      "model": model(),
      "osVersion": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      "abis": [AppFacts.abi],
      "memoryMb": Int(ProcessInfo.processInfo.physicalMemory / megabyte),
      "display": display(),
    ]
    let voice = voiceFacts()
    DispatchQueue.global(qos: .utility).async {
      let free = Self.freeStorageMb()
      let carried = Self.bundledRuntime()
      onMain {
        var facts = device
        if let free { facts["freeStorageMb"] = free }
        var app: [String: Any] = ["abi": AppFacts.abi]
        if let name = AppFacts.versionName { app["versionName"] = name }
        if let code = AppFacts.versionCode { app["versionCode"] = code }
        result(["app": app, "device": facts, "manifest": carried, "voice": voice])
      }
    }
  }

  /// The engine this build carries, checksums left out. Empty in a build without one.
  private static func bundledRuntime() -> [String: Any] {
    guard
      let url = Bundle.main.url(forResource: "runtime", withExtension: "zip", subdirectory: "dsh-runtime"),
      let manifest = (try? RuntimeArchive(url: url))?.manifest
    else { return [:] }
    return [
      "runtimeVersion": manifest.runtimeVersion,
      "dshVersion": manifest.dshVersion,
      "nodeVersion": manifest.nodeVersion,
      "files": manifest.files.count,
      "uncompressedBytes": manifest.files.reduce(0) { $0 + $1.size },
    ]
  }

  /// `iPhone14,5`: the kind of phone, not this one.
  private static func model() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
  }

  /// No dpi: iOS has no public figure for it.
  private static func display() -> [String: Any] {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let screen = scene?.screen ?? UIScreen.main
    return [
      "widthPx": Int(screen.nativeBounds.width),
      "heightPx": Int(screen.nativeBounds.height),
      "density": Double(screen.nativeScale),
      "fontScale": Double(UIFontMetrics.default.scaledValue(for: 100) / 100),
    ]
  }

  private static func voiceFacts() -> [String: Any] {
    let recognizer = SFSpeechRecognizer()
    return [
      "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "recognizerAvailable": recognizer?.isAvailable == true,
      "onDeviceAvailable": recognizer?.supportsOnDeviceRecognition == true,
    ]
  }

  private static func freeStorageMb() -> Int? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let bytes = values?.volumeAvailableCapacityForImportantUsage, bytes >= 0 else { return nil }
    return Int(bytes / Int64(megabyte))
  }
}

/// What this build is, for the diagnostics and for usage statistics.
enum AppFacts {
  static var versionName: String? {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  }

  static var versionCode: Int? {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
  }

  static var abi: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }
}
