import AVFoundation
import Flutter
import Speech
import UIKit

// dsh/voice and its events, after android/.../voice/VoicePlugin.kt: the system's
// recognizer with partial results, and a 16 kHz PCM recorder for the engine's own
// recognizer. Everything but the audio tap runs on the main thread.

private typealias VoiceEmit = ([String: Any]) -> Void

private protocol VoiceSession: AnyObject {
  /// The `VoiceError` code for losing the microphone.
  var audioFailure: Int { get }
  func start() throws
  func finish(_ result: @escaping FlutterResult)
  func discard()
}

final class VoiceChannel: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var session: VoiceSession?
  private var sessionId: Int?

  init(messenger: any FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/voice", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/voice/events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
  }

  deinit {
    // Keep the already-created session alive until main-thread discard. Its
    // microphone's revocation handler remains effective while cleanup waits.
    let old = session
    IOSAudioMainThreadCleanup { old?.discard() }.perform()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    endSession()
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    switch call.method {
    case "capabilities":
      let speech = SFSpeechRecognizer.authorizationStatus()
      let refused = speech == .denied || speech == .restricted
      result([
        "recognizer": !refused && Self.recognizer(nil)?.isAvailable == true,
        "recorder": AVAudioSession.sharedInstance().isInputAvailable,
      ])
    case "permission":
      result(AVAudioSession.sharedInstance().recordPermission == .granted ? "granted" : "denied")
    case "requestPermission": requestPermission(result)
    case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
    case "startRecognizer": startRecognizer(args, result: result)
    case "startRecorder":
      let seconds = min(max(args["maxSeconds"] as? Int ?? 60, 1), 600)
      begin(args, result: result) { RecorderSession(maxSeconds: seconds, emit: $0) }
    case "stop":
      guard let session else { return result(nil) }
      session.finish(result)
    case "cancel":
      endSession()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// The microphone is what's asked for; the recognizer's own question comes with
  /// it, so dictating doesn't stop for a second dialog. Refused, the recorder works
  /// without it and `capabilities` stops offering the recognizer.
  private func requestPermission(_ result: @escaping FlutterResult) {
    let audio = AVAudioSession.sharedInstance()
    switch audio.recordPermission {
    case .granted: askSpeech { result("granted") }
    case .denied: result("blocked")
    default:
      audio.requestRecordPermission { granted in
        onMain {
          if granted {
            self.askSpeech { result("granted") }
          } else {
            result("denied")
          }
        }
      }
    }
  }

  private func askSpeech(then done: @escaping () -> Void) {
    guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return done() }
    SFSpeechRecognizer.requestAuthorization { _ in onMain(done) }
  }

  private func startRecognizer(_ args: [String: Any], result: @escaping FlutterResult) {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      return result(Self.failure("permission", code: 9))
    }
    guard let recognizer = Self.recognizer(args["language"] as? String) else {
      return result(Self.failure("recognizer", code: 12))
    }
    guard recognizer.isAvailable else { return result(Self.failure("recognizer", code: 2)) }
    begin(args, result: result) { RecognizerSession(recognizer: recognizer, emit: $0) }
  }

  private func begin(
    _ args: [String: Any],
    result: @escaping FlutterResult,
    make: (@escaping VoiceEmit) -> VoiceSession
  ) {
    guard let id = args["sessionId"] as? Int else { return result(Self.failure("arguments", code: 5)) }
    endSession()
    guard AVAudioSession.sharedInstance().recordPermission == .granted else {
      return result(Self.failure("permission", code: 9))
    }
    // A valid foreground start entry may retry after reset. Dart's existing
    // system->recorder fallback also calls startRecorder; this ABI has no
    // origin field and cannot prove a new physical tap. Queries and automatic
    // foreground callbacks do not clear reset; invalid input returns above.
    let activeStartEntry = UIApplication.shared.applicationState == .active
      && UIApplication.shared.isProtectedDataAvailable
    if activeStartEntry { IOSAudioSessionCoordinator.shared.retry(userInitiated: true) }
    let next = make { [weak self] event in self?.send(event, from: id) }
    do {
      try next.start()
      session = next
      sessionId = id
      result(nil)
    } catch {
      next.discard()
      result(Self.failure("audio", code: next.audioFailure))
    }
  }

  private func send(_ event: [String: Any], from id: Int) {
    guard id == sessionId else { return }
    var event = event
    event["sessionId"] = id
    sink?(event)
    if event["type"] as? String == "end" {
      session = nil
      sessionId = nil
    }
  }

  private func endSession() {
    session?.discard()
    session = nil
    sessionId = nil
  }

  /// The phone's language, then the others the person reads: `en_CN` and the like
  /// have no recognizer of their own.
  private static func recognizer(_ language: String?) -> SFSpeechRecognizer? {
    if let language { return SFSpeechRecognizer(locale: Locale(identifier: language)) }
    return SFSpeechRecognizer()
      ?? Locale.preferredLanguages.lazy.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.first
  }

  private static func failure(_ code: String, code voiceCode: Int) -> FlutterError {
    FlutterError(code: code, message: nil, details: ["code": voiceCode])
  }
}

