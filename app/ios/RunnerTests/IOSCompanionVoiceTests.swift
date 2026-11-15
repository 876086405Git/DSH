import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import Runner

private final class CompanionTestAudioBackend: IOSAudioSessionBackend {
  enum Failure: Error { case synthetic }
  var configuration = IOSAudioSessionConfiguration(category: .ambient, mode: .default, options: [])
  var configurations: [IOSAudioSessionConfiguration] = []
  var activations: [Bool] = []
  var failConfigure = false, failActivation = false
  var onConfigure: ((IOSAudioSessionConfiguration) -> Void)?
  var onDeactivate: (() -> Void)?
  func configure(_ value: IOSAudioSessionConfiguration) throws {
    precondition(Thread.isMainThread)
    configurations.append(value)
    if failConfigure { throw Failure.synthetic }
    configuration = value
    onConfigure?(value)
  }
  func activate(_ value: Bool) throws {
    precondition(Thread.isMainThread)
    activations.append(value)
    if value && failActivation { throw Failure.synthetic }
    if !value { onDeactivate?() }
  }
}

/// The production engine and audio lease, with recording output/session
/// adapters. Utterances are real AVSpeechUtterance objects, never spoken by
/// these adapters. Two loader tests construct a player from synthetic bytes but
/// never call play. These tests cannot establish audible speech, OS activation,
/// microphone-dialog absence, interruption timing, codec coverage or PiP
/// coexistence on a device. Apple execution is a separate acceptance gate.
@MainActor
final class IOSCompanionVoiceTests: XCTestCase {
  private enum Failure: Error { case synthetic }

  @MainActor
  private final class Speech: IOSCompanionSpeechOutput {
    var onEvent: ((AVSpeechUtterance, IOSCompanionSpeechEvent) -> Void)?
    var voices = ["zh-CN": "synthetic-zh", "en-US": "synthetic-en"]
    var selected: [String] = []
    var made: [(voice: String, utterance: AVSpeechUtterance)] = []
    var submitted: [AVSpeechUtterance] = []
    var stops = 0
    var failConstruction = false
    var onSpeak: ((AVSpeechUtterance) -> Void)?
    func voiceIdentifier(language: String) -> String? { selected.append(language); return voices[language] }
    func utterance(text: String, voice: String, rate: Float, pitch: Float) -> AVSpeechUtterance? {
      guard !failConstruction else { return nil }
      let value = AVSpeechUtterance(string: text)
      value.rate = rate; value.pitchMultiplier = pitch
      made.append((voice, value))
      return value
    }
    func speak(_ utterance: AVSpeechUtterance) { submitted.append(utterance); onSpeak?(utterance) }
    func stop() { stops += 1 }
    func send(_ index: Int, _ event: IOSCompanionSpeechEvent) { onEvent?(submitted[index], event) }
  }

  @MainActor
  private final class Clip: IOSCompanionClip {
    nonisolated let duration: TimeInterval
    var onEnd: ((IOSCompanionClip, IOSCompanionClipEnd) -> Void)?
    var result = true
    var inlineEnd: IOSCompanionClipEnd?
    var onPlay: (() -> Void)?
    var plays = 0, stops = 0
    init(duration: TimeInterval = 1) { self.duration = duration }
    func play() -> Bool {
      plays += 1
      onPlay?()
      if let inlineEnd { onEnd?(self, inlineEnd) }
      return result
    }
    func stop() { stops += 1; onEnd = nil }
    func end(_ event: IOSCompanionClipEnd = .done) { onEnd?(self, event) }
  }

  @MainActor
  private final class Loader: IOSCompanionClipLoading {
    struct Request {
      let id: String, path: String
      let cancellation: IOSCompanionVoiceCancellation
      let complete: @MainActor (Result<IOSCompanionClip, Error>) -> Void
    }
    var requests: [Request] = []
    func load(id: String, path: String, cancellation: IOSCompanionVoiceCancellation,
              completion: @escaping @MainActor (Result<IOSCompanionClip, Error>) -> Void) {
      requests.append(Request(id: id, path: path, cancellation: cancellation, complete: completion))
    }
    func finish(_ index: Int, _ clip: Clip) { requests[index].complete(.success(clip)) }
    func fail(_ index: Int) { requests[index].complete(.failure(Failure.synthetic)) }
  }

  @MainActor
  private final class Fixture {
    let speech = Speech(), loader = Loader(), session = CompanionTestAudioBackend()
    let coordinator: IOSAudioSessionCoordinator
    var time: TimeInterval? = 100
    var events: [IOSCompanionVoiceEvent] = []
    var answers: [(String, Bool)] = []
    var order: [String] = []
    var engine: IOSCompanionVoiceEngine!
    var onEvent: ((IOSCompanionVoiceEvent) -> Void)?
    init() {
      coordinator = IOSAudioSessionCoordinator(session: session)
      let audio = IOSCompanionAudioLease(coordinator: coordinator)
      engine = IOSCompanionVoiceEngine(speech: speech, loader: loader, audio: audio, now: { [weak self] in self?.time })
      engine.emit = { [weak self] event in
        guard let self else { return }
        self.events.append(event); self.order.append("\(event.type):\(event.id)")
        self.onEvent?(event)
      }
    }
    func ready() { XCTAssertTrue(engine.ready(language: "zh-CN")) }
    @discardableResult func say(_ id: String, _ text: String = "synthetic 中文", flush: Bool = false) -> Bool {
      var value: Bool?
      engine.speak(["id": id, "text": text, "flush": flush, "pitch": 1.12, "rate": 1.0]) {
        value = $0; self.answers.append((id, $0)); self.order.append("reply:\(id):\($0)")
      }
      XCTAssertNotNil(value)
      return value == true
    }
    func play(_ id: String) {
      engine.play(["id": id, "path": "/synthetic-cache/companion-voice-\(id).wav"]) {
        self.answers.append((id, $0)); self.order.append("reply:\(id):\($0)")
      }
    }
    func terminals(_ id: String) -> [IOSCompanionVoiceEvent] {
      events.filter { $0.id == id && ["done", "stopped", "error"].contains($0.type) }
    }
  }

