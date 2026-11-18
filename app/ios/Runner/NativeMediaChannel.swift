import AVFoundation
import Darwin
import Flutter
import UIKit

// dsh/native-media and its events, after ohos/.../NativeMediaPlugin.ets, NativeMediaPolicy.ets
// and android/.../nativemedia/: a plugin's one audio clip and one caption line, for one owner
// at a time. Dart (lib/plugins/native/native_capabilities.dart) decides what may run; this
// side ends it by itself when the app leaves the screen, and reports `owner.revoked`.
//
// `voice` isn't offered, as on HarmonyOS. AVAudioEngine's echo cancelling is for what that
// engine plays and this clip doesn't go through it, so the phone's own speaker would read as
// the person speaking and stop the clip. Doing it properly means playing through the engine,
// tuned on a real phone. Dart filters by `capabilities`, so a plugin that asks for listening
// just goes without, and its clip and caption go on.

private final class MediaOwner {
  let token: String
  let generation: Int
  let lease: String

  init?(_ args: [String: Any]) {
    guard
      let token = args["owner"] as? String,
      token.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil,
      let generation = args["generation"] as? Int,
      generation >= 0, generation <= Int(Int32.max),
      let lease = args["lease"] as? String,
      !lease.isEmpty, lease.count <= 256,
      !lease.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return nil }
    self.token = token
    self.generation = generation
    self.lease = lease
  }

  func matches(_ args: [String: Any]) -> Bool {
    args["owner"] as? String == token && args["generation"] as? Int == generation && args["lease"] as? String == lease
  }
}

private struct MediaFailure: Error {
  let code: String
}

/// The caption dependency is created only for an actual overlay request.
/// Disposal can hide an existing instance without constructing one.
protocol IOSNativeMediaCaption: AnyObject {
  func setTop(_ value: CGFloat)
  func show(_ value: String) -> Bool
  func update(_ value: String) -> Bool
  func hide()
}

final class NativeMediaChannel: NSObject, FlutterStreamHandler, AVAudioPlayerDelegate {
  private static let methodsNamingAnOwner: Set<String> = [
    "play", "pause", "resume", "stop", "disposeOwner",
    "requestVoiceGrant", "startVoice", "stopVoice",
    "showOverlay", "updateOverlay", "hideOverlay",
  ]
  private static let maxCaptionCharacters = 240
  private static let maxCaptionBytes = 1024

  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var owner: MediaOwner?
  private var player: AVAudioPlayer?
  private let audioCoordinator: IOSAudioSessionCoordinator
  private let audio: IOSAudioSessionLease

  /// Bumped by anything that ends the clip: one still being read must not start after that.
  private var clipGeneration = 0
  private var clipLoading = false
  private var wantPlaying = true
  private let captionFactory: (@escaping () -> Void) -> IOSNativeMediaCaption
  private var storedCaption: IOSNativeMediaCaption?
  private var caption: IOSNativeMediaCaption {
    if let storedCaption { return storedCaption }
    let next = captionFactory { [weak self] in self?.captionClosed() }
    storedCaption = next
    return next
  }

  init(messenger: any FlutterBinaryMessenger, audioCoordinator: IOSAudioSessionCoordinator = .shared,
       captionFactory: @escaping (@escaping () -> Void) -> IOSNativeMediaCaption = { MediaCaption(onClose: $0) }) {
    precondition(Thread.isMainThread)
    self.captionFactory = captionFactory
    self.audioCoordinator = audioCoordinator
    audio = IOSAudioSessionLease(role: .nativeMedia, coordinator: audioCoordinator)
    methods = FlutterMethodChannel(name: "dsh/native-media", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/native-media/events", binaryMessenger: messenger)
    super.init()
    audio.onRevoked = { [weak self] _ in
      guard let self, self.player != nil else { return }
      self.clipOver("audio.stopped", reason: "interrupted")
    }
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  deinit {
    // No call to caption or disposeLocal here: lazy construction during
    // NSObject deinit must not try to create a new weak reference to self.
    let oldPlayer = player
    let oldCaption = storedCaption
    let audio = audio
    IOSAudioMainThreadCleanup {
      oldPlayer?.delegate = nil
      oldPlayer?.stop()
      audio.release()
      oldCaption?.hide()
    }.perform()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  /// No one left to hear about it: nothing may keep playing.
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    disposeLocal()
    return nil
  }

  private var onScreen: Bool {
    UIApplication.shared.applicationState != .background
  }

  // MARK: The channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    switch call.method {
    case "capabilities": return result(["features": ["audio", "overlay"]])
    case "activate": return activate(args, result: result)
    default: break
    }
    guard Self.methodsNamingAnOwner.contains(call.method) else { return result(FlutterMethodNotImplemented) }
    guard let current = owner, current.matches(args) else {
      // An owner that's already gone is already disposed.
      return result(call.method == "disposeOwner" ? nil : Self.failure("stale-owner"))
    }
    switch call.method {
    case "play": play(current, args, result: result)
    case "pause":
      if setPlaying(false) { result(nil) } else { result(Self.failure("audio")) }
    case "resume":
      if onScreen && setPlaying(true) { result(nil) } else { result(Self.failure("audio")) }
    case "stop":
      releaseClip()
      result(nil)
    case "disposeOwner":
      disposeLocal()
      result(nil)
    case "showOverlay": showCaption(args, update: false, result: result)
    case "updateOverlay": showCaption(args, update: true, result: result)
    case "hideOverlay":
      storedCaption?.hide()
      result(nil)
    default: result(Self.failure("unsupported"))
    }
  }