// MARK: - The system's recognizer

private final class RecognizerSession: VoiceSession {
  let audioFailure = 3

  private let recognizer: SFSpeechRecognizer
  private let emit: VoiceEmit
  private let microphone = Microphone()
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?
  private var over = false

  init(recognizer: SFSpeechRecognizer, emit: @escaping VoiceEmit) {
    self.recognizer = recognizer
    self.emit = emit
    microphone.onRevoked = { [weak self] in
      guard let self, !self.over else { return }
      self.discard()
      self.emit(["type": "error", "code": self.audioFailure])
      self.emit(["type": "end"])
    }
  }

  func start() throws {
    request.shouldReportPartialResults = true
    // On the phone when it can be: what's said stays here.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    try microphone.start { [request = self.request, emit = self.emit] buffer in
      request.append(buffer)
      let level = inputLevel(buffer)
      onMain { emit(["type": "level", "value": level]) }
    }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      onMain { self?.heard(result, error) }
    }
  }

  /// The final text arrives as an event, as it does on Android.
  func finish(_ result: @escaping FlutterResult) {
    microphone.stop()
    request.endAudio()
    result(nil)
  }

  func discard() {
    over = true
    microphone.stop()
    request.endAudio()
    task?.cancel()
    task = nil
  }

  private func heard(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
    guard !over else { return }
    if let result, !result.isFinal {
      return emit(["type": "partial", "text": result.bestTranscription.formattedString])
    }
    discard()
    if let result {
      emit(["type": "final", "text": result.bestTranscription.formattedString])
    } else {
      emit(["type": "error", "code": error.map(Self.code) ?? 7])
    }
    emit(["type": "end"])
  }

  /// `kAFAssistantErrorDomain`'s codes as the `SpeechRecognizer.ERROR_*` ones Dart's
  /// messages are keyed on.
  private static func code(_ error: Error) -> Int {
    switch (error as NSError).code {
    case 1110: return 7  // No speech detected.
    case 1700: return 9  // Not authorized.
    case 203: return 2  // Retry: the service couldn't be reached.
    default: return 5
    }
  }
}

// MARK: - The recorder

private final class RecorderSession: VoiceSession {
  let audioFailure = 100

  private static let sampleRate = 16_000
  private static let bytesPerSample = 2

  private let emit: VoiceEmit
  private let maxBytes: Int
  private let microphone = Microphone()
  private var pcm = Data()
  private var over = false

  init(maxSeconds: Int, emit: @escaping VoiceEmit) {
    maxBytes = maxSeconds * Self.sampleRate * Self.bytesPerSample
    self.emit = emit
    microphone.onRevoked = { [weak self] in
      guard let self, !self.over else { return }
      self.discard()
      self.emit(["type": "error", "code": self.audioFailure])
      self.emit(["type": "end"])
    }
  }

