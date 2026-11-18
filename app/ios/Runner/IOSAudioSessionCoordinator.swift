import AVFoundation
import Foundation

struct IOSAudioSessionConfiguration: Equatable {
  let category: AVAudioSession.Category
  let mode: AVAudioSession.Mode
  let options: AVAudioSession.CategoryOptions

  // One configuration for both output clients, including a late PiP join.
  // Joining or leaving must not reconfigure/deactivate already accepted speech.
  static let sharedOutput = Self(category: .playback, mode: .default, options: .mixWithOthers)
  static let recording = Self(category: .record, mode: .measurement, options: [])
  static let call = Self(category: .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
  static let media = Self(category: .playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
  static let silentVideo = Self(category: .ambient, mode: .default, options: [])

  fileprivate func satisfies(_ requested: Self) -> Bool {
    category == requested.category && mode == requested.mode && effectiveOptions == requested.effectiveOptions
  }
  private var effectiveOptions: AVAudioSession.CategoryOptions {
    if category == .ambient || options.contains(.duckOthers) || options.contains(.interruptSpokenAudioAndMixWithOthers) {
      return options.union(.mixWithOthers)
    }
    return options
  }
}

/// Implementations and all callers are confined to the main thread. This is
/// the existing Voice/NativeMedia channel execution model, enforced below;
/// this protocol is not an assertion of compiler-enforced actor isolation.
protocol IOSAudioSessionBackend: AnyObject {
  var configuration: IOSAudioSessionConfiguration { get }
  func configure(_ value: IOSAudioSessionConfiguration) throws
  func activate(_ value: Bool) throws
}

enum IOSAudioSessionRole: Equatable {
  case pictureInPicture, companion, recording, call, nativeMedia, silentVideo

  /// Only these roles produce audible output or own microphone input. Losing
  /// an old output route does not itself invalidate silent PiP/video members.
  fileprivate var stopsForRouteLoss: Bool {
    switch self {
    case .companion, .recording, .call, .nativeMedia: return true
    case .pictureInPicture, .silentVideo: return false
    }
  }
  fileprivate var shared: Bool {
    switch self {
    case .pictureInPicture, .companion, .silentVideo: return true
    case .recording, .call, .nativeMedia: return false
    }
  }
  fileprivate var configuration: IOSAudioSessionConfiguration {
    switch self {
    case .pictureInPicture, .companion: return .sharedOutput
    case .recording: return .recording
    case .call: return .call
    case .nativeMedia: return .media
    case .silentVideo: return .silentVideo
    }
  }
}

enum IOSAudioSessionFailure: Error, Equatable {
  case busy, interrupted, userActionRequired, replaced, audio
}

enum IOSAudioSessionRevocation: Equatable {
  case preempted, interrupted, mediaReset, routeLost, replaced

  var companionCode: String {
    switch self {
    case .preempted, .replaced: return "audio-replaced"
    case .interrupted: return "interrupted"
    case .mediaReset: return "media-reset"
    case .routeLost: return "route-lost"
    }
  }
}

/// A local cooperation protocol for every explicit App audio-session setter.
/// Tokens record successful setup and are revoked on observable loss. Neither
/// a token, a matching tuple nor setActive's past success proves OS activity.
/// There is no iOS-15 public synchronous audio-session isActive query.
// Sendable here is a narrow runtime-confinement promise: every entry below
// checks the main thread before touching state, and notifications/timers are
// delivered there. It does not make AVFoundation objects thread-safe or turn
// the legacy Flutter channels into compiler-isolated actors.
final class IOSAudioSessionCoordinator: NSObject, @unchecked Sendable {
  static let shared = IOSAudioSessionCoordinator(session: IOSSystemAudioSessionBackend(), observeSystem: true)
  static let availabilityChanged = Notification.Name("DSHAudioSessionAvailabilityChanged")

  struct Token: Equatable {
    fileprivate let generation: UUID
    fileprivate let member: UUID
  }
  private struct Member {
    let role: IOSAudioSessionRole
    let revoke: (Token, IOSAudioSessionRevocation) -> Void
  }
  private final class Group {
    let generation = UUID()
    let baseline: IOSAudioSessionConfiguration
    var installed: IOSAudioSessionConfiguration?
    var attempted: IOSAudioSessionConfiguration?
    var mayNeedDeactivation = false
    var activated = false
    var members: [UUID: Member] = [:]
    init(baseline: IOSAudioSessionConfiguration) { self.baseline = baseline }
  }
  private final class Transition {
    let acquiring: IOSAudioSessionRole?
    var cancellation: IOSAudioSessionRevocation?
    init(acquiring: IOSAudioSessionRole? = nil) { self.acquiring = acquiring }
  }
  private struct Residual {
    let baseline: IOSAudioSessionConfiguration
    let installed: IOSAudioSessionConfiguration
    let mayNeedDeactivation: Bool
  }
  private struct Availability: Equatable {
    let pictureBlocker: IOSAudioSessionFailure?
    let pictureLoss: UUID
  }

  private let session: IOSAudioSessionBackend
  private let observeSystem: Bool
  private var group: Group?
  private var transition: Transition?
  // A failed restore does not turn our old configuration into a new baseline.
  // It can be reused only while the exact last-owned tuple is still present.
  private var residual: Residual?
  private var recovery = PetOverlayAudioRecoveryState()
  private var observers: [NSObjectProtocol] = []
  private var timer: Timer?
  private var changePending = false
  private var environment = UUID()
  private var availability = UUID()
  private var pictureLoss = UUID()
  private var lastAvailability: Availability?

  /// Captured by work that has not acquired a lease yet (a bounded decoder).
  /// An interruption, reset, lost route or exclusive start retires that work
  /// even if the session is available again before its callback is delivered.
  var environmentGeneration: UUID {
    precondition(Thread.isMainThread)
    return environment
  }
  var availabilityGeneration: UUID {
    precondition(Thread.isMainThread)
    return availability
  }

  init(session: IOSAudioSessionBackend, observeSystem: Bool = false) {
    precondition(Thread.isMainThread)
    self.session = session
    self.observeSystem = observeSystem
    super.init()
    lastAvailability = availabilitySnapshot()
    if observeSystem { installObservers() }
  }

  /// Readiness for a new attempt, not proof that setActive will succeed.
  func blocker(for role: IOSAudioSessionRole) -> IOSAudioSessionFailure? {
    precondition(Thread.isMainThread)
    if recovery.requiresUserAction { return .userActionRequired }
    if recovery.interrupted { return .interrupted }
    if transition != nil { return .busy }
    if let group {
      guard group.installed == session.configuration else { return .replaced }
      let roles = group.members.values.map(\.role)
      if role.shared && roles.allSatisfy(\.shared) { return nil }
      if role == .recording && !roles.contains(.recording) { return nil }
      if role == .nativeMedia && roles.allSatisfy(\.shared) { return nil }
      return .busy
    }
    if let residual, residual.installed == session.configuration { return nil }
    let config = session.configuration
    if config.category == .record || config.category == .playAndRecord {
      return .busy // Do not take over an uncoordinated microphone owner.
    }
    if role != .recording, config.category == .playback,
      config.mode == .spokenAudio || config.mode == .moviePlayback {
      return .busy
    }
    // A new explicit recording may take over foreign playback/movie/spoken
    // configuration. It still acquires its own activation and saves the real
    // predecessor tuple; a matching foreign tuple is never an active lease.
    return nil
  }

  func isValid(_ token: Token) -> Bool {
    precondition(Thread.isMainThread)
    // A transition blocks new acquisitions, not a surviving member's use of
    // the still-owned tuple. In particular, route-loss callbacks must not make
    // PiP appear briefly invalid while only companion speech is being retired.
    guard recovery.blocker == nil, let group,
      token.generation == group.generation, let member = group.members[token.member],
      group.installed == session.configuration else { return false }
    return member.role == .silentVideo || group.activated
  }

  func acquire(_ role: IOSAudioSessionRole,
               onRevoked: @escaping (Token, IOSAudioSessionRevocation) -> Void) throws -> Token {
    precondition(Thread.isMainThread)
    poll()
    if let blocker = blocker(for: role) { throw blocker }
    let work = Transition(acquiring: role)
    transition = work
    defer { finishTransition(work) }
    if !role.shared { environment = UUID() }

    let next: Group
    if let current = group, role.shared && current.members.values.allSatisfy({ $0.role.shared }) {
      next = current
    } else {
      let old = group
      let current = session.configuration
      let retained = residual.flatMap { $0.installed == current ? $0 : nil }
      next = Group(baseline: old?.baseline ?? retained?.baseline ?? current)
      next.installed = old?.installed ?? retained?.installed
      next.mayNeedDeactivation = old?.mayNeedDeactivation ?? retained?.mayNeedDeactivation ?? false
      group = next
      residual = nil
      if let old { revokeMembers(old, reason: .preempted) }
    }
    do {
      guard work.cancellation == nil, recovery.blocker == nil else { throw IOSAudioSessionFailure.interrupted }
      let needsActivation = role != .silentVideo
      // A muted launch video joins an existing output without downgrading it.
      let requested: IOSAudioSessionConfiguration
      if next.activated {
        guard let installed = next.installed else { throw IOSAudioSessionFailure.replaced }
        requested = installed
      } else { requested = role.configuration }
      if !session.configuration.satisfies(requested) {
        next.attempted = requested
        try session.configure(requested)
      }
      guard work.cancellation == nil, recovery.blocker == nil,
        session.configuration.satisfies(requested) else { throw IOSAudioSessionFailure.replaced }
      next.installed = session.configuration
      next.attempted = nil
      if needsActivation && !next.activated {
        next.mayNeedDeactivation = true
        try session.activate(true)
        guard work.cancellation == nil, recovery.blocker == nil,
          session.configuration.satisfies(requested) else { throw IOSAudioSessionFailure.replaced }
        next.installed = session.configuration
        next.activated = true
      }
      let member = UUID()
      next.members[member] = Member(role: role, revoke: onRevoked)
      return Token(generation: next.generation, member: member)
    } catch {
      // Route loss can arrive synchronously during configure/activate. It has
      // already removed only audible members. Preserve surviving PiP/silent
      // members if their owned configuration remains usable; do not route the
      // cancelled new sound request through an all-member failure cleanup.
      if !retainSurvivors(next) {
        if group === next { group = nil }
        let reason: IOSAudioSessionRevocation
        if work.cancellation == .routeLost { reason = .replaced }
        else { reason = work.cancellation ?? .replaced }
        revokeMembers(next, reason: reason)
        restore(next)
      }
      throw (error as? IOSAudioSessionFailure) ?? IOSAudioSessionFailure.audio
    }
  }

  private func retainSurvivors(_ current: Group) -> Bool {
    guard group === current, recovery.blocker == nil, !current.members.isEmpty else { return false }
    let configured = session.configuration
    let owned = current.installed == configured || current.attempted.map { configured.satisfies($0) } == true
    guard owned else { return false }
    if !current.activated, current.members.values.contains(where: { $0.role != .silentVideo }) { return false }
    current.installed = configured
    current.attempted = nil
    return true
  }

  func release(_ token: Token) {
    precondition(Thread.isMainThread)
    guard let current = group, current.generation == token.generation,
      current.members.removeValue(forKey: token.member) != nil else { return }
    guard current.members.isEmpty else { changed(); return }
    // The current setter must settle first. Its common epilogue restores an
    // empty group unless that same acquisition actually admitted a new member.
    guard transition == nil else { return }
    let work = Transition()
    transition = work
    finishTransition(work)
  }

  private func finishTransition(_ work: Transition) {
    precondition(transition === work)
    if let current = group, current.members.isEmpty {
      group = nil
      restore(current)
    }
    transition = nil
    changed()
  }

  func poll() {
    precondition(Thread.isMainThread)
    guard transition == nil else { return }
    if let current = group, current.installed != session.configuration {
      invalidate(.replaced, restoreConfiguration: false)
    } else { changed() }
  }

  func interruptionBegan() {
    precondition(Thread.isMainThread)
    recovery.interrupted = true
    invalidate(.interrupted, restoreConfiguration: true)
  }
  func interruptionEnded() {
    precondition(Thread.isMainThread)
    recovery.interrupted = false
    changed()
  }
  func mediaServicesReset() {
    precondition(Thread.isMainThread)
    recovery.mediaServicesReset()
    invalidate(.mediaReset, restoreConfiguration: true)
  }
  func routeLost() {
    precondition(Thread.isMainThread)
    environment = UUID() // Retire an audible decoder that has no lease yet.
    if let transition {
      if transition.cancellation == nil, transition.acquiring?.stopsForRouteLoss == true {
        transition.cancellation = .routeLost
      }
      if let group { revokeMembers(group, reason: .routeLost, where: { $0.stopsForRouteLoss }) }
      return // The setter's epilogue handles an empty group after it returns.
    }
    let work = Transition()
    transition = work
    if let group { revokeMembers(group, reason: .routeLost, where: { $0.stopsForRouteLoss }) }
    finishTransition(work)
  }

  /// A valid foreground Voice start/NativeMedia play entry, or native PiP
  /// confirmation, may pass true after its relevant guards. Voice's existing
  /// Dart automatic fallback also uses startRecorder: this flag is an entry
  /// policy, not proof of a new physical tap. Companion speech, capabilities,
  /// foreground return and notifications never pass true.
  func retry(userInitiated: Bool) {
    precondition(Thread.isMainThread)
    guard transition == nil else { return }
    recovery.retry(userInitiated: userInitiated)
    poll()
    changed()
  }

  private func invalidate(_ reason: IOSAudioSessionRevocation, restoreConfiguration: Bool) {
    environment = UUID()
    if let transition {
      transition.cancellation = reason
      if let group { revokeMembers(group, reason: reason) }
      changed()
      return // The in-progress setter must return before its own cleanup.
    }
    let work = Transition()
    transition = work
    let old = group
    group = nil
    if let old {
      revokeMembers(old, reason: reason)
      if restoreConfiguration { restore(old) } else { residual = nil }
    }
    finishTransition(work)
  }

  private func revokeMembers(_ group: Group, reason: IOSAudioSessionRevocation,
                             where selected: (IOSAudioSessionRole) -> Bool = { _ in true }) {
    let members = group.members.filter { selected($0.value.role) }
    for (id, _) in members { group.members.removeValue(forKey: id) }
    if members.values.contains(where: { $0.role == .pictureInPicture }) { pictureLoss = UUID() }
    // Invalidate identities before calling clients. They stop outputs before
    // a higher-priority owner configures/activates; old release is a no-op.
    for (id, member) in members {
      member.revoke(Token(generation: group.generation, member: id), reason)
    }
  }

  private func restore(_ old: Group) {
    let current = session.configuration
    let ours = old.installed == current || old.attempted.map { current.satisfies($0) } == true
    guard ours else { residual = nil; return }
    if old.mayNeedDeactivation {
      do { try session.activate(false) }
      catch {
        // Failure may leave the session active. Do not install a non-mixing
        // baseline such as soloAmbient on top of that unknown activity.
        if session.configuration == current {
          residual = Residual(baseline: old.baseline, installed: current, mayNeedDeactivation: true)
        } else { residual = nil }
        return
      }
    }
    // No setters after a new, uncoordinated configuration appears, including
    // one installed synchronously by a deactivation callback.
    guard session.configuration == current else { residual = nil; return }
    do { try session.configure(old.baseline) } catch { }
    let after = session.configuration
    if after.satisfies(old.baseline) {
      residual = nil
    } else if after == current {
      residual = Residual(baseline: old.baseline, installed: after,
        mayNeedDeactivation: false)
    } else {
      residual = nil
    }
  }

  private func changed() {
    if observeSystem && group?.members.isEmpty == false {
      if timer == nil {
        let value = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
      }
    } else { timer?.invalidate(); timer = nil }
    let snapshot = availabilitySnapshot()
    guard snapshot != lastAvailability else { return }
    lastAvailability = snapshot
    availability = UUID()
    guard observeSystem, !changePending else { return }
    changePending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.changePending = false
      NotificationCenter.default.post(name: Self.availabilityChanged, object: self)
    }
  }

  private func availabilitySnapshot() -> Availability {
    // This generation is PiP readiness, not a count of shared utterances.
    // Brief recording transitions still version busy -> ready even when the
    // corresponding notifications are coalesced before delivery.
    Availability(pictureBlocker: blocker(for: .pictureInPicture), pictureLoss: pictureLoss)
  }

  private func installObservers() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      switch type {
      case .began: self?.interruptionBegan()
      case .ended: self?.interruptionEnded()
      @unknown default: break
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil, queue: .main) { [weak self] _ in self?.mediaServicesReset() })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main) { [weak self] note in
      if let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.routeLost() }
      else { self?.poll() }
    })
  }

  deinit {
    timer?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}

