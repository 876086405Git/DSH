import AVFoundation
import CoreFoundation
import Darwin
import Flutter
import Foundation

/// The existing dsh/companion_voice contract. Text-to-speech and fetched clips
/// are separate output domains, as on Android. Admission and events run on
/// MainActor and use the App's main-thread audio coordinator. Bounded file
/// reading and decoder construction run away from it. No microphone, network,
/// file writes or deletion are involved.
@MainActor
final class IOSCompanionVoice {
  private let channel: FlutterMethodChannel
  private let engine: IOSCompanionVoiceEngine
  private var timer: Timer?
  private var disposed = false

  init(messenger: any FlutterBinaryMessenger,
       pipAudioConfigured _: @escaping @MainActor () -> Bool) {
    channel = FlutterMethodChannel(name: "dsh/companion_voice", binaryMessenger: messenger)
    // Keep the old initializer label for AppDelegate source compatibility.
    // A snapshot predicate no longer grants or revokes a shared audio lease.
    let lease = IOSCompanionAudioLease(coordinator: .shared)
    engine = IOSCompanionVoiceEngine(speech: IOSCompanionSystemSpeech(),
      loader: IOSCompanionFileLoader(), audio: lease, now: IOSCompanionVoiceClock.now)
    engine.emit = { [weak self] event in
      guard let self, !self.disposed else { return }
      self.channel.invokeMethod("event", arguments: event.arguments)
    }
    engine.activityChanged = { [weak self] in self?.updateTimer() }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self, !self.disposed else { result(false); return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "ready": result(self.engine.ready(language: args["language"] as? String ?? "zh-CN"))
      case "speak": self.engine.speak(args, reply: { result($0) })
      case "play": self.engine.play(args, reply: { result($0) })
      case "stop": self.engine.stop(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Call before replacing the Flutter messenger. Terminal events are sent to
  /// the old messenger before this returns; no later callback can publish one.
  func dispose() {
    guard !disposed else { return }
    engine.dispose()
    disposed = true
    channel.setMethodCallHandler(nil)
    timer?.invalidate()
    timer = nil
  }

  private func updateTimer() {
    if !disposed && engine.hasWork {
      guard timer == nil else { return }
      let next = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
        DispatchQueue.main.async { self?.engine.poll() }
      }
      timer = next
      RunLoop.main.add(next, forMode: .common)
    } else {
      timer?.invalidate()
      timer = nil
    }
  }
}

// MARK: - Accepted work, identities and exact terminal events

struct IOSCompanionVoiceEvent: Equatable {
  let type: String
  let id: String
  var start: Int? = nil
  var end: Int? = nil
  var code: String? = nil

  var arguments: [String: Any] {
    var result: [String: Any] = ["type": type, "id": id]
    if let start { result["start"] = start }
    if let end { result["end"] = end }
    if let code { result["code"] = code }
    return result
  }
}

enum IOSCompanionSpeechEvent { case start, range(NSRange), done, cancelled }
enum IOSCompanionClipEnd: Equatable { case done, error }

@MainActor
protocol IOSCompanionSpeechOutput: AnyObject {
  var onEvent: ((AVSpeechUtterance, IOSCompanionSpeechEvent) -> Void)? { get set }
  func voiceIdentifier(language: String) -> String?
  func utterance(text: String, voice: String, rate: Float, pitch: Float) -> AVSpeechUtterance?
  func speak(_ utterance: AVSpeechUtterance)
  func stop()
}

protocol IOSCompanionClip: AnyObject {
  var duration: TimeInterval { get }
  @MainActor var onEnd: ((IOSCompanionClip, IOSCompanionClipEnd) -> Void)? { get set }
  @MainActor func play() -> Bool
  @MainActor func stop()
}

@MainActor
protocol IOSCompanionClipLoading: AnyObject {
  func load(id: String, path: String, cancellation: IOSCompanionVoiceCancellation,
            completion: @escaping @MainActor (Result<IOSCompanionClip, Error>) -> Void)
}

@MainActor
final class IOSCompanionVoiceEngine {
  static let maxTextUTF16 = 4_096
  static let maxQueuedUTF16 = 32_768
  static let maxSpeechItems = 32
  nonisolated static let maxClipSeconds: TimeInterval = 55
  static let speechStallSeconds: TimeInterval = 300
  static let loadSeconds: TimeInterval = 5

  var emit: ((IOSCompanionVoiceEvent) -> Void)?
  var activityChanged: (() -> Void)?
  private let speech: IOSCompanionSpeechOutput
  private let loader: IOSCompanionClipLoading
  private let audio: IOSCompanionAudioLease
  private let now: () -> TimeInterval?
  private var voice: String?
  private var speechGeneration = UUID()
  private var clipGeneration = UUID()
  private var queue: [SpeechJob] = []
  private var speaking: SpeechJob?
  private var playing: ClipJob?
  private var pending: Load?
  // A timed-out decoder may still be returning from an OS call. Do not start
  // another worker until that one actually returns, even after stop/dispose.
  private var loadingID: UUID?
  private var retiring = false
  private var disposed = false

  private final class Reply {
    private var callback: ((Bool) -> Void)?
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    func finish(_ accepted: Bool) {
      let next = callback
      callback = nil
      next?(accepted)
    }
  }
  private final class SpeechJob {
    let id: String, generation: UUID, utterance: AVSpeechUtterance
    var started = false
    var lastRangeEnd = 0
    var deadline: TimeInterval = 0
    init(id: String, generation: UUID, utterance: AVSpeechUtterance) {
      self.id = id; self.generation = generation; self.utterance = utterance
    }
  }
  private final class ClipJob {
    let id: String, generation: UUID, output: IOSCompanionClip, reply: Reply
    let deadline: TimeInterval
    var accepted = false
    var earlyEnd: IOSCompanionClipEnd?
    init(id: String, generation: UUID, output: IOSCompanionClip, reply: Reply,
         deadline: TimeInterval) {
      self.id = id; self.generation = generation; self.output = output
      self.reply = reply; self.deadline = deadline
    }
  }
  private final class Load {
    let token = UUID()
    let id: String, generation: UUID, audioEnvironment: UUID, deadline: TimeInterval, reply: Reply
    let cancellation = IOSCompanionVoiceCancellation()
    init(id: String, generation: UUID, audioEnvironment: UUID, deadline: TimeInterval, reply: Reply) {
      self.id = id; self.generation = generation; self.audioEnvironment = audioEnvironment
      self.deadline = deadline; self.reply = reply
    }
  }

  init(speech: IOSCompanionSpeechOutput, loader: IOSCompanionClipLoading,
       audio: IOSCompanionAudioLease, now: @escaping () -> TimeInterval?) {
    self.speech = speech; self.loader = loader; self.audio = audio; self.now = now
    speech.onEvent = { [weak self] utterance, event in self?.heard(utterance, event) }
    audio.onRevoked = { [weak self] code in self?.interrupt(code: code) }
  }

  var hasWork: Bool { speaking != nil || !queue.isEmpty || playing != nil || pending != nil }

  func ready(language: String) -> Bool {
    guard !disposed, language.utf8.count <= 64,
      language.range(of: "\\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,5}\\z", options: .regularExpression) != nil,
      let selected = speech.voiceIdentifier(language: language) else { return false }
    voice = selected
    return true
  }

  func speak(_ args: [String: Any], reply: @escaping (Bool) -> Void) {
    guard !disposed, !retiring, let id = Self.identifier(args["id"]), !uses(id),
      let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf16.count <= Self.maxTextUTF16, text.utf8.count <= 16_384,
      let flush = Self.boolean(args["flush"], fallback: false),
      let pitch = Self.number(args["pitch"], fallback: 1, within: 0.5...2),
      let multiplier = Self.number(args["rate"], fallback: 1, within: 0.1...4),
      let voice, now() != nil,
      let utterance = speech.utterance(text: text, voice: voice,
        rate: min(AVSpeechUtteranceMaximumSpeechRate,
          max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(multiplier))),
        pitch: Float(pitch)) else { reply(false); return }
    let jobs = queue + (speaking.map { [$0] } ?? [])
    guard flush || (jobs.count < Self.maxSpeechItems &&
      jobs.reduce(text.utf16.count, { $0 + $1.utterance.speechString.utf16.count }) <= Self.maxQueuedUTF16)
    else { reply(false); return }
    guard validLeaseOrEnd(), audio.acquire() else { reply(false); return }
    if flush { endSpeech("stopped", code: nil) }
    let job = SpeechJob(id: id, generation: speechGeneration, utterance: utterance)
    queue.append(job)
    reply(true)
    guard !disposed, job.generation == speechGeneration else { changed(); return }
    pumpSpeech()
    changed()
  }

  func play(_ args: [String: Any], reply: @escaping (Bool) -> Void) {
    guard !disposed, !retiring, loadingID == nil,
      let id = Self.identifier(args["id"]), !uses(id),
      let path = args["path"] as? String, Self.validPathText(path),
      let instant = now(), validLeaseOrEnd(), audio.mayAcquire else { reply(false); return }
    let load = Load(id: id, generation: clipGeneration, audioEnvironment: audio.environmentGeneration,
      deadline: instant + Self.loadSeconds,
      reply: Reply(reply))
    pending = load
    loadingID = load.token
    changed()
    loader.load(id: id, path: path, cancellation: load.cancellation) { [weak self] result in
      guard let self else {
        if case .success(let clip) = result { clip.stop() }
        load.reply.finish(false)
        return
      }
      self.loaded(load, result)
    }
  }

  func stop() { endAll("stopped", code: nil) }
  func interrupt(code: String) { endAll("stopped", code: code) }

  func dispose() {
    guard !disposed else { return }
    endAll("stopped", code: "disposed")
    disposed = true
    speech.onEvent = nil
    audio.onRevoked = nil
    emit = nil
    activityChanged?()
    activityChanged = nil
  }

  /// Called only while work exists and at event/start boundaries. The clock is
  /// monotonic including sleep. A suspended app delivers no timely guarantees;
  /// after it can run again, stale work is rejected before accepting callbacks.
  func poll() {
    guard !disposed, !retiring, hasWork else { return }
    if let load = pending, load.audioEnvironment != audio.environmentGeneration {
      pending = nil
      load.cancellation.cancel()
      load.reply.finish(false)
    }
    guard validLeaseOrEnd() else { return }
    guard let instant = now() else { endAll("error", code: "clock"); return }
    if let load = pending, instant >= load.deadline {
      pending = nil
      load.cancellation.cancel()
      load.reply.finish(false)  // Never accepted: no event, including late callbacks.
    }
    if let job = speaking, instant >= job.deadline { endSpeech("error", code: "timeout") }
    if let job = playing, instant >= job.deadline { endClip("error", code: "timeout") }
    changed()
  }

  private func uses(_ id: String) -> Bool {
    speaking?.id == id || queue.contains { $0.id == id } || playing?.id == id || pending?.id == id
  }

  private func validLeaseOrEnd() -> Bool {
    guard !audio.isHeld || audio.isValid else {
      endAll("stopped", code: "audio-replaced")
      return false
    }
    return true
  }

  private func pumpSpeech() {
    guard !disposed, !retiring, speaking == nil, !queue.isEmpty else { return }
    guard validLeaseOrEnd(), let instant = now(), audio.acquire() else {
      endSpeech("error", code: "audio"); changed(); return
    }
    let job = queue.removeFirst()
    guard job.generation == speechGeneration else { return }
    speaking = job
    job.deadline = instant + Self.speechStallSeconds
    speech.speak(job.utterance)
  }

  private func heard(_ utterance: AVSpeechUtterance, _ event: IOSCompanionSpeechEvent) {
    guard !disposed, !retiring, let job = speaking,
      job.generation == speechGeneration, job.utterance === utterance else { return }
    poll()
    guard speaking === job else { return }
    switch event {
    case .start:
      if !job.started {
        job.started = true
        if let instant = now() { job.deadline = instant + Self.speechStallSeconds }
        emit?(IOSCompanionVoiceEvent(type: "start", id: job.id))
      }
    case .range(let range):
      let length = utterance.speechString.utf16.count
      guard range.location != NSNotFound, range.location >= 0, range.length > 0,
        range.location <= length, range.length <= length - range.location else { return }
      // NSRange is already UTF-16, exactly what Dart String offsets use.
      // Neither grapheme counting nor NSString-to-Swift slicing belongs here.
      let end = range.location + range.length
      if end > job.lastRangeEnd {
        job.lastRangeEnd = end
        if let instant = now() { job.deadline = instant + Self.speechStallSeconds }
      }
      if !job.started { job.started = true; emit?(IOSCompanionVoiceEvent(type: "start", id: job.id)) }
      guard speaking === job else { return }
      emit?(IOSCompanionVoiceEvent(type: "range", id: job.id,
        start: range.location, end: end))
    case .done, .cancelled:
      speaking = nil // Remove identity before emitting or dispatching the next job.
      emit?(IOSCompanionVoiceEvent(type: event.isDone ? "done" : "stopped", id: job.id))
      pumpSpeech()
      changed()
    }
  }

  private func loaded(_ load: Load, _ result: Result<IOSCompanionClip, Error>) {
    guard loadingID == load.token else {
      if case .success(let clip) = result { clip.stop() }
      return
    }
    loadingID = nil
    guard !disposed, !retiring, pending === load, load.generation == clipGeneration,
      load.audioEnvironment == audio.environmentGeneration,
      !load.cancellation.isCancelled, let instant = now(), instant < load.deadline else {
      if pending === load { pending = nil }
      if case .success(let clip) = result { clip.stop() }
      load.reply.finish(false)
      changed()
      return
    }
    pending = nil
    guard case .success(let clip) = result else { load.reply.finish(false); changed(); return }
    guard clip.duration.isFinite, clip.duration > 0, clip.duration <= Self.maxClipSeconds,
      validLeaseOrEnd(), audio.acquire() else {
      clip.stop(); load.reply.finish(false); changed(); return
    }
    endClip("stopped", code: nil)
    let job = ClipJob(id: load.id, generation: clipGeneration, output: clip, reply: load.reply,
      deadline: instant + clip.duration + 3)
    playing = job
    clip.onEnd = { [weak self] output, event in self?.clipEnded(output, generation: job.generation, event) }
    let started = clip.play()
    guard playing === job, !disposed else { job.reply.finish(false); changed(); return }
    guard validLeaseOrEnd(), playing === job else { job.reply.finish(false); changed(); return }
    guard started else {
      // The player may even invoke its delegate inline and then return false.
      // The provisional identity has never been accepted, so retire it silently.
      endClip("error", code: "audio")
      changed()
      return
    }
    job.accepted = true
    job.reply.finish(true)
    guard playing === job else { changed(); return }
    emit?(IOSCompanionVoiceEvent(type: "start", id: job.id))
    if playing === job, let early = job.earlyEnd {
      clipEnded(clip, generation: job.generation, early)
    }
    changed()
  }

  private func clipEnded(_ output: IOSCompanionClip, generation: UUID, _ event: IOSCompanionClipEnd) {
    guard !disposed, !retiring, let job = playing, job.output === output,
      job.generation == generation, generation == clipGeneration else { return }
    if !job.accepted { if job.earlyEnd == nil { job.earlyEnd = event }; return }
    poll()
    guard playing === job else { return }
    playing = nil
    job.output.onEnd = nil
    job.output.stop()
    emit?(IOSCompanionVoiceEvent(type: event == .done ? "done" : "error", id: job.id,
      code: event == .error ? "decoder" : nil))
    changed()
  }

  private func endSpeech(_ terminal: String, code: String?) {
    speechGeneration = UUID()
    let old = (speaking.map { [$0] } ?? []) + queue
    speaking = nil
    queue.removeAll()
    speech.stop()
    for job in old { emit?(IOSCompanionVoiceEvent(type: terminal, id: job.id, code: code)) }
  }

  private func endClip(_ terminal: String, code: String?) {
    clipGeneration = UUID()
    guard let old = playing else { return }
    playing = nil
    old.output.onEnd = nil
    old.output.stop()
    if old.accepted { emit?(IOSCompanionVoiceEvent(type: terminal, id: old.id, code: code)) }
    else { old.reply.finish(false) }
  }

  private func endAll(_ terminal: String, code: String?) {
    guard !disposed, !retiring else { return }
    retiring = true
    let load = pending
    pending = nil
    load?.cancellation.cancel()
    endSpeech(terminal, code: code)
    endClip(terminal, code: code)
    load?.reply.finish(false)
    retiring = false
    changed()
  }

  private func changed() {
    if speaking == nil && queue.isEmpty && playing == nil { audio.release() }
    activityChanged?()
  }

  nonisolated static func identifier(_ value: Any?) -> String? {
    guard let id = value as? String, !id.isEmpty, id.utf8.count <= 128,
      id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
        (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
    return id
  }
  nonisolated static func validPathText(_ path: String) -> Bool {
    path.hasPrefix("/") && path.utf8.count <= 4_096 && !path.utf8.contains(0) &&
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
  }
  private static func number(_ value: Any?, fallback: Double, within range: ClosedRange<Double>) -> Double? {
    guard let value else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue.isFinite, range.contains(number.doubleValue) else { return nil }
    return number.doubleValue
  }
  private static func boolean(_ value: Any?, fallback: Bool) -> Bool? {
    guard let value else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }
}

private extension IOSCompanionSpeechEvent {
  var isDone: Bool { if case .done = self { return true }; return false }
}

// MARK: - Membership in the App's shared audio session

@MainActor
final class IOSCompanionAudioLease {
  var onRevoked: ((String) -> Void)?
  private let coordinator: IOSAudioSessionCoordinator
  private let lease: IOSAudioSessionLease

  init(coordinator: IOSAudioSessionCoordinator) {
    self.coordinator = coordinator
    lease = IOSAudioSessionLease(role: .companion, coordinator: coordinator)
    lease.onRevoked = { [weak self] reason in self?.onRevoked?(reason.companionCode) }
  }
  var isHeld: Bool { lease.isHeld }
  var isValid: Bool { lease.isValid }
  var mayAcquire: Bool { coordinator.blocker(for: .companion) == nil }
  var environmentGeneration: UUID { coordinator.environmentGeneration }
  func acquire() -> Bool {
    do { try lease.acquire(); return lease.isValid } catch { return false }
  }
  func release() { lease.release() }
}

// MARK: - AVFoundation adapters

@MainActor
private final class IOSCompanionSystemSpeech: NSObject, IOSCompanionSpeechOutput, AVSpeechSynthesizerDelegate {
  var onEvent: ((AVSpeechUtterance, IOSCompanionSpeechEvent) -> Void)?
  private var synthesizer: AVSpeechSynthesizer?

  func voiceIdentifier(language: String) -> String? {
    guard let voice = AVSpeechSynthesisVoice(language: language),
      voice.language.split(separator: "-").first?.lowercased() == language.split(separator: "-").first?.lowercased(),
      AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.identifier == voice.identifier }) else { return nil }
    return voice.identifier
  }
  func utterance(text: String, voice: String, rate: Float, pitch: Float) -> AVSpeechUtterance? {
    guard let chosen = AVSpeechSynthesisVoice(identifier: voice) else { return nil }
    let value = AVSpeechUtterance(string: text)
    value.voice = chosen
    value.rate = rate
    value.pitchMultiplier = pitch
    return value
  }
  func speak(_ utterance: AVSpeechUtterance) {
    if synthesizer == nil {
      let next = AVSpeechSynthesizer()
      next.usesApplicationAudioSession = true
      next.delegate = self
      synthesizer = next
    }
    synthesizer?.speak(utterance)
  }
  func stop() {
    let old = synthesizer
    synthesizer = nil
    old?.delegate = nil
    old?.stopSpeaking(at: .immediate)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    forward(synthesizer, utterance, .start)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    forward(synthesizer, utterance, .done)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    forward(synthesizer, utterance, .cancelled)
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
    forward(synthesizer, utterance, .range(characterRange))
  }
  nonisolated private func forward(_ source: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance,
                                  _ event: IOSCompanionSpeechEvent) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.synthesizer === source else { return }
      self.onEvent?(utterance, event)
    }
  }
}

