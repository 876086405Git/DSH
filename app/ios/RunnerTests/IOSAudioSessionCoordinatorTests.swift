import AVFoundation
import Foundation
import Flutter
import UIKit
import XCTest
@testable import Runner

private final class AudioCoordinatorRecordingBackend: IOSAudioSessionBackend {
  enum Failure: Error { case synthetic }
  enum Timing: Equatable { case beforeChange, afterChange }
  var configuration = IOSAudioSessionConfiguration(category: .soloAmbient, mode: .default, options: [])
  var configurations: [IOSAudioSessionConfiguration] = []
  var activations: [Bool] = []
  var steps: [String] = []
  var failNextConfiguration: Timing?
  var failNextActivation: Bool?
  var onConfigure: ((IOSAudioSessionConfiguration) -> Void)?
  var onActivate: ((Bool) -> Void)?
  func configure(_ value: IOSAudioSessionConfiguration) throws {
    steps.append("configure")
    configurations.append(value)
    let failure = failNextConfiguration
    failNextConfiguration = nil
    if failure == .beforeChange { throw Failure.synthetic }
    configuration = value
    onConfigure?(value)
    if failure == .afterChange { throw Failure.synthetic }
  }
  func activate(_ value: Bool) throws {
    steps.append(value ? "activate:true" : "activate:false")
    activations.append(value)
    onActivate?(value)
    if failNextActivation == value {
      failNextActivation = nil
      throw Failure.synthetic
    }
  }
}

/// One-owner transfer for teardown tests. No AV object, microphone, player or
/// production event callback runs on this background queue.
private final class AudioTestTransfer<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?
  init(_ value: Value) { self.value = value }
  func discard() {
    lock.lock()
    let old = value
    value = nil
    lock.unlock()
    withExtendedLifetime(old) {}
  }
}

private enum AudioTestBackgroundFailure: Error { case timedOut }

/// async guarantees queued work; sync may execute on the submitting thread.
/// Main deliberately does not drain while the background owner is destroyed,
/// leaving the production main cleanup pending for the following preemption.
private func audioTestOnBackgroundWhileMainWaits(_ work: @escaping @Sendable () -> Void,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) throws {
  precondition(Thread.isMainThread)
  let finished = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    XCTAssertFalse(Thread.isMainThread, file: file, line: line)
    work()
    finished.signal()
  }
  guard finished.wait(timeout: .now() + 2) == .success else {
    XCTFail("Synthetic background cleanup did not finish within 2 seconds", file: file, line: line)
    throw AudioTestBackgroundFailure.timedOut
  }
}

/// Implements Flutter's binary transport only; production channel dispatch and
/// codec still run. Replacing/clearing handlers models engine teardown.
private final class AudioTestMessenger: NSObject, FlutterBinaryMessenger {
  private var next: Int64 = 0
  private var handlers: [String: (Int64, FlutterBinaryMessageHandler)] = [:]
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    next += 1
    if let handler { handlers[channel] = (next, handler) } else { handlers.removeValue(forKey: channel) }
    return next
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    handlers = handlers.filter { $0.value.0 != connection }
  }
  func retire() { handlers.removeAll() }
  func invoke(_ method: String, arguments: [String: Any], reply: @escaping (Any?) -> Void) {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let data = codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))
    guard let handler = handlers["dsh/native-media"]?.1 else { reply(FlutterMethodNotImplemented); return }
    handler(data) { data in
      guard let data else { reply(FlutterMethodNotImplemented); return }
      reply(codec.decodeEnvelope(data))
    }
  }
}

private final class AudioTestCaption: IOSNativeMediaCaption {
  var hides = 0, shows = 0
  var top: CGFloat?
  func setTop(_ value: CGFloat) { top = value }
  func show(_ value: String) -> Bool { shows += 1; return true }
  func update(_ value: String) -> Bool { true }
  func hide() { XCTAssertTrue(Thread.isMainThread); hides += 1 }
}

/// Production coordinator/lease/recovery state, recording setters only.
/// No AVAudioSession, player, speech, microphone or UIKit object is activated.
/// A valid token here is local admission evidence, not OS active/audible proof.
/// Apple SDK compilation and all execution are UNRUN in the author environment.
@MainActor
final class IOSAudioSessionCoordinatorTests: XCTestCase {
  private func lease(_ role: IOSAudioSessionRole, _ coordinator: IOSAudioSessionCoordinator) -> IOSAudioSessionLease {
    IOSAudioSessionLease(role: role, coordinator: coordinator)
  }