/// One client's revocable membership; releasing it cannot release another
/// member or an older/newer generation. Clients stop their objects first.
final class IOSAudioSessionLease {
  var onRevoked: ((IOSAudioSessionRevocation) -> Void)?
  private let coordinator: IOSAudioSessionCoordinator
  private let role: IOSAudioSessionRole
  private var token: IOSAudioSessionCoordinator.Token?
  private var stopOutput: (() -> Void)?

  init(role: IOSAudioSessionRole, coordinator: IOSAudioSessionCoordinator = .shared) {
    precondition(Thread.isMainThread)
    self.role = role
    self.coordinator = coordinator
  }
  var isHeld: Bool { precondition(Thread.isMainThread); return token != nil }
  var isValid: Bool {
    precondition(Thread.isMainThread)
    return token.map { coordinator.isValid($0) } ?? false
  }
  /// Install before acquire. The coordinator captures this resource-only
  /// stopper independently of the weak client/lease, so it still stops output
  /// before preemption if off-main destruction is awaiting main-queue cleanup.
  func setOutputStop(_ stop: @escaping () -> Void) {
    precondition(Thread.isMainThread)
    precondition(token == nil)
    stopOutput = stop
  }
  func acquire() throws {
    precondition(Thread.isMainThread)
    if let token {
      guard coordinator.isValid(token) else { coordinator.poll(); throw IOSAudioSessionFailure.replaced }
      return
    }
    let stop = stopOutput
    do {
      token = try coordinator.acquire(role) { [weak self, stop] old, reason in
        let notify: ((IOSAudioSessionRevocation) -> Void)?
        if let self, self.token == old {
          self.token = nil
          self.stopOutput = nil
          notify = self.onRevoked
        } else { notify = nil }
        stop?()
        notify?(reason)
      }
    } catch {
      stopOutput = nil
      throw error
    }
  }
  func release() {
    precondition(Thread.isMainThread)
    let old = token
    token = nil
    stopOutput = nil
    if let old { coordinator.release(old) }
  }
  deinit {
    guard let token else { return }
    let coordinator = coordinator
    let stop = stopOutput
    IOSAudioMainThreadCleanup { stop?(); coordinator.release(token) }.perform()
  }
}