private final class IOSCompanionSystemClip: NSObject, IOSCompanionClip, AVAudioPlayerDelegate {
  let duration: TimeInterval
  private let player: AVAudioPlayer
  @MainActor var onEnd: ((IOSCompanionClip, IOSCompanionClipEnd) -> Void)?

  init(_ player: AVAudioPlayer) { self.player = player; duration = player.duration; super.init() }
  @MainActor func play() -> Bool {
    player.delegate = self
    // play() implicitly prepares and may activate the shared session. It is
    // deliberately AFTER generation and lease admission, never in the loader.
    // Sharing PiP's lease means zero new explicit setters, not zero framework activation.
    return player.play()
  }
  @MainActor func stop() { onEnd = nil; player.delegate = nil; player.stop() }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    forward(player, flag ? .done : .error)
  }
  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { forward(player, .error) }
  private func forward(_ player: AVAudioPlayer, _ event: IOSCompanionClipEnd) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.player === player else { return }
      self.onEnd?(self, event)
    }
  }
}

// MARK: - One bounded local read, with cooperative cancellation

final class IOSCompanionVoiceCancellation {
  private let lock = NSLock()
  private var cancelled = false
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum IOSCompanionVoiceLoadError: Error, Equatable { case invalidFile, unsupportedAudio, cancelled, busy }

@MainActor
final class IOSCompanionFileLoader: IOSCompanionClipLoading {
  nonisolated static let maxBytes = 16 * 1024 * 1024
  // Process-wide physical admission, not an engine/messenger lifetime flag.
  // Replacing a Flutter engine cannot create another decoder while a cancelled
  // predecessor is still inside an OS read/constructor call.
  private static var physicalLoadPending = false
  private static let sharedWorker = DispatchQueue(label: "dsh.companion-voice.read", qos: .userInitiated)
  private let cachesPath: String?
  private let worker: DispatchQueue