  private static func failure(_ code: String) -> FlutterError {
    FlutterError(code: code, message: "native media: \(code)", details: nil)
  }

  private func activate(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let next = MediaOwner(args) else { return result(Self.failure("bad-request")) }
    guard onScreen else { return result(Self.failure("not-foreground")) }
    guard sink != nil else { return result(Self.failure("stale-owner")) }
    // A new owner replaces the old one, which Dart has disposed (or is disposing) already.
    disposeLocal()
    owner = next
    if let top = args["top"] as? NSNumber { caption.setTop(CGFloat(top.doubleValue)) }
    result(nil)
  }

  // MARK: The clip

  private func play(_ current: MediaOwner, _ args: [String: Any], result: @escaping FlutterResult) {
    guard onScreen else { return result(Self.failure("not-foreground")) }
    guard
      let path = args["privatePath"] as? String,
      let type = args["contentType"] as? String,
      let hint = Self.fileHint(type),
      Self.isClipPath(path, of: current)
    else { return result(Self.failure("media-invalid")) }
    releaseClip()
    // A valid new foreground play request can recover after media reset.
    // This is the existing authorized plugin effect entry, not proof that
    // Swift observed a separate physical tap for each effect.
    let activeRequest = UIApplication.shared.applicationState == .active
      && UIApplication.shared.isProtectedDataAvailable
    if activeRequest { audioCoordinator.retry(userInitiated: true) }
    let mine = clipGeneration
    let audioEnvironment = audioCoordinator.environmentGeneration
    clipLoading = true
    wantPlaying = true
    DispatchQueue.global(qos: .userInitiated).async {
      let loaded = Result { try Self.load(path: path, hint: hint) }
      onMain { [weak self] in
        guard let self else { return }
        guard mine == self.clipGeneration, self.owner === current else { return result(Self.failure("stale-owner")) }
        self.clipLoading = false
        guard self.onScreen, self.audioCoordinator.environmentGeneration == audioEnvironment else {
          return result(Self.failure("audio"))
        }
        switch loaded {
        case .failure(let error): result(Self.failure((error as? MediaFailure)?.code ?? "media-invalid"))
        case .success(let clip):
          do {
            try self.start(clip)
            guard mine == self.clipGeneration, self.owner === current else {
              return result(Self.failure("stale-owner"))
            }
            result(nil)
          } catch {
            if mine == self.clipGeneration, self.owner === current { self.releaseClip() }
            result(Self.failure((error as? MediaFailure)?.code ?? "audio"))
          }
        }
      }
    }
  }