/// Transfers existing resources to main-thread cleanup, without retaining an
/// object whose deinit has begun or constructing lazy UI/weak references there.
/// The lock protects one-time closure removal; only the main thread invokes it.
/// Captured resources must no longer be used by the disposing caller.
final class IOSAudioMainThreadCleanup: @unchecked Sendable {
  private let lock = NSLock()
  private var work: (() -> Void)?
  init(_ work: @escaping () -> Void) { self.work = work }
  func perform() {
    if Thread.isMainThread { run() }
    else { DispatchQueue.main.async { self.run() } }
  }
  private func run() {
    precondition(Thread.isMainThread)
    lock.lock()
    let action = work
    work = nil
    lock.unlock()
    action?()
  }
}

private final class IOSSystemAudioSessionBackend: IOSAudioSessionBackend {
  private let audio = AVAudioSession.sharedInstance()
  var configuration: IOSAudioSessionConfiguration {
    IOSAudioSessionConfiguration(category: audio.category, mode: audio.mode, options: audio.categoryOptions)
  }
  func configure(_ value: IOSAudioSessionConfiguration) throws {
    // ambient inherently mixes; mixWithOthers is only explicitly settable on
    // playback/playAndRecord/multiRoute. Restore the same effective options.
    let options = value.category == .ambient ? value.options.subtracting(.mixWithOthers) : value.options
    try audio.setCategory(value.category, mode: value.mode, options: options)
  }
  func activate(_ value: Bool) throws {
    try audio.setActive(value, options: value ? [] : .notifyOthersOnDeactivation)
  }
}