  init(cachesPath: String? = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first,
       worker: DispatchQueue? = nil) {
    self.cachesPath = cachesPath
    self.worker = worker ?? Self.sharedWorker
  }
  func load(id: String, path: String, cancellation: IOSCompanionVoiceCancellation,
            completion: @escaping @MainActor (Result<IOSCompanionClip, Error>) -> Void) {
    guard !Self.physicalLoadPending else { completion(.failure(IOSCompanionVoiceLoadError.busy)); return }
    Self.physicalLoadPending = true
    let cachesPath = self.cachesPath
    worker.async {
      let loaded: Result<IOSCompanionClip, Error> = Result {
        let data = try Self.read(id: id, path: path, cachesPath: cachesPath, cancellation: cancellation)
        guard !cancellation.isCancelled else { throw IOSCompanionVoiceLoadError.cancelled }
        let player: AVAudioPlayer
        do { player = try AVAudioPlayer(data: data) }
        catch { throw IOSCompanionVoiceLoadError.unsupportedAudio }
        guard player.duration.isFinite, player.duration > 0,
          player.duration <= IOSCompanionVoiceEngine.maxClipSeconds
          else { throw IOSCompanionVoiceLoadError.unsupportedAudio }
        guard !cancellation.isCancelled else { throw IOSCompanionVoiceLoadError.cancelled }
        return IOSCompanionSystemClip(player)
      }
      DispatchQueue.main.async {
        Self.physicalLoadPending = false // Only after the physical worker returned.
        completion(loaded)
      }
    }
  }

