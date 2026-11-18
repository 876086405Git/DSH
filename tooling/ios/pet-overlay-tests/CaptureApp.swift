import Flutter
import CoreMedia
import CoreVideo
import UIKit

// Same signature as the real app's navigation bridge. The fixture records
// requests only: no chat, agent, phone operation or approval is executed.
enum SystemEntries {
  static var held: [[String: String]] = []
  static func send(_ entry: [String: String]) { held.append(entry) }
}

private final class FixtureMessenger: FlutterBinaryMessenger {}
private final class FixtureRegistrar: FlutterPluginRegistrar {
  private let binary = FixtureMessenger()
  func messenger() -> any FlutterBinaryMessenger { binary }
  func lookupKey(forAsset asset: String) -> String { asset }
}

@main
@MainActor
final class CaptureApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    if CommandLine.arguments.contains("--reset-fixture-consent") {
      UserDefaults.standard.removeObject(forKey: "dsh.ios.petOverlay.enabled")
      UserDefaults.standard.removeObject(forKey: "dsh.ios.petOverlay.alwaysShow")
    }
    let window = UIWindow(frame: UIScreen.main.bounds)
    self.window = window
    window.rootViewController = CaptureController()
    window.makeKeyAndVisible()
    return true
  }
}

@MainActor
private final class CaptureController: UIViewController {
  private let registrar = FixtureRegistrar()
  private let status = UILabel()
  private var taskID = 0
  private var id = "deepy-whale"
  private var timer: Timer?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    // A separate fixture bundle and preferences domain, never production data.
    let owner = IOSPetOverlay.shared
    owner.register(registrar: registrar)
    owner.onTaskPauseRequested = { [weak self] id in self?.record("pause", id: id) }
    owner.onTaskStopConfirmed = { [weak self] id in
      self?.record("confirmed-stop", id: id)
      IOSPetOverlay.shared.endPhoneTask(id: id)
    }
    owner.onTaskResumeConfirmed = { [weak self] id in self?.record("confirmed-resume", id: id) }
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 200),
    ])
    let title = UILabel()
    title.text = "Pet PiP · synthetic fixture"
    title.font = .preferredFont(forTextStyle: .headline)
    stack.addArrangedSubview(title)
    for (title, selector) in [
      ("Enable pet (foreground confirmation)", #selector(enable)),
      ("Begin synthetic phone task", #selector(begin)),
      ("Start PiP (explicit user button)", #selector(start)),
      ("End synthetic task", #selector(end)),
      ("Always show (separate confirmation)", #selector(always)),
      ("Switch pet", #selector(switchPet)),
      ("Review paused task", #selector(review)),
      ("Disable", #selector(disable)),
    ] {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.addTarget(self, action: selector, for: .touchUpInside)
      stack.addArrangedSubview(button)
    }
    status.numberOfLines = 0
    status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    stack.addArrangedSubview(status)
    push()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        let state = IOSPetOverlay.shared.statusSnapshot
        self?.status.text = ["enabled", "possible", "active", "keepingAlive", "paused", "errorCode"]
          .map { "\($0)=\(state[$0] ?? "nil")" }.joined(separator: "\n")
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    do { try captureFrames() }
    catch {
      let result = ["success": false, "error": String(describing: type(of: error)), "runID": runID] as [String: Any]
      if let bytes = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
        try? bytes.write(to: documents.appendingPathComponent("capture-result.json"), options: .atomic)
      }
    }
  }

  private var channel: FlutterMethodChannel { FlutterMethodChannel.testChannels["dsh/pet_overlay"]! }
  private func call(_ method: String, _ args: [String: Any] = [:]) {
    channel.callTestMethod(method, arguments: args) { [weak self] result in
      if let error = result as? FlutterError { self?.status.text = "\(error.code)" }
    }
  }
  @objc private func enable() { call("setEnabled", ["enabled": true]) }
  @objc private func disable() { call("setEnabled", ["enabled": false]) }
  @objc private func always() { call("setAlwaysShow", ["on": true]) }
  @objc private func start() { call("startPictureInPicture") }
  @objc private func review() { call("reviewPausedTask") }
  @objc private func begin() {
    taskID += 1
    IOSPetOverlay.shared.beginPhoneTask(id: taskID, sessionID: "synthetic-session", line: "Maps · fixture only")
    IOSPetOverlay.shared.updatePhoneTask(id: taskID, line: "Maps · fixture only", progress: 0.4)
  }
  @objc private func end() { IOSPetOverlay.shared.endPhoneTask(id: taskID) }
  @objc private func switchPet() { id = id == "deepy-whale" ? "whale-girl" : "deepy-whale"; push() }
  private func push() {
    call("push", ["state": "working", "tier": 1, "packId": id, "size": "medium", "active": true,
      "target": ["host": "{\"kind\":\"local\",\"id\":\"local\"}", "sessionId": "synthetic-session"],
      "bubble": ["id": "fixture", "text": "Fixture · working", "untilMs": Date().timeIntervalSince1970 * 1000 + 60000]])
  }

  private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
  private var runID: String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--capture-run-id"), index + 1 < args.count else { return "manual" }
    return args[index + 1]
  }
  private func record(_ action: String, id: Int) {
    let entry: [String: Any] = ["action": action, "taskId": id, "synthetic": true]
    if let bytes = try? JSONSerialization.data(withJSONObject: entry) {
      try? bytes.write(to: documents.appendingPathComponent("last-task-action.json"))
    }
  }

  /// These PNGs are made by the production UIKit renderer with the production
  /// assets. No audio/PiP capability is activated by automatic capture.
  private func captureFrames() throws {
    try verifySampleOrientation()
    let output = documents.appendingPathComponent("frames", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var names: [String] = []
    let renderer = PetOverlayFrameRenderer { Bundle.main.url(forResource: $0, withExtension: nil) }
    for packID in ["deepy-whale", "whale-girl"] {
      let pack = try renderer.load(packID: packID)
      for name in PetOverlayState.names.sorted() {
        for size in ["small", "medium", "large"] {
          let state = PetOverlayState(["state": name, "tier": name == "juggling" ? 2 : 3,
            "packId": packID, "size": size,
            "bubble": ["id": "fixture", "text": "测试 · Waiting for your confirmation", "untilMs": 10000]])
          let animation = pack.primary(state: name, tier: state.tier)
          let frame = PetOverlayFrameSelection(animation: animation,
            index: animation.frames.count / 2, nextMilliseconds: nil)
          var phone = PetOverlayPhoneTask(id: 1, sessionID: "synthetic", line: "Maps · synthetic task")
          phone.progress = 0.4
          let image = try renderer.render(state: state, frame: frame, phoneTask: phone,
            paused: false, nowMilliseconds: 0)
          guard let png = UIImage(cgImage: image).pngData() else { throw PetOverlayPackFailure() }
          let file = "\(packID)-\(name)-\(size).png"
          try png.write(to: output.appendingPathComponent(file))
          names.append(file)
        }
      }
    }
    let receipt: [String: Any] = ["success": true, "runID": runID, "frames": names,
      "system": UIDevice.current.systemVersion, "device": UIDevice.current.model,
      "sampleBufferBGRAOrientation": "passed",
      "scope": "Production Swift UIKit renderer and BGRA sample-buffer factory + Apple SDK; Flutter channel uses fixture shim. PiP duration/energy not tested.",
      "defaultState": IOSPetOverlay.shared.statusSnapshot]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      .write(to: documents.appendingPathComponent("capture-result.json"), options: .atomic)
  }

  private func verifySampleOrientation() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1; format.opaque = true; format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { ctx in
      UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
      UIColor.green.setFill(); ctx.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
      UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 2, width: 2, height: 2))
      UIColor.white.setFill(); ctx.fill(CGRect(x: 2, y: 2, width: 2, height: 2))
    }
    let sample = try PetOverlayPictureInPicture.sampleBuffer(from: image.cgImage!)
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw PetOverlayPackFailure("calibration_buffer") }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
      throw PetOverlayPackFailure("calibration_buffer")
    }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let expected: [(Int, Int, [UInt8])] = [
      (0, 0, [0, 0, 255, 255]), (3, 0, [0, 255, 0, 255]),
      (0, 3, [255, 0, 0, 255]), (3, 3, [255, 255, 255, 255]),
    ]
    for (x, y, bgra) in expected {
      for channel in 0..<4 where abs(Int(base[y * stride + 4 * x + channel]) - Int(bgra[channel])) > 1 {
        throw PetOverlayPackFailure("calibration_bgra_orientation")
      }
    }
  }
}