  /// Only `<caches>/native-media/<owner>/clip`, where Dart's download puts it
  /// (path_provider's temporary directory is the caches directory here). Never a URL or
  /// another path, and nothing on the way may be a link.
  private static func isClipPath(_ path: String, of current: MediaOwner) -> Bool {
    guard let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
      return false
    }
    let expected = "\(caches)/native-media/\(current.token)/clip"
    guard path == expected else { return false }
    let root = URL(fileURLWithPath: caches).resolvingSymlinksInPath().path
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == "\(root)/native-media/\(current.token)/clip"
  }

  /// nil for a type outside the channel's list. `audio/ogg` is on the list but no player here
  /// reads it, so that one fails at `load`.
  private static func fileHint(_ type: String) -> String? {
    switch type {
    case "audio/mpeg": return AVFileType.mp3.rawValue
    case "audio/wav": return AVFileType.wav.rawValue
    case "audio/mp4": return AVFileType.m4a.rawValue
    case "audio/aac": return "public.aac-audio"
    case "audio/ogg": return "org.xiph.ogg-audio"
    default: return nil
    }
  }

  /// 1 byte to 16 MiB of a real file, read whole through one descriptor, so a path swapped
  /// after the check changes nothing and the file is Dart's to delete from here on.
  private static func load(path: String, hint: String) throws -> AVAudioPlayer {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw MediaFailure(code: "media-invalid") }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    let limit = 16 * 1024 * 1024
    guard
      fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 1, Int(info.st_size) <= limit
    else { throw MediaFailure(code: "media-invalid") }
    guard let data = try file.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
      throw MediaFailure(code: "media-invalid")
    }
    do {
      return try AVAudioPlayer(data: data, fileTypeHint: hint)
    } catch {
      throw MediaFailure(code: "media-invalid")
    }
  }

  private func start(_ clip: AVAudioPlayer) throws {
    do {
      // Recording outranks media. Other outputs are synchronously stopped by
      // the coordinator before this exclusive configuration is installed.
      audio.setOutputStop { [clip] in clip.delegate = nil; clip.stop() }
      try audio.acquire()
    } catch {
      throw MediaFailure(code: (error as? IOSAudioSessionFailure) == .busy ? "busy" : "audio")
    }
    clip.delegate = self
    player = clip
    guard wantPlaying else { return }
    guard clip.play(), player === clip, audio.isValid else { throw MediaFailure(code: "audio") }
  }

  /// A pause while the clip is still being read holds until it's there.
  private func setPlaying(_ wanted: Bool) -> Bool {
    wantPlaying = wanted
    guard let player else { return clipLoading }
    guard audio.isValid else {
      clipOver("audio.stopped", reason: "interrupted")
      return false
    }
    if !wanted {
      player.pause()
      return true
    }
    return (player.isPlaying || player.play()) && self.player === player && audio.isValid
  }

  /// Stop the actual output before releasing our exact coordinator token.
  private func releaseClip() {
    clipGeneration += 1
    clipLoading = false
    player?.delegate = nil
    player?.stop()
    player = nil
    audio.release()
  }

  /// Ended by itself: nothing more of it, then the event.
  private func clipOver(_ kind: String, reason: String? = nil) {
    guard let current = owner else { return }
    releaseClip()
    emit(current, kind, reason: reason)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    onMain { [weak self] in
      guard let self, self.player === player else { return }
      if flag {
        self.clipOver("audio.ended")
      } else {
        self.clipOver("audio.error", reason: "player")
      }
    }
  }

  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    onMain { [weak self] in
      guard let self, self.player === player else { return }
      self.clipOver("audio.error", reason: "player")
    }
  }

  // MARK: The system ending things

  @objc private func wentAway() {
    onMain { [weak self] in self?.revoke("background") }
  }

  // MARK: The caption

  private func showCaption(_ args: [String: Any], update: Bool, result: @escaping FlutterResult) {
    let text = args["text"] as? String ?? ""
    guard text.unicodeScalars.count <= Self.maxCaptionCharacters, text.utf8.count <= Self.maxCaptionBytes else {
      return result(Self.failure("bad-request"))
    }
    let clean = text
      .replacingOccurrences(of: "[\\x{0000}-\\x{001F}\\x{007F}]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    if update {
      return result(caption.update(clean) ? nil : Self.failure("unsupported"))
    }
    guard onScreen else { return result(Self.failure("not-foreground")) }
    result(caption.show(clean) ? nil : Self.failure("unsupported"))
  }

  private func captionClosed() {
    guard let current = owner else { return }
    emit(current, "overlay.closed", reason: "user")
  }

  // MARK: Ending the owner

  private func disposeLocal() {
    owner = nil
    releaseClip()
    storedCaption?.hide()
  }

  private func revoke(_ reason: String) {
    guard let current = owner else { return }
    disposeLocal()
    emit(current, "owner.revoked", reason: reason)
  }

  private func emit(_ current: MediaOwner, _ kind: String, reason: String? = nil) {
    var event: [String: Any] = [
      "owner": current.token,
      "generation": current.generation,
      "lease": current.lease,
      "kind": kind,
    ]
    if let reason { event["reason"] = reason }
    sink?(event)
  }
}