  func testReadyOnlySelectsAVoiceAndFailureKeepsThePriorSelection() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready()
    XCTAssertFalse(f.engine.ready(language: "zz-ZZ"))
    XCTAssertFalse(f.engine.ready(language: ""))
    XCTAssertFalse(f.engine.ready(language: "zh-CN/other"))
    XCTAssertTrue(f.speech.made.isEmpty)
    XCTAssertTrue(f.speech.submitted.isEmpty)
    XCTAssertTrue(f.loader.requests.isEmpty)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.configurations.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
    XCTAssertTrue(f.say("v1"))
    XCTAssertEqual(f.speech.made.first?.voice, "synthetic-zh")
  }

  func testInvalidArgumentsDoNotFlushAcceptedSpeechOrTouchAudio() {
    let f = Fixture(); defer { f.engine.dispose() }
    XCTAssertFalse(f.say("v0")) // ready has not selected a voice.
    f.ready(); XCTAssertTrue(f.say("v1"))
    let initialStops = f.speech.stops
    let invalid: [[String: Any]] = [
      ["id": "../bad", "text": "text"], ["id": "", "text": "text"],
      ["id": "v1\n", "text": "text"], ["id": "v1.2", "text": "text"],
      ["id": "中文", "text": "text"],
      ["id": String(repeating: "x", count: 129), "text": "text"],
      ["id": "v2", "text": " \n\t"],
      ["id": "v2", "text": String(repeating: "😀", count: 2_049)],
      ["id": "v2", "text": "text", "pitch": true],
      ["id": "v2", "text": "text", "rate": false],
      ["id": "v2", "text": "text", "rate": Double.infinity],
      ["id": "v2", "text": "text", "pitch": Double.nan],
      ["id": "v2", "text": "text", "rate": 0],
      ["id": "v2", "text": "text", "pitch": 2.1],
      ["id": "v2", "text": "text", "flush": NSNumber(value: 1)],
    ]
    for var args in invalid {
      if args["flush"] == nil { args["flush"] = true }
      var result: Bool?
      f.engine.speak(args) { result = $0 }
      XCTAssertEqual(result, false)
    }
    XCTAssertEqual(f.speech.stops, initialStops)
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertEqual(f.session.activations, [true])
  }

  func testEachQueuedUtteranceCapturesVoiceRateAndPitchBeforeSubmission() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("v1", "first"))
    XCTAssertTrue(f.engine.ready(language: "en-US"))
    XCTAssertTrue(f.say("v2", "second"))
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertEqual(f.speech.made.map { $0.voice }, ["synthetic-zh", "synthetic-en"])
    XCTAssertEqual(f.speech.made[1].utterance.rate, AVSpeechUtteranceDefaultSpeechRate)
    XCTAssertEqual(f.speech.made[1].utterance.pitchMultiplier, Float(1.12), accuracy: 0.0001)
    XCTAssertFalse(f.speech.made[0].utterance === f.speech.made[1].utterance)
    f.speech.send(0, .start); f.speech.send(0, .done)
    XCTAssertEqual(f.speech.submitted.map(\.speechString), ["first", "second"])
    f.speech.send(0, .cancelled) // Already completed; cannot terminate v2.
    f.speech.send(1, .start); f.speech.send(1, .done); f.speech.send(1, .done)
    XCTAssertEqual(f.events.map(\.type), ["start", "done", "start", "done"])
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testSpeechQueueHasAnItemAndAggregateTextBudget() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready()
    for index in 0..<32 { XCTAssertTrue(f.say("v\(index)", "x")) }
    XCTAssertFalse(f.say("overflow", "x"))
    f.engine.stop()
    XCTAssertEqual(f.events.filter { $0.type == "stopped" }.count, 32)
    let text = String(repeating: "x", count: 4_096)
    for index in 0..<8 { XCTAssertTrue(f.say("large\(index)", text)) }
    XCTAssertFalse(f.say("largeOverflow", "x"))
    XCTAssertTrue(f.say("replacement", "new", flush: true))
    XCTAssertEqual(f.speech.submitted.last?.speechString, "new")
  }

  func testUTF16RangesAreUnchangedForEmojiAndCombiningMarks() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("v1", "A😀e\u{301}中"))
    XCTAssertEqual(f.speech.submitted[0].speechString.utf16.count, 6)
    XCTAssertEqual(f.speech.submitted[0].speechString.count, 4)
    f.speech.send(0, .range(NSRange(location: 1, length: 2)))
    f.speech.send(0, .start)
    f.speech.send(0, .range(NSRange(location: 3, length: 2)))
    f.speech.send(0, .range(NSRange(location: 5, length: 1)))
    f.speech.send(0, .range(NSRange(location: NSNotFound, length: 1)))
    f.speech.send(0, .range(NSRange(location: Int.max, length: Int.max)))
    f.speech.send(0, .range(NSRange(location: 5, length: 2)))
    f.speech.send(0, .range(NSRange(location: 0, length: 0)))
    XCTAssertEqual(f.events, [
      IOSCompanionVoiceEvent(type: "start", id: "v1"),
      IOSCompanionVoiceEvent(type: "range", id: "v1", start: 1, end: 3),
      IOSCompanionVoiceEvent(type: "range", id: "v1", start: 3, end: 5),
      IOSCompanionVoiceEvent(type: "range", id: "v1", start: 5, end: 6),
    ])
  }

  func testFlushEndsOnlySpeechIncludingUnspokenItemsAndFiltersOldObjects() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("v1")); XCTAssertTrue(f.say("v2"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    XCTAssertTrue(f.say("v3", "replacement", flush: true))
    XCTAssertEqual(f.terminals("v1").map(\.type), ["stopped"])
    XCTAssertEqual(f.terminals("v2").map(\.type), ["stopped"])
    XCTAssertEqual(clip.stops, 0)
    f.speech.send(0, .start); f.speech.send(0, .done); f.speech.send(0, .cancelled)
    XCTAssertTrue(f.terminals("v3").isEmpty)
    XCTAssertEqual(f.speech.submitted.count, 2)
    f.speech.send(1, .done)
    XCTAssertEqual(f.session.activations, [true]) // Clip still owns our shared use.
    clip.end()
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testPlayReplacesOnlyTheClipAndDoesNotCancelTheSpeechQueue() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("v1")); XCTAssertTrue(f.say("v2"))
    f.play("c1"); let first = Clip(); f.loader.finish(0, first)
    let late = first.onEnd
    f.play("c2"); let second = Clip(); f.loader.finish(1, second)
    XCTAssertEqual(f.terminals("c1").map(\.type), ["stopped"])
    XCTAssertTrue(f.terminals("v1").isEmpty)
    XCTAssertTrue(f.terminals("v2").isEmpty)
    XCTAssertEqual(f.speech.submitted.count, 1)
    late?(first, .error)
    XCTAssertTrue(f.terminals("c2").isEmpty)
    second.end()
    XCTAssertEqual(f.session.activations, [true])
    f.speech.send(0, .done); f.speech.send(1, .done)
    XCTAssertEqual(f.session.activations, [true, false])
    XCTAssertEqual(f.terminals("c1").count, 1)
    XCTAssertEqual(f.terminals("c2").map(\.type), ["done"])
  }

  func testStopSettlesBothDomainsExactlyOnceWithoutDependingOnDelegates() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("a")); XCTAssertTrue(f.say("b"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    let late = clip.onEnd
    f.engine.stop(); f.engine.stop()
    f.speech.send(0, .done); f.speech.send(0, .cancelled); late?(clip, .error)
    for id in ["a", "b", "clip"] { XCTAssertEqual(f.terminals(id).map(\.type), ["stopped"]) }
    XCTAssertFalse(f.engine.hasWork)
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testReusingAnIDAfterStopCannotAdoptOldUtteranceOrPlayerCallbacks() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("same")); f.engine.stop()
    XCTAssertTrue(f.say("same", "new"))
    f.speech.send(0, .start); f.speech.send(0, .range(NSRange(location: 0, length: 1)))
    f.speech.send(0, .done); f.speech.send(0, .cancelled)
    XCTAssertEqual(f.terminals("same").count, 1)
    f.speech.send(1, .done)
    f.play("same"); let first = Clip(); f.loader.finish(0, first)
    let late = first.onEnd
    f.engine.stop()
    f.play("same"); let next = Clip(); f.loader.finish(1, next)
    late?(first, .done)
    XCTAssertEqual(f.terminals("same").map(\.type), ["stopped", "done", "stopped"])
    next.end()
    XCTAssertEqual(f.terminals("same").map(\.type), ["stopped", "done", "stopped", "done"])
  }

  func testAnIDCannotBeAcceptedTwiceWhileItStillNamesLiveWork() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("same"))
    XCTAssertFalse(f.say("same", "replacement", flush: true))
    f.play("same")
    XCTAssertTrue(f.loader.requests.isEmpty)
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertTrue(f.events.isEmpty)
  }

  func testPlayReturningFalseHasNoEventsEvenWithAnInlineAndLateError() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); f.play("same")
    let clip = Clip(); clip.result = false; clip.inlineEnd = .error
    var late: ((IOSCompanionClip, IOSCompanionClipEnd) -> Void)?
    clip.onPlay = { late = clip.onEnd }
    f.loader.finish(0, clip)
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.say("same", "Dart fallback"))
    late?(clip, .error); late?(clip, .done)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertEqual(f.speech.submitted.last?.speechString, "Dart fallback")
    f.speech.send(0, .start); f.speech.send(0, .done)
    XCTAssertEqual(f.terminals("same").map(\.type), ["done"])
  }

  func testAcceptedInlineClipCompletionFollowsTrueThenStartThenOneTerminal() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("clip"); let clip = Clip(); clip.inlineEnd = .done
    f.loader.finish(0, clip)
    XCTAssertEqual(f.order, ["reply:clip:true", "start:clip", "done:clip"])
    XCTAssertFalse(f.engine.hasWork)
  }

  func testReadFailureAllowsSameIDFallbackWithoutAClipTerminal() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); f.play("same"); f.loader.fail(0)
    XCTAssertEqual(f.answers.last?.1, false)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
    XCTAssertTrue(f.say("same"))
    f.speech.send(0, .done)
    XCTAssertEqual(f.terminals("same").map(\.type), ["done"])
  }

  func testStopDuringReadResolvesFalseAndLatePreparationCannotStart() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); f.play("same"); f.engine.stop()
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertTrue(f.loader.requests[0].cancellation.isCancelled)
    XCTAssertTrue(f.say("same", "fallback"))
    let old = Clip(); f.loader.finish(0, old)
    XCTAssertEqual(old.plays, 0)
    XCTAssertEqual(old.stops, 1)
    XCTAssertEqual(f.answers.map { $0.1 }, [false, true])
    XCTAssertTrue(f.events.isEmpty)
  }

  func testOnePhysicalLoaderRemainsTheLimitAfterCancellation() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("first"); f.play("second")
    XCTAssertEqual(f.answers.last?.1, false)
    XCTAssertEqual(f.loader.requests.count, 1)
    f.engine.stop(); f.play("third")
    XCTAssertEqual(f.loader.requests.count, 1)
    f.loader.finish(0, Clip())
    f.play("fourth")
    XCTAssertEqual(f.loader.requests.count, 2)
    XCTAssertEqual(f.loader.requests[1].id, "fourth")
  }

  func testReadDeadlineRejectsLateSuccessWithoutAudioOrEvents() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("clip"); f.time = 105; f.engine.poll()
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertTrue(f.loader.requests[0].cancellation.isCancelled)
    let clip = Clip(); f.loader.finish(0, clip)
    XCTAssertEqual(clip.plays, 0)
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
  }

  func testClipDurationLimitsAreCheckedBeforeTheAudioLease() {
    let f = Fixture(); defer { f.engine.dispose() }
    for (index, duration) in [0.0, -1, 55.001, Double.nan, Double.infinity].enumerated() {
      f.play("c\(index)"); let clip = Clip(duration: duration); f.loader.finish(index, clip)
      XCTAssertEqual(f.answers.last?.1, false)
      XCTAssertEqual(clip.plays, 0)
    }
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
  }

  func testSpeechDeadlineEndsItsQueueButLeavesTheIndependentClip() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("a")); XCTAssertTrue(f.say("b"))
    f.time = 399
    f.play("clip"); let clip = Clip(duration: 55); f.loader.finish(0, clip)
    f.time = 400; f.engine.poll()
    XCTAssertEqual(f.terminals("a").first?.code, "timeout")
    XCTAssertEqual(f.terminals("b").first?.code, "timeout")
    XCTAssertTrue(f.terminals("clip").isEmpty)
    XCTAssertEqual(clip.stops, 0)
    XCTAssertEqual(f.session.activations, [true])
    f.speech.send(0, .done)
    clip.end()
    XCTAssertEqual(f.terminals("a").count, 1)
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testForwardUTF16ProgressExtendsSpeechStallDeadlineButRepeatedOrBackwardRangesDoNot() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice", "abcd"))
    f.time = 101; f.speech.send(0, .start) // deadline 401
    f.time = 390; f.speech.send(0, .range(NSRange(location: 0, length: 1))) // deadline 690
    f.time = 450; f.engine.poll() // Cross the old deadline while real progress keeps it live.
    XCTAssertTrue(f.terminals("voice").isEmpty)
    f.time = 680; f.speech.send(0, .range(NSRange(location: 1, length: 1))) // deadline 980
    f.time = 700; f.speech.send(0, .range(NSRange(location: 1, length: 1))) // repeat
    f.time = 970; f.speech.send(0, .range(NSRange(location: 0, length: 1))) // backward
    f.speech.send(0, .start) // duplicate start is not progress either.
    f.time = 980; f.engine.poll()
    XCTAssertEqual(f.terminals("voice").map(\.type), ["error"])
    XCTAssertEqual(f.terminals("voice").first?.code, "timeout")
  }

  func testClipDeadlineWinsOverAnUnobservedLateSuccessfulCompletion() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("clip"); let clip = Clip(duration: 2); f.loader.finish(0, clip)
    let late = clip.onEnd
    f.time = 106
    late?(clip, .done)
    XCTAssertEqual(f.terminals("clip").map(\.type), ["error"])
    XCTAssertEqual(f.terminals("clip").first?.code, "timeout")
  }

  func testRecordingNativeMediaAndUnownedPiPConfigurationsAreNotTakenOver() {
    let values = [
      IOSAudioSessionConfiguration(category: .record, mode: .measurement, options: []),
      IOSAudioSessionConfiguration(category: .playAndRecord, mode: .default, options: []),
      IOSAudioSessionConfiguration(category: .playback, mode: .spokenAudio, options: .duckOthers),
      IOSAudioSessionConfiguration(category: .playback, mode: .moviePlayback, options: .mixWithOthers),
    ]
    for configuration in values {
      let f = Fixture(); defer { f.engine.dispose() }
      f.session.configuration = configuration
      f.ready(); XCTAssertFalse(f.say("voice"))
      f.play("clip")
      XCTAssertEqual(f.answers.last?.1, false)
      XCTAssertTrue(f.loader.requests.isEmpty) // Admission precedes even decoder construction.
      XCTAssertEqual(f.session.configuration, configuration)
      XCTAssertTrue(f.session.configurations.isEmpty)
      XCTAssertTrue(f.session.activations.isEmpty)
      XCTAssertTrue(f.events.isEmpty)
    }
  }

  func testOurOwnCategoryNotificationDoesNotCancelButModeChangeDoes() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice"))
    f.engine.poll()
    XCTAssertTrue(f.terminals("voice").isEmpty)
    f.session.configuration = IOSAudioSessionConfiguration(category: .playback,
      mode: .spokenAudio, options: .duckOthers)
    f.engine.poll()
    XCTAssertEqual(f.terminals("voice").map(\.type), ["stopped"])
    XCTAssertEqual(f.session.activations, [true]) // Never deactivate the newer media owner.
    XCTAssertEqual(f.session.configurations, [.sharedOutput])
    XCTAssertEqual(f.session.configuration.mode, .spokenAudio)
  }

  func testOptionsOnlyTakeoverIsDetectedWithoutDependingOnANotification() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice"))
    f.session.configuration = IOSAudioSessionConfiguration(category: .playback, mode: .default, options: [])
    f.engine.poll()
    XCTAssertEqual(f.terminals("voice").first?.code, "audio-replaced")
    XCTAssertEqual(f.session.activations, [true])
  }

  func testActivationFailureReturnsFalseAndRestoresOnlyOurChangedConfiguration() {
    let f = Fixture(); defer { f.engine.dispose() }
    let prior = f.session.configuration
    f.session.failActivation = true; f.ready()
    XCTAssertFalse(f.say("voice"))
    XCTAssertEqual(f.session.configuration, prior)
    XCTAssertEqual(f.session.configurations, [.sharedOutput, prior])
    XCTAssertEqual(f.session.activations, [true, false])
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.speech.submitted.isEmpty)
  }

  func testConfigurationFailureBeforeChangeDoesNotDeactivateThePriorSession() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.session.failConfigure = true; f.ready()
    XCTAssertFalse(f.say("voice"))
    XCTAssertTrue(f.session.activations.isEmpty)
    XCTAssertEqual(f.session.configuration.category, .ambient)
  }

  func testReleaseRechecksConfigurationAfterDeactivationBeforeRestoring() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice"))
    let replacement = IOSAudioSessionConfiguration(category: .record, mode: .measurement, options: [])
    f.session.onDeactivate = { f.session.configuration = replacement }
    f.engine.stop()
    XCTAssertEqual(f.session.configuration, replacement)
    XCTAssertEqual(f.session.configurations, [.sharedOutput])
  }

  func testTakeoverDuringProvisionalPlayRejectsItAndRetiresPriorSpeech() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice")); f.play("clip")
    let clip = Clip()
    clip.onPlay = {
      f.session.configuration = IOSAudioSessionConfiguration(category: .record, mode: .measurement, options: [])
    }
    f.loader.finish(0, clip)
    XCTAssertEqual(f.answers.last?.1, false)
    XCTAssertTrue(f.events.filter { $0.id == "clip" }.isEmpty)
    XCTAssertEqual(f.terminals("voice").map(\.type), ["stopped"])
    XCTAssertEqual(f.session.activations, [true])
  }

  func testDisposeSettlesPendingAndAcceptedWorkAndAllLateCallbacksStaySilent() {
    let f = Fixture()
    f.ready(); XCTAssertTrue(f.say("voice")); XCTAssertTrue(f.say("queued"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    let late = clip.onEnd
    f.play("pending"); f.engine.dispose()
    let savedEvents = f.events, savedAnswers = f.answers.count
    f.engine.dispose(); f.engine.stop(); f.engine.poll()
    f.speech.send(0, .done); late?(clip, .error)
    let prepared = Clip(); f.loader.finish(1, prepared)
    XCTAssertEqual(prepared.plays, 0)
    XCTAssertEqual(f.events, savedEvents)
    XCTAssertEqual(f.answers.count, savedAnswers)
    for id in ["voice", "queued", "clip"] { XCTAssertEqual(f.terminals(id).map(\.type), ["stopped"]) }
    XCTAssertEqual(f.answers.last?.0, "pending"); XCTAssertEqual(f.answers.last?.1, false)
    XCTAssertFalse(f.engine.ready(language: "zh-CN"))
    XCTAssertFalse(f.say("new")); f.play("newClip")
    XCTAssertEqual(f.loader.requests.count, 2)
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testTerminalCallbackCannotReenterAnAllDomainRetirement() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice"))
    f.onEvent = { event in if event.type == "stopped" { XCTAssertFalse(f.say("reentrant")) } }
    f.engine.stop()
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertFalse(f.engine.hasWork)
  }

  func testPiPJoiningEitherBeforeOrAfterSpeechDoesNotOwnTheOtherMember() throws {
    for pictureFirst in [true, false] {
      let f = Fixture(); defer { f.engine.dispose() }
      let picture = IOSAudioSessionLease(role: .pictureInPicture, coordinator: f.coordinator)
      defer { picture.release() }
      if pictureFirst { try picture.acquire() }
      f.ready(); XCTAssertTrue(f.say("voice")); XCTAssertTrue(f.say("queued"))
      f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
      if !pictureFirst { try picture.acquire() }
      XCTAssertEqual(f.session.configurations, [.sharedOutput])
      XCTAssertEqual(f.session.activations, [true])
      picture.release()
      f.engine.poll()
      XCTAssertEqual(clip.stops, 0)
      XCTAssertTrue(f.events.filter { ["done", "stopped", "error"].contains($0.type) }.isEmpty)
      f.speech.send(0, .done); f.speech.send(1, .done); clip.end()
      XCTAssertEqual(f.session.activations, [true, false])
      for id in ["voice", "queued", "clip"] { XCTAssertEqual(f.terminals(id).map(\.type), ["done"]) }
    }
  }

  func testOrdinarySpeechCompletionDoesNotVersionPiPReadinessOrReleaseItsLease() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    let picture = IOSAudioSessionLease(role: .pictureInPicture, coordinator: f.coordinator)
    try picture.acquire(); defer { picture.release() }
    let generation = f.coordinator.availabilityGeneration
    f.ready()
    for index in 0..<3 {
      XCTAssertTrue(f.say("voice\(index)"))
      f.speech.send(index, .done)
      XCTAssertEqual(f.coordinator.availabilityGeneration, generation)
      XCTAssertTrue(picture.isValid)
      XCTAssertEqual(f.session.activations, [true])
    }
    picture.release()
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testRouteLossRetiresAudibleWorkButKeepsPiPAndSilentVideoMembers() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    let picture = IOSAudioSessionLease(role: .pictureInPicture, coordinator: f.coordinator)
    let silent = IOSAudioSessionLease(role: .silentVideo, coordinator: f.coordinator)
    try picture.acquire(); try silent.acquire()
    defer { picture.release(); silent.release() }
    let availability = f.coordinator.availabilityGeneration
    f.ready(); XCTAssertTrue(f.say("voice")); XCTAssertTrue(f.say("queued"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    let late = clip.onEnd
    f.play("pending")
    f.coordinator.routeLost()
    for id in ["voice", "queued", "clip"] {
      XCTAssertEqual(f.terminals(id), [IOSCompanionVoiceEvent(type: "stopped", id: id, code: "route-lost")])
    }
    XCTAssertEqual(f.answers.last?.0, "pending")
    XCTAssertEqual(f.answers.last?.1, false)
    XCTAssertTrue(f.loader.requests[1].cancellation.isCancelled)
    XCTAssertEqual(clip.stops, 1)
    XCTAssertTrue(picture.isValid && silent.isValid)
    XCTAssertEqual(f.coordinator.availabilityGeneration, availability)
    XCTAssertEqual(f.session.configurations, [.sharedOutput])
    XCTAssertEqual(f.session.activations, [true])
    let events = f.events
    f.speech.send(0, .done); late?(clip, .done)
    let pending = Clip(); f.loader.finish(1, pending)
    XCTAssertEqual(pending.plays, 0)
    XCTAssertEqual(f.events, events)
    picture.release()
    XCTAssertEqual(f.session.activations, [true])
    silent.release()
    XCTAssertEqual(f.session.activations, [true, false])
  }

  func testRecordingPreemptionStopsAcceptedOutputsBeforeItsFirstSetter() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    f.ready(); XCTAssertTrue(f.say("voice")); XCTAssertTrue(f.say("queued"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    let late = clip.onEnd
    let stops = f.speech.stops
    var checkedRecordingSetter = false
    f.session.onConfigure = { value in
      guard value == .recording else { return }
      checkedRecordingSetter = true
      XCTAssertGreaterThan(f.speech.stops, stops)
      XCTAssertEqual(clip.stops, 1)
      for id in ["voice", "queued", "clip"] {
        XCTAssertEqual(f.terminals(id).map(\.code), ["audio-replaced"])
      }
    }
    let recording = IOSAudioSessionLease(role: .recording, coordinator: f.coordinator)
    try recording.acquire(); defer { recording.release() }
    XCTAssertTrue(checkedRecordingSetter)
    let events = f.events
    f.speech.send(0, .done); late?(clip, .error)
    recording.release(); f.engine.poll()
    XCTAssertEqual(f.events, events)
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertEqual(clip.plays, 1)
    f.session.onConfigure = nil
  }

  func testHeldRecordingRejectsNewSpeechAndClipBeforeDecode() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    let recording = IOSAudioSessionLease(role: .recording, coordinator: f.coordinator)
    try recording.acquire(); defer { recording.release() }
    let configurations = f.session.configurations, activations = f.session.activations
    f.ready()
    XCTAssertFalse(f.say("voice"))
    f.play("clip")
    XCTAssertEqual(f.answers.map { $0.1 }, [false, false])
    XCTAssertTrue(f.loader.requests.isEmpty)
    XCTAssertTrue(f.speech.submitted.isEmpty)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertEqual(f.session.configurations, configurations)
    XCTAssertEqual(f.session.activations, activations)
    recording.release()
    XCTAssertTrue(f.say("fresh"))
  }

  func testResetWithoutAnyLeaseRequiresExplicitEntryRecoveryBeforeAutomaticWork() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.coordinator.mediaServicesReset()
    f.ready() // Capability/voice readiness never clears the audio reset gate.
    XCTAssertFalse(f.say("before"))
    f.play("beforeClip")
    f.coordinator.retry(userInitiated: false)
    f.coordinator.interruptionEnded()
    XCTAssertFalse(f.say("afterForeground"))
    XCTAssertTrue(f.loader.requests.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
    XCTAssertEqual(f.coordinator.blocker(for: .companion), .userActionRequired)
    // This models the policy used after valid native Voice/Media entry guards.
    // It is not a Flutter permission-flow or physical-user-tap test.
    f.coordinator.retry(userInitiated: true)
    XCTAssertTrue(f.say("newEntry"))
    XCTAssertEqual(f.speech.submitted.count, 1)
  }

  func testRouteLossInvalidatesPendingDecodeEvenWhenNoAudioMemberExisted() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("old")
    XCTAssertTrue(f.session.activations.isEmpty)
    f.coordinator.routeLost()
    f.engine.poll()
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertTrue(f.loader.requests[0].cancellation.isCancelled)
    let old = Clip(); f.loader.finish(0, old)
    XCTAssertEqual(old.plays, 0)
    XCTAssertEqual(old.stops, 1)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
    f.play("new"); let fresh = Clip(); f.loader.finish(1, fresh)
    XCTAssertEqual(f.answers.map { $0.1 }, [false, true])
    XCTAssertEqual(fresh.plays, 1)
  }

  func testBriefRecordingInvalidatesPendingDecodeBeforeItsCallback() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("old")
    let recording = IOSAudioSessionLease(role: .recording, coordinator: f.coordinator)
    try recording.acquire(); recording.release()
    let activations = f.session.activations
    let old = Clip(); f.loader.finish(0, old) // No engine.poll() was needed.
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertEqual(old.plays, 0)
    XCTAssertEqual(old.stops, 1)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertEqual(f.session.activations, activations)
    f.play("new"); let fresh = Clip(); f.loader.finish(1, fresh)
    XCTAssertEqual(f.answers.map { $0.1 }, [false, true])
  }

  func testInterruptionRetiresBothDomainsAndEndedNeverReplaysOldWork() throws {
    let f = Fixture(); defer { f.engine.dispose() }
    let picture = IOSAudioSessionLease(role: .pictureInPicture, coordinator: f.coordinator)
    try picture.acquire(); defer { picture.release() }
    f.ready(); XCTAssertTrue(f.say("voice")); XCTAssertTrue(f.say("queued"))
    f.play("clip"); let clip = Clip(); f.loader.finish(0, clip)
    let late = clip.onEnd
    f.coordinator.interruptionBegan()
    XCTAssertFalse(picture.isValid)
    for id in ["voice", "queued", "clip"] {
      XCTAssertEqual(f.terminals(id), [IOSCompanionVoiceEvent(type: "stopped", id: id, code: "interrupted")])
    }
    XCTAssertFalse(f.say("during"))
    f.coordinator.interruptionEnded(); f.engine.poll()
    let events = f.events
    f.speech.send(0, .done); late?(clip, .done)
    XCTAssertEqual(f.events, events)
    XCTAssertEqual(f.speech.submitted.count, 1)
    XCTAssertEqual(clip.plays, 1)
    XCTAssertTrue(f.say("new"))
  }

  func testResetPendingDecodeCannotReviveAfterAnExplicitRecoveryEntry() {
    let f = Fixture(); defer { f.engine.dispose() }
    f.play("old")
    f.coordinator.mediaServicesReset()
    f.coordinator.retry(userInitiated: true)
    let old = Clip(); f.loader.finish(0, old)
    XCTAssertEqual(f.answers.map { $0.1 }, [false])
    XCTAssertEqual(old.plays, 0)
    XCTAssertTrue(f.events.isEmpty)
    XCTAssertTrue(f.session.activations.isEmpty)
    f.play("new"); let fresh = Clip(); f.loader.finish(1, fresh)
    XCTAssertEqual(f.answers.map { $0.1 }, [false, true])
    XCTAssertEqual(fresh.plays, 1)
  }

  private func cache() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-companion-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
  }
  private func read(_ file: URL, root: URL, id: String = "v1",
                    cancellation: IOSCompanionVoiceCancellation = IOSCompanionVoiceCancellation()) throws -> Data {
    try IOSCompanionFileLoader.read(id: id, path: file.path, cachesPath: root.path, cancellation: cancellation)
  }

  func testProductionReadUsesTheExactLocalLeafAndDoesNotChangeOrDeleteIt() throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.bin")
    let data = Data([0, 1, 2, 128, 255])
    try data.write(to: file)
    XCTAssertEqual(try read(file, root: root), data)
    XCTAssertEqual(try Data(contentsOf: file), data)
    XCTAssertThrowsError(try read(file, root: root, id: "v2"))
    XCTAssertThrowsError(try read(file, root: root, id: "../v1"))
    XCTAssertThrowsError(try IOSCompanionFileLoader.read(id: "v1", path: "https://example.invalid/audio.wav",
      cachesPath: root.path, cancellation: IOSCompanionVoiceCancellation()))
    XCTAssertThrowsError(try read(root.appendingPathComponent("../companion-voice-v1.bin"), root: root))
  }

  func testProductionReadRejectsEmptyOverLimitDirectoriesAndFinalSymlinks() throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.wav")
    try Data().write(to: file)
    XCTAssertThrowsError(try read(file, root: root))
    let descriptor = Darwin.open(file.path, O_WRONLY | O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    guard descriptor >= 0 else { return }
    XCTAssertEqual(ftruncate(descriptor, off_t(IOSCompanionFileLoader.maxBytes + 1)), 0)
    Darwin.close(descriptor)
    XCTAssertThrowsError(try read(file, root: root))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try read(file, root: root))
    try FileManager.default.removeItem(at: file)
    let target = root.appendingPathComponent("synthetic-other.wav")
    try Data([1, 2, 3]).write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    XCTAssertThrowsError(try read(file, root: root))
    XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
  }

  func testCancelledProductionReadReturnsWithoutChangingTheOriginal() throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.bin")
    try Data([4, 5, 6]).write(to: file)
    let cancellation = IOSCompanionVoiceCancellation(); cancellation.cancel()
    XCTAssertThrowsError(try read(file, root: root, cancellation: cancellation))
    XCTAssertEqual(try Data(contentsOf: file), Data([4, 5, 6]))
  }

  func testProductionLoaderRejectsSyntheticInvalidAudioAndCompletesOnMainActor() async throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.bin")
    let bytes = Data("synthetic non-audio; no user file".utf8)
    try bytes.write(to: file)
    let loader = IOSCompanionFileLoader(cachesPath: root.path)
    let done = expectation(description: "bounded invalid-audio load")
    loader.load(id: "v1", path: file.path, cancellation: IOSCompanionVoiceCancellation()) { result in
      XCTAssertTrue(Thread.isMainThread)
      if case .success(let clip) = result { clip.stop(); XCTFail("invalid bytes should not produce a player") }
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 10)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testProductionPhysicalLoadSlotSurvivesCancellationAndANewLoaderInstance() async throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.bin")
    try Data("synthetic invalid audio".utf8).write(to: file)
    let queue = DispatchQueue(label: "dsh.companion-test.controlled-read")
    queue.suspend()
    var resumed = false
    defer { if !resumed { queue.resume() } }
    let old = IOSCompanionFileLoader(cachesPath: root.path, worker: queue)
    let replacement = IOSCompanionFileLoader(cachesPath: root.path)
    let cancel = IOSCompanionVoiceCancellation()
    let returned = expectation(description: "old physical operation actually returned")
    old.load(id: "v1", path: file.path, cancellation: cancel) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(error as? IOSCompanionVoiceLoadError, .cancelled)
      } else { XCTFail("cancelled synthetic read must fail") }
      returned.fulfill()
    }
    cancel.cancel() // Logical cancellation does not release the physical slot.
    var busyAnswers = 0
    replacement.load(id: "v1", path: file.path, cancellation: IOSCompanionVoiceCancellation()) { result in
      busyAnswers += 1
      if case .failure(let error) = result {
        XCTAssertEqual(error as? IOSCompanionVoiceLoadError, .busy)
      } else { XCTFail("another instance must not dispatch a decoder") }
    }
    XCTAssertEqual(busyAnswers, 1)
    resumed = true; queue.resume()
    await fulfillment(of: [returned], timeout: 10)
    let reused = expectation(description: "slot available after actual worker return")
    replacement.load(id: "v1", path: file.path, cancellation: IOSCompanionVoiceCancellation()) { result in
      if case .failure(let error) = result {
        XCTAssertEqual(error as? IOSCompanionVoiceLoadError, .unsupportedAudio)
      } else { XCTFail("invalid audio remains invalid") }
      reused.fulfill()
    }
    await fulfillment(of: [reused], timeout: 10)
  }

  func testProductionLoaderConstructsSyntheticPCMWithoutPlayingIt() async throws {
    let root = try cache(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("companion-voice-v1.wav")
    // 50 ms of silent 16 kHz mono PCM16, generated here, never played.
    let samples = 800, count = samples * 2
    var bytes = Data()
    func tag(_ value: String) { bytes.append(contentsOf: value.utf8) }
    func number<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }
    tag("RIFF"); number(UInt32(36 + count)); tag("WAVE"); tag("fmt "); number(UInt32(16))
    number(UInt16(1)); number(UInt16(1)); number(UInt32(16_000)); number(UInt32(32_000))
    number(UInt16(2)); number(UInt16(16)); tag("data"); number(UInt32(count))
    bytes.append(Data(repeating: 0, count: count))
    try bytes.write(to: file)
    let loader = IOSCompanionFileLoader(cachesPath: root.path)
    let done = expectation(description: "synthetic PCM metadata load only")
    loader.load(id: "v1", path: file.path, cancellation: IOSCompanionVoiceCancellation()) { result in
      XCTAssertTrue(Thread.isMainThread)
      switch result {
      case .success(let clip):
        XCTAssertEqual(clip.duration, 0.05, accuracy: 0.001)
        clip.stop()
      case .failure: XCTFail("generated PCM should initialize; no playback was requested")
      }
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 10)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }
}
