import AVFoundation
import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers

// dsh/launch, after ohos/.../LaunchPlugin.ets, and dsh/launch_clip, after
// android/.../launch/LaunchClipPlugin.kt. See lib/launch/launch_state.dart.
//
// iOS's own launch screen is a fixed storyboard: here a blank page in the system's background
// colour (LaunchImage is one transparent pixel), which can't play or change anything. What
// moves is Dart's launch screen, whose first frame paints that same page. So `systemIcon` is
// false, Dart brings the icon in with its motion, and there is no system splash to hand over.

final class LaunchChannel {
  /// The icon's square: Android's 160 dp, in points.
  private static let iconPoints: CGFloat = 160

  /// What `UIBezierPath` needs to come close to the shape the home screen cuts icons to.
  private static let iconCorner: CGFloat = 0.2237

  /// By the alternate icon's name (LauncherIconChannel in DshPlugin.swift).
  private static let launchIcons = [
    "AppIconNight": "LaunchIconNight",
    "AppIconFrost": "LaunchIconFrost",
    "AppIconInk": "LaunchIconInk",
  ]

  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/launch", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "begin", "snapshot": result(Self.describe())
      case "reveal": result(false)
      case "mark":
        let name = (call.arguments as? [String: Any])?["name"] as? String ?? ""
        StartupWatch.shared.mark("launch screen: \(name)")
        result(nil)
      case "done":
        StartupWatch.shared.mark("launch screen: gone")
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func describe() -> [String: Any] {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let dark = (scene?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
    let scale = scene?.screen.scale ?? UIScreen.main.scale
    let side = Int((iconPoints * scale).rounded())
    // systemBackgroundColor at the launch screen's level.
    let page = dark ? 0xFF00_0000 : 0xFFFF_FFFF
    var reply: [String: Any] = [
      "active": true,
      "sdk": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
      "systemSplash": false,
      "systemIcon": false,
      "iconPx": side,
      "background": page,
      "backgroundBottom": page,
      "dark": dark,
      // As on HarmonyOS: the engine lives in this process and Dart starts it, so at a cold
      // start it isn't running yet. Dart reads this only while the active host is this phone.
      "coldEngine": EngineChannel.isBundled,
    ]
    if let pixels = iconPixels(side: side) { reply["icon"] = FlutterStandardTypedData(bytes: pixels) }
    return reply
  }

  /// The chosen icon as Dart's motion draws it: RGBA, premultiplied, cut to the home screen's
  /// shape since the file itself is a plain square. Nil leaves the motion without one.
  private static func iconPixels(side: Int) -> Data? {
    guard side > 0, let icon = chosenIcon()?.cgImage else { return nil }
    var pixels = Data(count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: side * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      let square = CGRect(x: 0, y: 0, width: side, height: side)
      context.interpolationQuality = .high
      context.addPath(UIBezierPath(roundedRect: square, cornerRadius: CGFloat(side) * iconCorner).cgPath)
      context.clip()
      context.draw(icon, in: square)
      return true
    }
    return drawn ? pixels : nil
  }

  /// Image sets of their own: an app icon's set isn't a dependable source for `UIImage(named:)`.
  private static func chosenIcon() -> UIImage? {
    let name = UIApplication.shared.alternateIconName.flatMap { launchIcons[$0] } ?? "LaunchIconMist"
    return UIImage(named: name)
  }
}

// MARK: - dsh/launch_clip

/// A custom launch screen's clip on a Flutter texture: silent, played once, the last frame stays.
/// AVFoundation doesn't read WebM, so a WebM file is refused at `probe`.
final class LaunchClipChannel {
  private static let posterSide: CGFloat = 1440

  private let channel: FlutterMethodChannel
  private let textures: any FlutterTextureRegistry
  private var clips: [Int64: LaunchClip] = [:]