  func testCallTakesOnePlayAndRecordLeaseAndReleasesIt() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let call = lease(.call, coordinator)
    try call.acquire()
    XCTAssertEqual(backend.configuration, .call)
    XCTAssertTrue(call.isValid)
    call.release()
    XCTAssertFalse(call.isHeld)
    XCTAssertEqual(backend.activations, [true, false])
  }

  func testConstructionAndReadinessDoNotActivateOrAdoptAnUnownedTuple() throws {
    let backend = AudioCoordinatorRecordingBackend()
    backend.configuration = .sharedOutput
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let voice = lease(.companion, coordinator)
    XCTAssertNil(coordinator.blocker(for: .companion))
    XCTAssertFalse(voice.isHeld)
    XCTAssertFalse(voice.isValid)
    XCTAssertTrue(backend.configurations.isEmpty)
    XCTAssertTrue(backend.activations.isEmpty)
    try voice.acquire()
    XCTAssertEqual(backend.activations, [true]) // Equal tuple was not borrowed as active.
    XCTAssertTrue(voice.isValid)
    voice.release()
  }

  func testBothOutputAdmissionAndReleaseOrdersKeepOneActivationAndTheRealBaseline() throws {
    for petFirst in [true, false] {
      for firstLeavesFirst in [true, false] {
        let backend = AudioCoordinatorRecordingBackend()
        let baseline = backend.configuration
        let coordinator = IOSAudioSessionCoordinator(session: backend)
        let first = lease(petFirst ? .pictureInPicture : .companion, coordinator)
        let second = lease(petFirst ? .companion : .pictureInPicture, coordinator)
        try first.acquire(); try second.acquire()
        XCTAssertTrue(first.isValid && second.isValid)
        XCTAssertEqual(backend.configurations, [.sharedOutput])
        XCTAssertEqual(backend.activations, [true])
        let leaving = firstLeavesFirst ? first : second
        let staying = firstLeavesFirst ? second : first
        leaving.release(); leaving.release()
        XCTAssertTrue(staying.isValid)
        XCTAssertEqual(backend.activations, [true])
        XCTAssertEqual(backend.configuration, .sharedOutput)
        staying.release()
        XCTAssertEqual(backend.configuration, baseline)
        XCTAssertEqual(backend.configurations, [.sharedOutput, baseline])
        XCTAssertEqual(backend.activations, [true, false])
      }
    }
  }

  func testExclusivePreemptionStopsClientsBeforeConfigurationAndPreservesBaselineAcrossTheChain() throws {
    let backend = AudioCoordinatorRecordingBackend()
    // Includes nontrivial options. The recording backend does not validate
    // platform mode/route support; it verifies exact restoration arguments.
    backend.configuration = IOSAudioSessionConfiguration(category: .playback, mode: .default,
      options: [.duckOthers, .mixWithOthers])
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let pet = lease(.pictureInPicture, coordinator), voice = lease(.companion, coordinator)
    try pet.acquire(); try voice.acquire()
    pet.onRevoked = { [weak pet] _ in backend.steps.append("stop-pet"); pet?.release() }
    voice.onRevoked = { [weak voice] _ in backend.steps.append("stop-voice"); voice?.release() }
    let start = backend.steps.count
    let media = lease(.nativeMedia, coordinator)
    try media.acquire()
    let steps = Array(backend.steps.dropFirst(start))
    XCTAssertEqual(Set(steps.prefix(2)), Set(["stop-pet", "stop-voice"]))
    XCTAssertEqual(Array(steps.dropFirst(2)), ["configure", "activate:true"])
    XCTAssertFalse(pet.isValid || voice.isValid)
    media.onRevoked = { [weak media] _ in backend.steps.append("stop-media"); media?.release() }
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    XCTAssertFalse(media.isValid)
    XCTAssertTrue(mic.isValid)
    XCTAssertEqual(backend.configuration, .recording)
    pet.release(); media.release(); voice.release()
    XCTAssertTrue(mic.isValid)
    XCTAssertFalse(backend.activations.contains(false))
    mic.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, true, true, false])
    pet.onRevoked = nil; voice.onRevoked = nil; media.onRevoked = nil
  }

  func testRecordingRejectsEveryOtherRoleAndItsOldTokenCannotEndANewGeneration() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let old = try coordinator.acquire(.recording) { _, _ in }
    let configurations = backend.configurations, activations = backend.activations
    for role in [IOSAudioSessionRole.companion, .pictureInPicture, .nativeMedia, .silentVideo, .recording] {
      XCTAssertThrowsError(try coordinator.acquire(role) { _, _ in }) {
        XCTAssertEqual($0 as? IOSAudioSessionFailure, .busy)
      }
    }
    XCTAssertEqual(backend.configurations, configurations)
    XCTAssertEqual(backend.activations, activations)
    coordinator.release(old)
    let next = try coordinator.acquire(.companion) { _, _ in }
    let beforeStale = backend.activations
    coordinator.release(old); coordinator.release(old)
    XCTAssertTrue(coordinator.isValid(next))
    XCTAssertEqual(backend.activations, beforeStale)
    coordinator.release(next)
  }

  func testSilentLaunchHasNoExplicitActivationAndUpgradesWithoutLosingTheBaseline() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let launch = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try launch.acquire()
    XCTAssertTrue(launch.isValid)
    XCTAssertEqual(backend.configurations, [.silentVideo])
    XCTAssertTrue(backend.activations.isEmpty)
    try voice.acquire()
    XCTAssertTrue(launch.isValid && voice.isValid)
    XCTAssertEqual(backend.configurations, [.silentVideo, .sharedOutput])
    XCTAssertEqual(backend.activations, [true])
    voice.release()
    XCTAssertTrue(launch.isValid)
    XCTAssertEqual(backend.activations, [true])
    launch.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, false])
  }

  func testLaunchJoiningOutputDoesNotDowngradeAndMediaRevokesBothBeforeTakingTheSession() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let voice = lease(.companion, coordinator), launch = lease(.silentVideo, coordinator)
    try voice.acquire(); try launch.acquire()
    XCTAssertEqual(backend.configurations, [.sharedOutput])
    XCTAssertEqual(backend.activations, [true])
    var ended: Set<String> = []
    voice.onRevoked = { _ in ended.insert("voice") }
    launch.onRevoked = { _ in ended.insert("launch") }
    backend.onConfigure = { config in
      if config == .media { XCTAssertEqual(ended, Set(["voice", "launch"])) }
    }
    let media = lease(.nativeMedia, coordinator)
    try media.acquire()
    XCTAssertFalse(launch.isValid || voice.isValid)
    XCTAssertThrowsError(try launch.acquire())
    XCTAssertTrue(media.isValid)
    media.release()
  }

  func testObservedForeignModeAndOptionsReplacementRevokesWithoutRestoringOverIt() throws {
    for replacement in [IOSAudioSessionConfiguration.media,
      IOSAudioSessionConfiguration(category: .playback, mode: .default, options: [])] {
      let backend = AudioCoordinatorRecordingBackend()
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      let voice = lease(.companion, coordinator)
      try voice.acquire()
      var reasons: [IOSAudioSessionRevocation] = []
      voice.onRevoked = { reasons.append($0) }
      backend.configuration = replacement // An uncoordinated setter, not an OS test.
      XCTAssertFalse(voice.isValid)
      coordinator.poll(); coordinator.poll(); voice.release()
      XCTAssertEqual(reasons, [.replaced])
      XCTAssertEqual(backend.configuration, replacement)
      XCTAssertEqual(backend.configurations, [.sharedOutput])
      XCTAssertEqual(backend.activations, [true])
    }
  }

  func testResetBeforeAnyLeasePersistsThroughForegroundAndEndedUntilUserRecovery() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    coordinator.mediaServicesReset()
    coordinator.retry(userInitiated: false)
    coordinator.interruptionBegan(); coordinator.interruptionEnded(); coordinator.poll()
    for role in [IOSAudioSessionRole.companion, .pictureInPicture, .recording, .nativeMedia, .silentVideo] {
      XCTAssertEqual(coordinator.blocker(for: role), .userActionRequired)
      XCTAssertThrowsError(try coordinator.acquire(role) { _, _ in })
    }
    XCTAssertTrue(backend.configurations.isEmpty)
    XCTAssertTrue(backend.activations.isEmpty)
    coordinator.retry(userInitiated: true) // Synthetic native user choice; no UI assertion.
    XCTAssertTrue(backend.activations.isEmpty) // Clearing the gate does not play anything.
    let token = try coordinator.acquire(.companion) { _, _ in }
    XCTAssertEqual(backend.activations, [true])
    coordinator.release(token)
  }

  func testInterruptionRetiresAllTokensAndRecoveryNeverRestartsOldMembers() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let pet = lease(.pictureInPicture, coordinator), voice = lease(.companion, coordinator)
    try pet.acquire(); try voice.acquire()
    var reasons: [IOSAudioSessionRevocation] = []
    pet.onRevoked = { reasons.append($0) }; voice.onRevoked = { reasons.append($0) }
    coordinator.interruptionBegan()
    XCTAssertEqual(reasons, [.interrupted, .interrupted])
    XCTAssertFalse(pet.isHeld || voice.isHeld)
    XCTAssertEqual(backend.configuration, baseline)
    let activations = backend.activations
    coordinator.interruptionEnded()
    coordinator.retry(userInitiated: false)
    XCTAssertEqual(backend.activations, activations)
    XCTAssertFalse(pet.isValid || voice.isValid)
    try voice.acquire()
    XCTAssertEqual(backend.activations, activations + [true])
    voice.release()
  }

  func testRouteLossEvenWithoutAMemberInvalidatesPendingWorkWithoutSetters() {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let before = coordinator.environmentGeneration
    coordinator.routeLost()
    XCTAssertNotEqual(coordinator.environmentGeneration, before)
    XCTAssertTrue(backend.configurations.isEmpty)
    XCTAssertTrue(backend.activations.isEmpty)
  }

  func testReentrantAcquisitionWhilePreemptingIsRejectedAndOldReleaseCannotChangeTheNewOwner() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    var old: IOSAudioSessionCoordinator.Token?
    old = try coordinator.acquire(.companion) { token, _ in
      coordinator.release(token)
      // A do/catch rather than XCTAssertThrowsError: a `try` in its autoclosure would make this
      // revocation handler a throwing closure, which acquire doesn't take.
      do {
        _ = try coordinator.acquire(.pictureInPicture) { _, _ in }
        XCTFail("acquired while another member was being preempted")
      } catch {
        XCTAssertEqual(error as? IOSAudioSessionFailure, .busy)
      }
    }
    let mic = try coordinator.acquire(.recording) { _, _ in }
    coordinator.release(try XCTUnwrap(old))
    XCTAssertTrue(coordinator.isValid(mic))
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertEqual(backend.activations, [true, true])
    coordinator.release(mic)
  }

  func testResetDuringConfigurationDoesNotActivateOrPublishACandidateToken() {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    backend.onConfigure = { [weak coordinator] config in
      if config == .sharedOutput { coordinator?.mediaServicesReset() }
    }
    let voice = lease(.companion, coordinator)
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(voice.isHeld || voice.isValid)
    XCTAssertTrue(backend.activations.isEmpty)
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(coordinator.blocker(for: .companion), .userActionRequired)
  }

  func testInterruptionDuringActivationRejectsCandidateAndOnlyCleansItsOwnConfiguration() {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    backend.onActivate = { [weak coordinator] value in if value { coordinator?.interruptionBegan() } }
    let voice = lease(.companion, coordinator)
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(voice.isHeld)
    XCTAssertEqual(backend.activations, [true, false])
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(coordinator.blocker(for: .companion), .interrupted)
  }

  func testUncoordinatedReplacementDuringActivationIsNotDeactivatedByCandidateCleanup() {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    backend.onActivate = { [weak backend] value in if value { backend?.configuration = .recording } }
    let voice = lease(.companion, coordinator)
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(voice.isHeld)
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertEqual(backend.activations, [true])
    XCTAssertEqual(backend.configurations, [.sharedOutput])
  }

  func testConfigurationFailureBeforeAndAfterChangeNeverClaimsActivation() {
    for timing in [AudioCoordinatorRecordingBackend.Timing.beforeChange, .afterChange] {
      let backend = AudioCoordinatorRecordingBackend()
      let baseline = backend.configuration
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      backend.failNextConfiguration = timing
      let voice = lease(.companion, coordinator)
      XCTAssertThrowsError(try voice.acquire())
      XCTAssertFalse(voice.isValid)
      XCTAssertTrue(backend.activations.isEmpty)
      XCTAssertEqual(backend.configuration, baseline)
    }
  }

  func testFailedActivationReturnsToBaselineAndDoesNotCreateAnAvailabilityRetryLoop() {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let generation = coordinator.availabilityGeneration
    backend.failNextActivation = true
    let voice = lease(.companion, coordinator)
    XCTAssertThrowsError(try voice.acquire())
    coordinator.poll(); coordinator.poll()
    XCTAssertFalse(voice.isHeld)
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, false])
    XCTAssertEqual(coordinator.availabilityGeneration, generation)
  }

  func testFailedRestoreRetainsRealBaselineInsteadOfAdoptingTheAbandonedRecordingTuple() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    backend.failNextConfiguration = .beforeChange
    mic.release()
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertFalse(mic.isHeld)
    let voice = lease(.companion, coordinator)
    try voice.acquire() // Proven residual ownership, not arbitrary recording takeover.
    XCTAssertTrue(voice.isValid)
    voice.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, false, true, false])
  }

  func testReleaseRechecksOwnershipAfterDeactivationAndNeverRestoresOverAReplacement() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let voice = lease(.companion, coordinator)
    try voice.acquire()
    backend.onActivate = { [weak backend] value in if !value { backend?.configuration = .recording } }
    voice.release()
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertEqual(backend.configurations, [.sharedOutput])
    XCTAssertEqual(backend.activations, [true, false])
  }

  func testShortExclusiveUseStillVersionsAvailabilityEvenWhenFinalConfigurationIsUnchanged() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let before = coordinator.availabilityGeneration
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    let during = coordinator.availabilityGeneration
    mic.release()
    XCTAssertNotEqual(during, before)
    XCTAssertNotEqual(coordinator.availabilityGeneration, during)
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertNil(coordinator.blocker(for: .pictureInPicture))
  }

  func testDroppingALeaseReleasesOnlyItsMembership() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    var pet: IOSAudioSessionLease? = lease(.pictureInPicture, coordinator)
    weak var weakPet = pet
    let voice = lease(.companion, coordinator)
    try pet?.acquire(); try voice.acquire()
    pet = nil
    XCTAssertNil(weakPet)
    XCTAssertTrue(voice.isValid)
    XCTAssertEqual(backend.activations, [true])
    voice.release()
    XCTAssertEqual(backend.configuration, baseline)
  }

  func testRouteLossStopsOnlyAudibleMembersAndLeavesPiPAndSilentVideoInstalled() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let pet = lease(.pictureInPicture, coordinator), voice = lease(.companion, coordinator)
    let silent = lease(.silentVideo, coordinator)
    try pet.acquire(); try voice.acquire(); try silent.acquire()
    var revoked: [String] = []
    pet.onRevoked = { _ in revoked.append("pet") }
    voice.onRevoked = { reason in
      XCTAssertEqual(reason, .routeLost)
      XCTAssertTrue(pet.isValid && silent.isValid) // Also valid during the transition callback.
      revoked.append("voice")
    }
    silent.onRevoked = { _ in revoked.append("silent") }
    let configurations = backend.configurations, activations = backend.activations
    let availability = coordinator.availabilityGeneration
    coordinator.routeLost(); coordinator.routeLost()
    XCTAssertEqual(revoked, ["voice"])
    XCTAssertTrue(pet.isValid && silent.isValid)
    XCTAssertFalse(voice.isHeld)
    XCTAssertEqual(backend.configurations, configurations)
    XCTAssertEqual(backend.activations, activations)
    XCTAssertEqual(coordinator.availabilityGeneration, availability)
    pet.release()
    XCTAssertTrue(silent.isValid)
    XCTAssertEqual(backend.activations, activations)
    silent.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, activations + [false])
  }

  func testRouteLossRestoresOnlyWhenNoQuietMemberRemains() throws {
    for role in [IOSAudioSessionRole.companion, .nativeMedia, .recording] {
      let backend = AudioCoordinatorRecordingBackend()
      let baseline = backend.configuration
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      let output = lease(role, coordinator)
      var stops = 0, notifications = 0
      output.setOutputStop { stops += 1 }
      output.onRevoked = { reason in
        XCTAssertEqual(reason, .routeLost)
        XCTAssertEqual(stops, 1) // Physical stop precedes the logical event.
        notifications += 1
      }
      try output.acquire()
      coordinator.routeLost(); coordinator.routeLost(); output.release()
      XCTAssertEqual(stops, 1)
      XCTAssertEqual(notifications, 1)
      XCTAssertFalse(output.isHeld)
      XCTAssertEqual(backend.configuration, baseline)
      XCTAssertEqual(backend.activations, [true, false])
    }
  }

  func testRouteLossDuringSharedConfigurationPreservesTheExistingSilentToken() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try silent.acquire()
    backend.onConfigure = { value in if value == .sharedOutput { coordinator.routeLost() } }
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(voice.isHeld)
    XCTAssertTrue(silent.isValid)
    XCTAssertTrue(backend.activations.isEmpty)
    XCTAssertEqual(backend.configuration, .sharedOutput)
    backend.onConfigure = nil
    silent.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertTrue(backend.activations.isEmpty)
  }

  func testRouteLossDuringActivationKeepsSilentMembershipUntilItsOwnRelease() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try silent.acquire()
    backend.onActivate = { value in if value { coordinator.routeLost() } }
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertTrue(silent.isValid)
    XCTAssertFalse(voice.isHeld)
    XCTAssertEqual(backend.activations, [true]) // No deactivation over the survivor.
    backend.onActivate = nil
    silent.release()
    XCTAssertEqual(backend.activations, [true, false])
    XCTAssertEqual(backend.configuration, baseline)
  }

  func testRouteLossDuringPiPAdmissionDoesNotCancelTheSilentCandidate() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), pet = lease(.pictureInPicture, coordinator)
    try silent.acquire()
    backend.onConfigure = { value in if value == .sharedOutput { coordinator.routeLost() } }
    backend.onActivate = { value in if value { coordinator.routeLost() } }
    try pet.acquire()
    XCTAssertTrue(silent.isValid && pet.isValid)
    XCTAssertEqual(backend.activations, [true])
    backend.onConfigure = nil; backend.onActivate = nil
    pet.release(); silent.release()
    XCTAssertEqual(backend.activations, [true, false])
  }

  func testReleaseOfLastMemberDuringACancelledTransitionRestoresTheEmptyGroup() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try silent.acquire()
    backend.onConfigure = { value in
      if value == .sharedOutput { silent.release(); coordinator.routeLost() }
    }
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(silent.isHeld || voice.isHeld)
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertNil(coordinator.blocker(for: .pictureInPicture))
    backend.onConfigure = nil
    try voice.acquire()
    XCTAssertTrue(voice.isValid)
    voice.release()
    XCTAssertEqual(backend.configuration, baseline)
  }

  func testReleaseOfLastMemberDuringSuccessfulAdmissionDoesNotDeactivateTheNewMember() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try silent.acquire()
    backend.onConfigure = { value in if value == .sharedOutput { silent.release() } }
    try voice.acquire()
    XCTAssertFalse(silent.isHeld)
    XCTAssertTrue(voice.isValid)
    XCTAssertEqual(backend.activations, [true])
    XCTAssertEqual(backend.configuration, .sharedOutput)
    backend.onConfigure = nil
    voice.release()
    XCTAssertEqual(backend.activations, [true, false])
    XCTAssertEqual(backend.configuration, baseline)
  }

  func testRouteRevocationCallbackCanReleaseTheLastQuietMemberWithoutLeavingAnEmptyGroup() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let pet = lease(.pictureInPicture, coordinator), voice = lease(.companion, coordinator)
    try pet.acquire(); try voice.acquire()
    voice.onRevoked = { _ in pet.release() }
    coordinator.routeLost()
    XCTAssertFalse(pet.isHeld || voice.isHeld)
    XCTAssertEqual(backend.activations, [true, false])
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertNil(coordinator.blocker(for: .pictureInPicture))
  }

  func testResetDuringRouteCancellationKeepsTheUserActionGate() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let silent = lease(.silentVideo, coordinator), voice = lease(.companion, coordinator)
    try silent.acquire()
    backend.onConfigure = { value in
      if value == .sharedOutput { coordinator.mediaServicesReset(); coordinator.routeLost() }
    }
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertFalse(silent.isHeld || voice.isHeld)
    XCTAssertEqual(coordinator.blocker(for: .companion), .userActionRequired)
    XCTAssertTrue(backend.activations.isEmpty)
  }

  func testExplicitNewRecordingAndMediaCanRecoverWithoutAnyPiPLease() throws {
    for role in [IOSAudioSessionRole.recording, .nativeMedia] {
      let backend = AudioCoordinatorRecordingBackend()
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      coordinator.mediaServicesReset()
      coordinator.retry(userInitiated: false)
      XCTAssertThrowsError(try coordinator.acquire(role) { _, _ in })
      XCTAssertTrue(backend.activations.isEmpty)
      coordinator.retry(userInitiated: true) // Models a validated foreground start entry.
      let current = try coordinator.acquire(role) { _, _ in }
      XCTAssertTrue(coordinator.isValid(current))
      XCTAssertEqual(backend.activations, [true])
      coordinator.release(current)
    }
  }

  func testRecordingMayTakeForeignPlaybackButNeverAdoptsItsActivation() throws {
    for mode in [AVAudioSession.Mode.moviePlayback, .spokenAudio] {
      let backend = AudioCoordinatorRecordingBackend()
      let prior = IOSAudioSessionConfiguration(category: .playback, mode: mode, options: .mixWithOthers)
      backend.configuration = prior
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      XCTAssertEqual(coordinator.blocker(for: .companion), .busy)
      XCTAssertEqual(coordinator.blocker(for: .pictureInPicture), .busy)
      XCTAssertNil(coordinator.blocker(for: .recording))
      let mic = lease(.recording, coordinator)
      try mic.acquire()
      XCTAssertEqual(backend.configuration, .recording)
      XCTAssertEqual(backend.activations, [true])
      mic.release()
      XCTAssertEqual(backend.configuration, prior)
      XCTAssertEqual(backend.activations, [true, false])
    }
  }

  func testForeignMicrophoneCategoriesStillBlockEveryNewRole() {
    for category in [AVAudioSession.Category.record, .playAndRecord] {
      let backend = AudioCoordinatorRecordingBackend()
      backend.configuration = IOSAudioSessionConfiguration(category: category, mode: .default, options: [])
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      for role in [IOSAudioSessionRole.recording, .nativeMedia, .companion, .pictureInPicture, .silentVideo] {
        XCTAssertEqual(coordinator.blocker(for: role), .busy)
        XCTAssertThrowsError(try coordinator.acquire(role) { _, _ in })
      }
      XCTAssertTrue(backend.configurations.isEmpty)
      XCTAssertTrue(backend.activations.isEmpty)
    }
  }

  func testFailedDeactivationDoesNotInstallSoloAmbientAndRetainsTheOriginalBaseline() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    backend.failNextActivation = false
    mic.release()
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertEqual(backend.configurations, [.recording])
    XCTAssertEqual(backend.activations, [true, false])
    let voice = lease(.companion, coordinator)
    try voice.acquire()
    XCTAssertTrue(voice.isValid)
    XCTAssertEqual(backend.activations, [true, false, true]) // Residual was not assumed active.
    voice.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, false, true, false])
    XCTAssertEqual(backend.configurations.last, baseline)
  }

  func testFailedDeactivationWithForeignReplacementDoesNotRetainOwnership() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let voice = lease(.companion, coordinator)
    try voice.acquire()
    backend.failNextActivation = false
    backend.onActivate = { value in if !value { backend.configuration = .recording } }
    voice.release()
    XCTAssertEqual(backend.configurations, [.sharedOutput])
    XCTAssertEqual(backend.configuration, .recording)
    XCTAssertEqual(coordinator.blocker(for: .companion), .busy)
  }

  func testSuccessfulDeactivationThenFailedRestoreDoesNotRepeatDeactivationForSilentUse() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let baseline = backend.configuration
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    backend.failNextConfiguration = .beforeChange
    mic.release()
    XCTAssertEqual(backend.configuration, .recording)
    let silent = lease(.silentVideo, coordinator)
    try silent.acquire(); silent.release()
    XCTAssertEqual(backend.configuration, baseline)
    XCTAssertEqual(backend.activations, [true, false])
  }

  func testOrdinarySpeechMembershipDoesNotVersionPiPRecovery() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let empty = coordinator.availabilityGeneration
    for _ in 0..<3 {
      let voice = lease(.companion, coordinator)
      try voice.acquire(); voice.release()
      XCTAssertEqual(coordinator.availabilityGeneration, empty)
    }
    let pet = lease(.pictureInPicture, coordinator)
    try pet.acquire()
    let active = coordinator.availabilityGeneration
    for _ in 0..<3 {
      let voice = lease(.companion, coordinator)
      try voice.acquire(); voice.release()
      XCTAssertEqual(coordinator.availabilityGeneration, active)
      XCTAssertTrue(pet.isValid)
    }
    pet.release()
  }

  func testActualPiPLossVersionsRecoveryEvenWhenTheFinalForeignTupleIsAdoptable() throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let pet = lease(.pictureInPicture, coordinator)
    try pet.acquire()
    let before = coordinator.availabilityGeneration
    var reasons: [IOSAudioSessionRevocation] = []
    pet.onRevoked = { reasons.append($0) }
    backend.configuration = IOSAudioSessionConfiguration(category: .playback, mode: .default, options: [])
    coordinator.poll()
    XCTAssertEqual(reasons, [.replaced])
    XCTAssertNil(coordinator.blocker(for: .pictureInPicture))
    XCTAssertNotEqual(coordinator.availabilityGeneration, before)
    let after = coordinator.availabilityGeneration
    coordinator.poll(); coordinator.poll()
    XCTAssertEqual(coordinator.availabilityGeneration, after)
  }

  func testFailedAcquisitionReleasesItsCapturedOutputStopper() {
    final class Output {}
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let voice = lease(.companion, coordinator)
    var output: Output? = Output()
    weak var weakOutput = output
    voice.setOutputStop { [held = output!] in _ = held }
    output = nil
    backend.failNextActivation = true
    XCTAssertThrowsError(try voice.acquire())
    XCTAssertNil(weakOutput)
    XCTAssertFalse(voice.isHeld)
  }

  func testBackgroundLeaseDestructionStillStopsItsOutputBeforePreemption() async throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    var old: IOSAudioSessionLease? = lease(.companion, coordinator)
    var order: [String] = []
    old?.setOutputStop { XCTAssertTrue(Thread.isMainThread); order.append("stop-old") }
    try old?.acquire()
    weak var weakOld = old
    let transfer = AudioTestTransfer(try XCTUnwrap(old))
    old = nil
    try audioTestOnBackgroundWhileMainWaits { transfer.discard() }
    XCTAssertNil(weakOld)
    backend.onConfigure = { value in if value == .recording { order.append("configure-new") } }
    let mic = lease(.recording, coordinator)
    try mic.acquire()
    XCTAssertEqual(Array(order.prefix(2)), ["stop-old", "configure-new"])
    let drained = expectation(description: "queued cleanup passed")
    DispatchQueue.main.async { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertTrue(mic.isValid) // Old deferred release cannot release this token.
    XCTAssertEqual(backend.activations, [true, true])
    mic.release()
    XCTAssertEqual(backend.activations, [true, true, false])
  }

  func testMainThreadCleanupIsOneShotAcrossQueuedAndImmediateCalls() async throws {
    var calls = 0
    let cleanup = IOSAudioMainThreadCleanup { XCTAssertTrue(Thread.isMainThread); calls += 1 }
    try audioTestOnBackgroundWhileMainWaits { cleanup.perform(); cleanup.perform() }
    cleanup.perform()
    XCTAssertEqual(calls, 1)
    let drained = expectation(description: "duplicate queued cleanup passed")
    DispatchQueue.main.async { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertEqual(calls, 1)
  }

  func testUnusedNativeMediaDestructionNeverCreatesCaptionOrActivatesAudio() async throws {
    for background in [false, true] {
      let backend = AudioCoordinatorRecordingBackend()
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      let messenger = AudioTestMessenger()
      var made = 0
      var channel: NativeMediaChannel? = NativeMediaChannel(messenger: messenger, audioCoordinator: coordinator,
        captionFactory: { _ in made += 1; return AudioTestCaption() })
      weak var weakChannel = channel
      messenger.retire()
      let transfer = AudioTestTransfer(channel)
      channel = nil
      if background { try audioTestOnBackgroundWhileMainWaits { transfer.discard() } }
      else { transfer.discard() }
      XCTAssertNil(weakChannel)
      let drained = expectation(description: "unused channel cleanup passed")
      DispatchQueue.main.async { drained.fulfill() }
      await fulfillment(of: [drained], timeout: 2)
      XCTAssertEqual(made, 0)
      XCTAssertTrue(backend.configurations.isEmpty)
      XCTAssertTrue(backend.activations.isEmpty)
    }
  }

  func testNativeMediaDisposalHidesOnlyItsAlreadyCreatedCaption() async throws {
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let messenger = AudioTestMessenger(), caption = AudioTestCaption()
    var made = 0
    var channel: NativeMediaChannel? = NativeMediaChannel(messenger: messenger, audioCoordinator: coordinator,
      captionFactory: { _ in made += 1; return caption })
    _ = channel?.onListen(withArguments: nil, eventSink: { _ in })
    let owner: [String: Any] = ["owner": "0123456789abcdef", "generation": 1, "lease": "synthetic-only", "top": 120]
    var answered = false
    messenger.invoke("activate", arguments: owner) { value in XCTAssertNil(value); answered = true }
    XCTAssertTrue(answered)
    XCTAssertEqual(made, 1)
    XCTAssertEqual(caption.top, CGFloat(120))
    messenger.retire()
    let transfer = AudioTestTransfer(channel)
    channel = nil
    try audioTestOnBackgroundWhileMainWaits { transfer.discard() }
    let drained = expectation(description: "existing caption cleanup passed")
    DispatchQueue.main.async { drained.fulfill() }
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertEqual(made, 1)
    XCTAssertEqual(caption.hides, 1)
    XCTAssertTrue(backend.activations.isEmpty)
  }

  func testNativeMediaQueriesInvalidPlayAndResumeDoNotClearRecovery() throws {
    try XCTSkipIf(UIApplication.shared.applicationState == .background,
      "This channel-dispatch check needs a non-background Runner test host")
    let backend = AudioCoordinatorRecordingBackend()
    let coordinator = IOSAudioSessionCoordinator(session: backend)
    let messenger = AudioTestMessenger()
    let channel = NativeMediaChannel(messenger: messenger, audioCoordinator: coordinator)
    defer { messenger.retire() }
    _ = channel.onListen(withArguments: nil, eventSink: { _ in })
    let owner: [String: Any] = ["owner": "0123456789abcdef", "generation": 1, "lease": "synthetic-only"]
    var activated = false
    messenger.invoke("activate", arguments: owner) { value in XCTAssertNil(value); activated = true }
    XCTAssertTrue(activated)
    for reset in [false, true] {
      if reset { coordinator.mediaServicesReset() }
      else { coordinator.interruptionBegan() }
      let blocked: IOSAudioSessionFailure = reset ? .userActionRequired : .interrupted
      messenger.invoke("capabilities", arguments: [:]) { value in
        XCTAssertNotNil(value as? [String: Any])
      }
      var invalid = owner
      invalid["privatePath"] = "/not-the-native-media-cache/clip"
      invalid["contentType"] = "audio/wav"
      messenger.invoke("play", arguments: invalid) { value in
        XCTAssertEqual((value as? FlutterError)?.code, "media-invalid")
      }
      messenger.invoke("resume", arguments: owner) { value in
        XCTAssertEqual((value as? FlutterError)?.code, "audio")
      }
      XCTAssertEqual(coordinator.blocker(for: .nativeMedia), blocked)
      XCTAssertTrue(backend.configurations.isEmpty)
      XCTAssertTrue(backend.activations.isEmpty)
    }
  }
}

final class IOSPCMChunkJoinerTests: XCTestCase {
  func testOddNetworkChunksKeepEveryCompleteSampleInOrder() {
    var joiner = IOSPCMChunkJoiner()
    XCTAssertEqual(Array(joiner.append(Data([0x01]))), [])
    XCTAssertEqual(Array(joiner.append(Data([0x02, 0x03]))), [0x01, 0x02])
    XCTAssertEqual(Array(joiner.append(Data([0x04, 0x05, 0x06]))), [0x03, 0x04, 0x05, 0x06])
    XCTAssertEqual(joiner.oddChunks, 2)
  }
}
