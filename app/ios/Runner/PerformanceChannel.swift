import Flutter
import UIKit

// dsh/performance and its events, after ohos/.../PerformancePlugin.ets and
// OhosThermalState.ets. The tier is a default, not a benchmark. iOS has nothing like
// Android's media performance class, so nothing here reads a phone as `high`.

final class PerformanceChannel: NSObject, FlutterStreamHandler {
  // Lower than Android's 5 GiB: 4 GB iPhones (11 to 13) report about 3.7 GiB and run
  // this app's effects fine. Only the 3 GB and smaller ones count as low.
  private static let lowMemoryBytes: UInt64 = 3584 * 1024 * 1024

  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let device = PerformanceChannel.readDevice()
  private var sink: FlutterEventSink?
  private var policy = ThermalPolicy()
  private var lowPower = false
  private var sequence = 0
  private var recovery: DispatchWorkItem?

  init(messenger: any FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/performance", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/performance/events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard call.method == "snapshot", let self else { return result(FlutterMethodNotImplemented) }
      self.refresh()
      result(self.snapshot())
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(changed), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    center.addObserver(self, selector: #selector(changed), name: .NSProcessInfoPowerStateDidChange, object: nil)
    // A suspended app hears neither of those.
    center.addObserver(self, selector: #selector(changed), name: UIApplication.didBecomeActiveNotification, object: nil)
    refresh()
  }

  /// The current snapshot on listen closes the gap between the method's answer and this stream.
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    events(snapshot())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// Posted on any thread.
  @objc private func changed() {
    onMain { [weak self] in self?.refresh() }
  }

  private func refresh() {
    let info = ProcessInfo.processInfo
    let thermalChanged = policy.update(info.thermalState, now: info.systemUptime)
    let powerChanged = info.isLowPowerModeEnabled != lowPower
    lowPower = info.isLowPowerModeEnabled
    scheduleRecovery()
    if thermalChanged || powerChanged {
      sequence += 1
      sink?(snapshot())
    }
  }

  /// At the deadline the state is read again: an old cool reading proves nothing.
  private func scheduleRecovery() {
    recovery?.cancel()
    recovery = nil
    guard let since = policy.coolSince else { return }
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    recovery = work
    let wait = max(since + ThermalPolicy.recovery - ProcessInfo.processInfo.systemUptime, 0.001)
    DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
  }

  private func snapshot() -> [String: Any] {
    var thermal: [String: Any] = [
      "platform": "ios",
      "supported": true,
      "listening": true,
      "lightweight": policy.lightweight || lowPower,
      "thermalLightweight": policy.lightweight,
      "lowPowerMode": lowPower,
      "level": policy.level,
      "recoveryAfterMs": Int(ThermalPolicy.recovery * 1000),
    ]
    if let status = policy.state?.rawValue { thermal["status"] = status }
    if let since = policy.coolSince { thermal["coolSinceUptimeMs"] = Int(since * 1000) }
    return ["sequence": sequence, "device": device, "thermal": thermal]
  }

  private static func readDevice() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let memory = info.physicalMemory
    let cores = info.processorCount
    let lowMemory = memory > 0 && memory < lowMemoryBytes
    let fewCores = cores > 0 && cores <= 2
    var reasons: [String] = []
    if lowMemory { reasons.append("memory_below_3_5_gib") }
    if fewCores { reasons.append("at_most_two_cores") }
    if reasons.isEmpty { reasons.append("no_low_tier_evidence") }
    return [
      "policyVersion": 1,
      "platform": "ios",
      "tier": lowMemory || fewCores ? "low" : "medium",
      "reasons": reasons,
      "totalMemoryBytes": Int(clamping: memory),
      "cpuCores": cores,
      "availableProcessors": info.activeProcessorCount,
      "cpuMaxKhz": [Int](),
      "cached": false,
      "measuredAtMs": Int(Date().timeIntervalSince1970 * 1000),
      "apiVersion": info.operatingSystemVersion.majorVersion,
    ]
  }
}

/// `serious` is where iOS says performance is affected, the nearest to Android's MODERATE and
/// HarmonyOS's WARM: `fair` is ordinary on a phone that's charging. Once light it stays light
/// until 30 seconds of being cool, in system uptime: product hysteresis, not a cooling time.
private struct ThermalPolicy {
  static let recovery: TimeInterval = 30

  private(set) var state: ProcessInfo.ThermalState?
  private(set) var lightweight = false
  private(set) var coolSince: TimeInterval?

  var level: String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    default: return "unknown"
    }
  }

  /// Whether anything observable changed.
  mutating func update(_ value: ProcessInfo.ThermalState, now: TimeInterval) -> Bool {
    let before = (state, lightweight, coolSince)
    switch value {
    case .serious, .critical:
      lightweight = true
      coolSince = nil
    case .nominal, .fair:
      if lightweight {
        if let since = coolSince {
          if now - since >= Self.recovery {
            lightweight = false
            coolSince = nil
          }
        } else {
          coolSince = now
        }
      }
    @unknown default:
      // Not evidence of cooling.
      return false
    }
    state = value
    return before.0 != state || before.1 != lightweight || before.2 != coolSince
  }
}