  init(messenger: any FlutterBinaryMessenger, textures: any FlutterTextureRegistry) {
    channel = FlutterMethodChannel(name: "dsh/launch_clip", binaryMessenger: messenger)
    self.textures = textures
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    let id = (args["texture"] as? NSNumber)?.int64Value ?? -1
    switch call.method {
    case "probe":
      guard let path = args["path"] as? String, let poster = args["poster"] as? String else {
        return result(FlutterError(code: "invalid", message: nil, details: nil))
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let answer = Self.probe(path: path, poster: poster)
        onMain { result(answer) }
      }
    case "open": open(args["path"] as? String, result: result)
    case "play":
      clips[id]?.play()
      result(clips[id] != nil)
    case "close":
      close(id)
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ path: String?, result: @escaping FlutterResult) {
    guard let path, FileManager.default.isReadableFile(atPath: path) else { return result(nil) }
    let clip = LaunchClip(url: URL(fileURLWithPath: path))
    let id = textures.register(clip)
    clips[id] = clip
    clip.onFrame = { [weak self] in self?.textures.textureFrameAvailable(id) }
    clip.onShowing = { [weak self] in self?.send("showing", id) }
    clip.onDone = { [weak self] in self?.send("done", id) }
    clip.prepare { [weak self] ready in
      if ready {
        result(["texture": id])
      } else {
        self?.close(id)
        result(nil)
      }
    }
  }

  private func send(_ method: String, _ id: Int64) {
    channel.invokeMethod(method, arguments: ["texture": id])
  }

  private func close(_ id: Int64) {
    guard let clip = clips.removeValue(forKey: id) else { return }
    clip.close()
    textures.unregisterTexture(id)
  }

  /// The length and the frame as shown (rotation applied), with the first frame written as a PNG
  /// at `poster`; nil when it isn't a video this phone can play. Blocks while the file is read.
  private static func probe(path: String, poster: String) -> [String: Int]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else { return nil }
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0 else { return nil }
    let shown = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(shown.width).rounded())
    let height = Int(abs(shown.height).rounded())
    guard width > 0, height > 0 else { return nil }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: posterSide, height: posterSide)
    guard
      let frame = try? generator.copyCGImage(at: .zero, actualTime: nil),
      savePNG(frame, to: URL(fileURLWithPath: poster))
    else { return nil }
    return ["durationMs": Int((seconds * 1000).rounded()), "width": width, "height": height]
  }

  private static func savePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      return false
    }
    CGImageDestinationAddImage(sink, image, nil)
    return CGImageDestinationFinalize(sink)
  }
}

private final class LaunchClip: NSObject, FlutterTexture {
  var onFrame: (() -> Void)?
  var onShowing: (() -> Void)?
  var onDone: (() -> Void)?

  private let asset: AVURLAsset
  private let player = AVPlayer()
  private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
  ])

  /// `latest` is read on the raster thread.
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  private var item: AVPlayerItem?
  private var statusWatch: NSKeyValueObservation?
  private var link: CADisplayLink?
  private var answer: ((Bool) -> Void)?
  private let audio = IOSAudioSessionLease(role: .silentVideo)
  private var prepared = false
  private var wantPlay = false
  private var started = false
  private var showing = false
  private var over = false

  init(url: URL) {
    asset = AVURLAsset(url: url)
    super.init()
    audio.onRevoked = { [weak self] _ in self?.finish() }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  func prepare(_ done: @escaping (Bool) -> Void) {
    answer = done
    asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) { [weak self] in
      onMain { self?.assetLoaded() }
    }
  }

  private func assetLoaded() {
    guard !over else { return }
    var failure: NSError?
    let loaded = asset.statusOfValue(forKey: "tracks", error: &failure) == .loaded && asset.isPlayable
    guard loaded, let track = asset.tracks(withMediaType: .video).first else { return reply(false) }
    let item = AVPlayerItem(asset: asset)
    // A phone records turned, with the turn in the track: the texture needs it upright.
    if !track.preferredTransform.isIdentity {
      item.videoComposition = AVVideoComposition(propertiesOf: asset)
    }
    item.add(output)
    self.item = item
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(ended), name: .AVPlayerItemDidPlayToEndTime, object: item)
    center.addObserver(self, selector: #selector(ended), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
    statusWatch = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
      onMain { self?.statusChanged() }
    }
    player.isMuted = true
    player.actionAtItemEnd = .pause
    player.preventsDisplaySleepDuringVideoPlayback = false
    player.replaceCurrentItem(with: item)
  }

  private func statusChanged() {
    guard !over, let item else { return }
    switch item.status {
    case .readyToPlay:
      guard !prepared else { return }
      prepared = true
      reply(true)
      if wantPlay { start() }
    case .failed:
      if answer != nil { reply(false) } else { finish() }
    default: break
    }
  }

  private func reply(_ ready: Bool) {
    let done = answer
    answer = nil
    done?(ready)
  }

  func play() {
    wantPlay = true
    if prepared { start() }
  }

  private func start() {
    guard !started, !over else { return }
    started = true
    // With no other user this is ambient. When speech/PiP already owns an
    // output group, join without changing its configuration or activation.
    // Recording/exclusive media wins; this muted startup clip may be skipped.
    do {
      audio.setOutputStop { [player] in player.pause() }
      try audio.acquire()
    } catch { finish(); return }
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
    player.play()
    if !audio.isValid || over { player.pause(); finish() }
  }

  @objc private func tick() {
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    lock.lock()
    latest = buffer
    lock.unlock()
    onFrame?()
    if !showing {
      showing = true
      onShowing?()
    }
  }

  /// Posted on any thread.
  @objc private func ended() {
    onMain { [weak self] in self?.finish() }
  }

  private func finish() {
    guard !over else { return }
    tick()
    stopPumping()
    onDone?()
  }

  private func stopPumping() {
    over = true
    link?.invalidate()
    link = nil
    // Stop the output before releasing the session membership.
    player.pause()
    audio.release()
  }

  func close() {
    stopPumping()
    answer = nil
    NotificationCenter.default.removeObserver(self)
    statusWatch?.invalidate()
    statusWatch = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    item = nil
    lock.lock()
    latest = nil
    lock.unlock()
  }
}