  /// Internal test seam is the same production read, with a synthetic cache
  /// directory. It never opens the caller's path directly: only the exact leaf
  /// below the canonical cache directory descriptor can be read.
  nonisolated static func read(id: String, path: String, cachesPath: String?,
                               cancellation: IOSCompanionVoiceCancellation) throws -> Data {
    guard !cancellation.isCancelled else { throw IOSCompanionVoiceLoadError.cancelled }
    guard let cachesPath,
      path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
      else { throw IOSCompanionVoiceLoadError.invalidFile }
    let given = URL(fileURLWithPath: path)
    let rootURL = URL(fileURLWithPath: cachesPath, isDirectory: true).standardizedFileURL
    let canonical = rootURL.resolvingSymlinksInPath().path
    let parent = given.deletingLastPathComponent().path
    let kind = given.pathExtension.lowercased()
    let leaf = "companion-voice-\(id).\(kind)"
    guard ["wav", "mp3", "m4a", "flac", "ogg", "bin"].contains(kind),
      given.lastPathComponent == leaf, parent == rootURL.path || parent == canonical,
      IOSCompanionVoiceEngine.identifier(id) == id
      else { throw IOSCompanionVoiceLoadError.invalidFile }
    let directory = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw IOSCompanionVoiceLoadError.invalidFile }
    defer { Darwin.close(directory) }
    let descriptor = leaf.withCString { Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw IOSCompanionVoiceLoadError.invalidFile }
    defer { Darwin.close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= Int64(maxBytes) else { throw IOSCompanionVoiceLoadError.invalidFile }
    var data = Data()
    data.reserveCapacity(Int(before.st_size))
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      guard !cancellation.isCancelled else { throw IOSCompanionVoiceLoadError.cancelled }
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw IOSCompanionVoiceLoadError.invalidFile }
      if count == 0 { break }
      guard data.count <= maxBytes - count else { throw IOSCompanionVoiceLoadError.invalidFile }
      data.append(contentsOf: chunk.prefix(count))
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
      data.count == Int(before.st_size), after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
      after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
      !cancellation.isCancelled else { throw IOSCompanionVoiceLoadError.invalidFile }
    return data
  }
}

/// iOS 10+ continuous monotonic time, including device sleep. No iOS 16-only
/// ContinuousClock and no user-adjustable wall clock on the iOS 15 target.
private enum IOSCompanionVoiceClock {
  private static let secondsPerTick: Double? = {
    var value = mach_timebase_info_data_t(numer: 0, denom: 0)
    guard mach_timebase_info(&value) == KERN_SUCCESS, value.numer > 0, value.denom > 0 else { return nil }
    return Double(value.numer) / Double(value.denom) / 1_000_000_000
  }()
  static func now() -> TimeInterval? {
    guard let factor = secondsPerTick else { return nil }
    return Double(mach_continuous_time()) * factor
  }
}