// MARK: - The caption's view

/// The one line a plugin may float over the app, under the chat header; the × is the app's. In
/// the window rather than Flutter's view, which reorders its own subviews around platform views.
private final class MediaCaption: IOSNativeMediaCaption {
  private var top: CGFloat = 96
  private var text: String?
  private var pill: CaptionPill?
  private var topConstraint: NSLayoutConstraint?
  private let onClose: () -> Void

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  func setTop(_ value: CGFloat) {
    guard value > 0 else { return }
    top = value
    topConstraint?.constant = value
  }

  func show(_ value: String) -> Bool {
    text = value
    return place(value)
  }

  func update(_ value: String) -> Bool {
    guard text != nil else { return false }
    text = value
    return place(value)
  }

  func hide() {
    text = nil
    pill?.removeFromSuperview()
    pill = nil
    topConstraint = nil
  }

  /// An empty text keeps it waiting, unseen, for the first line.
  private func place(_ value: String) -> Bool {
    if let pill {
      pill.setText(value)
      return true
    }
    if value.isEmpty { return true }
    guard let window = topViewController()?.viewIfLoaded?.window else { return false }
    let view = CaptionPill { [weak self] in
      self?.hide()
      self?.onClose()
    }
    view.setText(value)
    view.translatesAutoresizingMaskIntoConstraints = false
    window.addSubview(view)
    let pinned = view.topAnchor.constraint(equalTo: window.topAnchor, constant: top)
    NSLayoutConstraint.activate([
      pinned,
      view.centerXAnchor.constraint(equalTo: window.centerXAnchor),
      view.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 16),
      view.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -16),
    ])
    pill = view
    topConstraint = pinned
    return true
  }
}

private final class CaptionPill: UIView {
  private static let keySide: CGFloat = 32
  private static let inset: CGFloat = 4

  private let label = UILabel()
  private let close = UIButton(type: .custom)
  private let onClose: () -> Void

  /// The app's 雾蓝 surfaces, as android/.../nativemedia/MediaOverlays.kt draws them.
  private static let surface = adaptive(0xEEF1F9, 0x1C1F28)
  private static let stroke = adaptive(0xDCE0E8, 0x343841)
  private static let ink = adaptive(0x1E232E, 0xE6E9F0)
  private static let muted = adaptive(0x646974, 0x9A9EA9)
  private static let field = adaptive(0xE7EBF4, 0x2D323C)

  private static func adaptive(_ light: Int, _ dark: Int) -> UIColor {
    UIColor { traits in
      let value = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
      )
    }
  }

  /// In the language the app shows: `flutter.app_language` is lib/state/locale_state.dart's.
  private static var closeLabel: String {
    let chosen = UserDefaults.standard.string(forKey: "flutter.app_language")
    let chinese = chosen == "zh" || (chosen != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
    return chinese ? "关闭字幕" : "Close caption"
  }

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
    super.init(frame: .zero)
    backgroundColor = Self.surface
    layer.cornerRadius = (Self.keySide + 2 * Self.inset) / 2
    layer.borderWidth = 1
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.14
    layer.shadowRadius = 6
    layer.shadowOffset = CGSize(width: 0, height: 2)

    label.font = .systemFont(ofSize: 14)
    label.textColor = Self.ink
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let symbol = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    close.setImage(UIImage(systemName: "xmark", withConfiguration: symbol), for: .normal)
    close.tintColor = Self.muted
    close.backgroundColor = Self.field
    close.layer.cornerRadius = Self.keySide / 2
    close.accessibilityLabel = Self.closeLabel
    close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    label.translatesAutoresizingMaskIntoConstraints = false
    close.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    addSubview(close)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
      close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
      close.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
      close.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
      close.widthAnchor.constraint(equalToConstant: Self.keySide),
      close.heightAnchor.constraint(equalToConstant: Self.keySide),
    ])
    updateBorder()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("not from a storyboard")
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    updateBorder()
  }

  /// A layer's colours don't follow the system by themselves.
  private func updateBorder() {
    layer.borderColor = Self.stroke.resolvedColor(with: traitCollection).cgColor
  }

  func setText(_ value: String) {
    if label.text != value { label.text = value }
  }

  @objc private func closeTapped() {
    onClose()
  }
}