// MARK: - Startup watch

/// dsh/startup: how far Dart has got (lib/launch/startup_trace.dart).
final class StartupChannel {
  private let channel: FlutterMethodChannel

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/startup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "mark":
        StartupWatch.shared.mark(call.arguments as? String ?? "")
        result(nil)
      case "finished":
        StartupWatch.shared.finished()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// A launch that never gets to the app is a blank page, and a TestFlight build has no console to
/// read. If Flutter hasn't drawn anything after a few seconds, or the launch screen is still up
/// well after that, this says on the screen how far things got, so a photo is enough to tell.
/// It goes away by itself if the app gets there. Main thread only.
final class StartupWatch {
  static let shared = StartupWatch()

  private static let noFrameAfter: TimeInterval = 6
  private static let stillUpAfter: TimeInterval = 15

  private let born = Date()
  private var stages: [String] = []
  private var isFinished = false
  private var armedAt: Date?
  private weak var note: UILabel?

  func mark(_ stage: String) {
    NSLog("[dsh-startup] %@", stage)
    stages.append(String(format: "%5.1fs %@", Date().timeIntervalSince(born), stage))
    if let note { note.text = report(note.window) }
  }

  func finished() {
    isFinished = true
    NSLog("[dsh-startup] finished")
    note?.removeFromSuperview()
  }

  /// From the scene, once it's active.
  func arm(_ window: UIWindow?) {
    guard armedAt == nil, let window else { return }
    armedAt = Date()
    check(window)
  }

  private func check(_ window: UIWindow?) {
    guard let window, let armedAt, !isFinished else { return }
    let flutter = window.rootViewController as? FlutterViewController
    let waited = Date().timeIntervalSince(armedAt)
    let drawing = flutter?.isDisplayingFlutterUI == true
    if waited >= (drawing ? Self.stillUpAfter : Self.noFrameAfter) {
      show(in: window)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak window] in self?.check(window) }
  }

  private func show(in window: UIWindow) {
    let text = report(window)
    if let note {
      note.text = text
      return
    }
    NSLog("[dsh-startup] stuck:\n%@", text)
    let label = UILabel()
    label.numberOfLines = 0
    label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .label
    label.backgroundColor = .secondarySystemBackground
    label.text = text
    label.isUserInteractionEnabled = false
    label.translatesAutoresizingMaskIntoConstraints = false
    window.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      label.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 16),
    ])
    note = label
  }

  private func report(_ window: UIWindow?) -> String {
    let frameworks = Bundle.main.privateFrameworksURL
    func has(_ path: String) -> String {
      guard let url = frameworks?.appendingPathComponent(path) else { return "?" }
      return FileManager.default.fileExists(atPath: url.path) ? "yes" : "NO"
    }
    let embedded = frameworks
      .flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
      .map { $0.replacingOccurrences(of: ".framework", with: "") }
      .sorted()
      .joined(separator: " ")
    let root = window?.rootViewController
    let flutter = root as? FlutterViewController
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return [
      "DSH Go is stuck starting. Please send a photo of this.",
      "\(version) (\(build))  iOS \(UIDevice.current.systemVersion)",
      "root \(root.map { "\(type(of: $0))" } ?? "none")  drawing \(flutter?.isDisplayingFlutterUI == true)",
      "App binary \(has("App.framework/App"))  assets \(has("App.framework/flutter_assets"))",
      "frameworks: \(embedded ?? "?")",
      "stages:",
      stages.isEmpty ? "  (Dart has said nothing)" : stages.suffix(20).joined(separator: "\n"),
    ].joined(separator: "\n")
  }
}