  func start() throws {
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(Self.sampleRate),
        channels: 1,
        interleaved: true
      )
    else { throw NoMicrophone() }
    var converter: AVAudioConverter?
    try microphone.start { [weak self] buffer in
      if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
      guard let active = converter, let chunk = Self.converted(buffer, with: active, to: target) else { return }
      let level = inputLevel(buffer)
      onMain { self?.add(chunk, level: level) }
    }
  }

  func finish(_ result: @escaping FlutterResult) {
    microphone.stop()
    // Queued behind what the tap had already sent here.
    onMain { [self] in
      over = true
      result(pcm.isEmpty ? nil : FlutterStandardTypedData(bytes: Self.wav(pcm)))
      emit(["type": "end"])
    }
  }

  func discard() {
    over = true
    microphone.stop()
    pcm = Data()
  }

  private func add(_ chunk: Data, level: Double) {
    guard !over else { return }
    emit(["type": "level", "value": level])
    guard pcm.count < maxBytes else { return }
    pcm.append(chunk.prefix(maxBytes - pcm.count))
    if pcm.count >= maxBytes { emit(["type": "limit"]) }
  }

  private static func converted(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    to target: AVAudioFormat
  ) -> Data? {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var handed = false
    var failure: NSError?
    let status = converter.convert(to: out, error: &failure) { _, state in
      if handed {
        state.pointee = .noDataNow
        return nil
      }
      handed = true
      state.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
    return Data(bytes: samples, count: Int(out.frameLength) * bytesPerSample)
  }

  /// 16 kHz mono PCM16, what the engine's recognizer reads.
  private static func wav(_ pcm: Data) -> Data {
    var data = Data()
    func tag(_ text: String) { data.append(contentsOf: text.utf8) }
    func put<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    tag("RIFF")
    put(UInt32(36 + pcm.count))
    tag("WAVE")
    tag("fmt ")
    put(UInt32(16))
    put(UInt16(1))
    put(UInt16(1))
    put(UInt32(sampleRate))
    put(UInt32(sampleRate * bytesPerSample))
    put(UInt16(bytesPerSample))
    put(UInt16(bytesPerSample * 8))
    tag("data")
    put(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
}

// MARK: - The microphone

private struct NoMicrophone: Error {}

/// A main-thread recording lease. The coordinator retains the original App
/// baseline; a preempted PiP tuple is never saved here and later resurrected.
private final class Microphone {
  var onRevoked: (() -> Void)?
  private let engine = AVAudioEngine()
  private let audio = IOSAudioSessionLease(role: .recording)
  private var tapInstalled = false
  private var running = false

  init() {
    audio.onRevoked = { [weak self] _ in
      guard let self else { return }
      let wasRunning = self.running
      self.stop()
      if wasRunning { self.onRevoked?() }
    }
  }

  /// [tap] runs on the audio thread.
  func start(tap: @escaping (AVAudioPCMBuffer) -> Void) throws {
    precondition(Thread.isMainThread)
    guard !running, !audio.isHeld else { throw NoMicrophone() }
    do {
      // Kept by the coordinator independently of this object's weak callback.
      // It stops capture before reconfiguration even while deinit is queued.
      audio.setOutputStop { [engine] in engine.stop() }
      try audio.acquire()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      // installTap raises on a format like this, with nothing to catch it.
      guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
      input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in tap(buffer) }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      guard audio.isValid else { throw NoMicrophone() }
      running = true
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    precondition(Thread.isMainThread)
    running = false
    if tapInstalled {
      tapInstalled = false
      engine.inputNode.removeTap(onBus: 0)
    }
    engine.stop()
    audio.release()
  }

  deinit {
    let engine = engine
    let audio = audio
    let installed = tapInstalled
    IOSAudioMainThreadCleanup {
      engine.stop()
      if installed { engine.inputNode.removeTap(onBus: 0) }
      audio.release()
    }.perform()
  }
}

/// 0 (silence) to 1, over the range speech covers at the phone's microphone.
private func inputLevel(_ buffer: AVAudioPCMBuffer) -> Double {
  guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
  let count = Int(buffer.frameLength)
  var sum: Float = 0
  for index in 0..<count { sum += samples[index] * samples[index] }
  let rms = (sum / Float(count)).squareRoot()
  let decibels = 20 * log10(max(rms, 0.000_001))
  return Double(min(max((decibels + 50) / 40, 0), 1))
}

/// Network PCM chunks are byte-framed, not sample-framed. A 16-bit sample may
/// straddle two chunks; dropping either chunk turns speech into stutter.
struct IOSPCMChunkJoiner {
  private var carry: UInt8?
  private(set) var oddChunks = 0

  mutating func append(_ chunk: Data) -> Data {
    var result = Data()
    if let carry { result.append(carry) }
    result.append(chunk)
    carry = nil
    if !result.count.isMultiple(of: 2) {
      carry = result.removeLast()
      oddChunks += 1
    }
    return result
  }
}

// The call UI uses dsh/speech, while dictation uses dsh/voice above. Keep a
// single native input/output graph for calls so the microphone and reply can
// coexist under iOS voice processing. Android's channel owns the same wire ABI.
final class IOSSpeechChannel: NSObject {
  private final class Playback {
    let id: String
    let format: AVAudioFormat
    let levels: Bool
    var pending = 0
    var ending = false
    var started = false
    var joiner = IOSPCMChunkJoiner()
    init(id: String, format: AVAudioFormat, levels: Bool) {
      self.id = id; self.format = format; self.levels = levels
    }
  }

  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let callAudio = IOSAudioSessionLease(role: .call)
  private let mediaAudio = IOSAudioSessionLease(role: .nativeMedia)
  private var playback: Playback?
  private var callActive = false
  private var tapInstalled = false
  private var muted = false
  private var bargeIn = true
  private var externalPlaying = false
  private var quietMilliseconds = 950
  private var silenceMilliseconds = 0
  private var speaking = false
  private var utterance = Data()
  private var oldIdleTimer = false

  /// A bounded, content-free record of where native playback stopped.
  private func trace(_ stage: String) {
    guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let file = directory.appendingPathComponent("dsh-speech.log")
    let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let line = "\(Date().timeIntervalSince1970) \(stage)\n"
    try? (String(previous.suffix(4096)) + line).write(to: file, atomically: true, encoding: .utf8)
  }

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/speech", binaryMessenger: messenger)
    super.init()
    engine.attach(player)
    callAudio.setOutputStop { [engine] in engine.stop() }
    mediaAudio.setOutputStop { [engine] in engine.stop() }
    callAudio.onRevoked = { [weak self] _ in self?.stopCall(error: "audio-interrupted") }
    mediaAudio.onRevoked = { [weak self] _ in self?.stopPlayback(phase: "error") }
    channel.setMethodCallHandler { [weak self] call, reply in self?.handle(call, reply: reply) ?? reply(FlutterMethodNotImplemented) }
    NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  private func event(_ values: [String: Any]) { channel.invokeMethod("event", arguments: values) }

  private func handle(_ call: FlutterMethodCall, reply: FlutterResult) {
    precondition(Thread.isMainThread)
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "callStart": reply(startCall(args))
    case "callStop": stopCall(); reply(nil)
    case "callMute": muted = args["on"] as? Bool == true; reply(nil)
    case "callBargeIn": bargeIn = args["on"] as? Bool != false; reply(nil)
    case "callPlaying": externalPlaying = args["on"] as? Bool == true; reply(nil)
    case "callPause": setPause(args["pause"] as? String); reply(nil)
    case "callSpeaker":
      let requested = args["on"] as? Bool != false
      if callActive { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(requested ? .speaker : .none) }
      let speaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
      reply(callActive ? speaker : requested)
    case "open": reply(open(args))
    case "write": reply(write(args))
    case "waiting":
      reply(playback?.id == args["id"] as? String ? playback!.pending : -1)
    case "end":
      if let playback, playback.id == args["id"] as? String {
        playback.ending = true
        if playback.pending == 0 { stopPlayback(phase: "done") }
        else { startPlaybackIfReady(force: true) }
      }
      reply(nil)
    case "stop": stopPlayback(phase: "stopped"); reply(nil)
    case "duck":
      if playback?.id == args["id"] as? String { player.volume = args["on"] as? Bool == true ? 0.3 : 1 }
      reply(nil)
    default: reply(FlutterMethodNotImplemented)
    }
  }

  private func setPause(_ value: String?) {
    quietMilliseconds = switch value {
    case "quick": 550
    case "patient": 1550
    default: 950
    }
  }

  private func startCall(_ args: [String: Any]) -> String {
    guard AVAudioSession.sharedInstance().recordPermission == .granted else { return "permission" }
    guard UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable else { return "microphone" }
    stopCall()
    stopPlayback(phase: "stopped")
    IOSAudioSessionCoordinator.shared.retry(userInitiated: true)
    do {
      try callAudio.acquire()
      let input = engine.inputNode
      try? input.setVoiceProcessingEnabled(true)
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0,
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
          channels: 1, interleaved: true),
        let converter = AVAudioConverter(from: format, to: target) else { throw NoMicrophone() }
      input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
        guard let pcm = Self.convert(buffer, converter: converter, target: target) else { return }
        let level = inputLevel(buffer)
        DispatchQueue.main.async { [weak self] in self?.heard(pcm, level: level) }
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      guard callAudio.isValid else { throw NoMicrophone() }
      callActive = true
      muted = false; speaking = false; silenceMilliseconds = 0; utterance = Data()
      bargeIn = args["bargeIn"] as? Bool != false
      setPause(args["pause"] as? String)
      oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      return "ok"
    } catch {
      stopCall()
      return "microphone"
    }
  }

  private func stopCall(error: String? = nil) {
    let wasActive = callActive
    callActive = false
    if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    stopPlayback(phase: "stopped")
    engine.stop()
    callAudio.release()
    if wasActive { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
    speaking = false; utterance = Data(); silenceMilliseconds = 0
    if wasActive, let error { event(["type": "callError", "reason": error]) }
  }

  @objc private func enteredBackground() {
    if callActive { stopCall(error: "background") }
  }

  private func heard(_ pcm: Data, level: Double) {
    guard callActive, !muted else { return }
    event(["type": "micLevel", "value": level])
    let milliseconds = pcm.count * 1_000 / (16_000 * 2)
    let voiced = level > (playback != nil || externalPlaying ? 0.34 : 0.13)
    if voiced {
      if !speaking {
        speaking = true
        event(["type": "speechStart", "over": playback != nil || externalPlaying])
        if bargeIn && playback != nil { stopPlayback(phase: "stopped") }
      }
      silenceMilliseconds = 0
    } else if speaking { silenceMilliseconds += milliseconds }
    guard speaking else { return }
    if utterance.count < 16_000 * 2 * 30 { utterance.append(pcm) }
    if silenceMilliseconds >= quietMilliseconds || utterance.count >= 16_000 * 2 * 30 {
      let duration = utterance.count * 1_000 / (16_000 * 2)
      if duration >= 250 { event(["type": "utterance", "wav": Self.wav(utterance), "ms": duration]) }
      utterance = Data(); speaking = false; silenceMilliseconds = 0
    }
  }

  private func open(_ args: [String: Any]) -> Bool {
    trace("play-open-requested")
    guard let id = args["id"] as? String, !id.isEmpty,
      let rate = args["rate"] as? Int, (8_000...48_000).contains(rate),
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
        channels: 1, interleaved: true) else { trace("play-open-invalid"); return false }
    let forCall = args["call"] as? Bool == true
    guard !forCall || callActive else { trace("play-open-no-call"); return false }
    stopPlayback(phase: "stopped")
    do {
      if !callActive {
        // A read-aloud tap is a fresh foreground action after a previous call
        // or route interruption; it may explicitly clear coordinator recovery.
        if UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable {
          IOSAudioSessionCoordinator.shared.retry(userInitiated: true)
        }
        try mediaAudio.acquire()
      }
      trace("play-open-lease")
      engine.connect(player, to: engine.mainMixerNode, format: format)
      if !engine.isRunning { try engine.start() }
      trace("play-open-engine")
      guard callActive ? callAudio.isValid : mediaAudio.isValid else { throw NoMicrophone() }
      playback = Playback(id: id, format: format, levels: args["levels"] as? Bool == true)
      player.volume = 1
      event(["type": "play", "id": id, "what": "start"])
      trace("play-open-ok")
      return true
    } catch {
      trace("play-open-failed-\((error as NSError).code)")
      stopPlayback(phase: "error")
      return false
    }
  }

  private func write(_ args: [String: Any]) -> Int {
    guard let playback, playback.id == args["id"] as? String,
      !playback.ending, let bytes = args["bytes"] as? FlutterStandardTypedData,
      bytes.data.count <= 256 * 1024, playback.pending < 2 * 1024 * 1024 else { return -1 }
    let data = playback.joiner.append(bytes.data)
    guard !data.isEmpty else { return playback.pending }
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: playback.format,
        frameCapacity: AVAudioFrameCount(data.count / 2)),
      let samples = buffer.int16ChannelData?[0] else { return -1 }
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: data.count))
    buffer.frameLength = AVAudioFrameCount(data.count / 2)
    playback.pending += data.count
    let id = playback.id
    let count = data.count
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak playback] _ in
      DispatchQueue.main.async {
        guard let self, let playback, self.playback === playback, playback.id == id else { return }
        playback.pending = max(0, playback.pending - count)
        if playback.ending && playback.pending == 0 { self.stopPlayback(phase: "done") }
        else if playback.pending == 0 {
          self.player.pause()
          playback.started = false
          self.trace("play-underrun")
        }
      }
    }
    startPlaybackIfReady()
    return playback.pending
  }

  private func startPlaybackIfReady(force: Bool = false) {
    guard let playback, !playback.started else { return }
    // Network TTS arrives in small PCM chunks. Starting with the first one
    // makes every network pause audible; keep a short queue before resuming.
    let ready = playback.format.sampleRate * 2 * 0.35
    guard force || Double(playback.pending) >= ready else { return }
    playback.started = true
    player.play()
    trace("play-resumed")
  }

  private func stopPlayback(phase: String) {
    guard let playback else { return }
    self.playback = nil
    player.stop()
    trace("play-odd-chunks-\(playback.joiner.oddChunks)")
    event(["type": "play", "id": playback.id, "what": phase])
    if !callActive { engine.stop(); mediaAudio.release() }
  }

  private static func convert(_ input: AVAudioPCMBuffer, converter: AVAudioConverter,
                              target: AVAudioFormat) -> Data? {
    let frames = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return nil }
    var delivered = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, state in
      guard !delivered else { state.pointee = .noDataNow; return nil }
      delivered = true; state.pointee = .haveData; return input
    }
    guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
    return Data(bytes: samples, count: Int(output.frameLength) * 2)
  }

  private static func wav(_ pcm: Data) -> Data {
    var data = Data()
    func tag(_ text: String) { data.append(contentsOf: text.utf8) }
    func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    tag("RIFF"); put(UInt32(36 + pcm.count)); tag("WAVEfmt ")
    put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(16_000))
    put(UInt32(32_000)); put(UInt16(2)); put(UInt16(16))
    tag("data"); put(UInt32(pcm.count)); data.append(pcm)
    return data
  }
}
