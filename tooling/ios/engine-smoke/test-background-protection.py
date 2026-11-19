#!/usr/bin/env python3
"""Execute production protection/coordinator/lifecycle Swift against system stubs.

macOS CI only. No microphone, audio output, location request or real engine runs.
The stubs replace OS facilities, not production policy or arbitration methods.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    raise SystemExit('Requires the macOS Foundation/Swift toolchain')
root = Path(__file__).resolve().parents[3]
runner = root / 'app/ios/Runner'


def without_imports(source):
    return '\n'.join(line for line in source.splitlines() if not line.startswith('import '))


recovery_source = (runner / 'PetOverlay/PetOverlayState.swift').read_text()
recovery = recovery_source[recovery_source.index('struct PetOverlayAudioRecoveryState {'):recovery_source.index('struct PetOverlayPolicy {')]
engine_source = (runner / 'EngineChannel.swift').read_text()
lifecycle = engine_source[engine_source.index('private final class EngineLifecycle:'):engine_source.index('/// dsh/runtime:')]
coordinator = without_imports((runner / 'IOSAudioSessionCoordinator.swift').read_text())
protection = without_imports((runner / 'IOSBackgroundProtection.swift').read_text())

stubs = r'''
import Foundation

final class AVAudioSession {
  enum Category { case soloAmbient, ambient, playback, record, playAndRecord, multiRoute }
  enum Mode { case `default`, measurement, voiceChat, spokenAudio, moviePlayback }
  struct CategoryOptions: OptionSet {
    let rawValue: UInt
    static let mixWithOthers = Self(rawValue: 1)
    static let duckOthers = Self(rawValue: 2)
    static let defaultToSpeaker = Self(rawValue: 4)
    static let interruptSpokenAudioAndMixWithOthers = Self(rawValue: 8)
  }
  struct SetActiveOptions: OptionSet {
    let rawValue: UInt
    static let notifyOthersOnDeactivation = Self(rawValue: 1)
  }
  enum InterruptionType: UInt { case began, ended }
  enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2 }
  static let interruptionNotification = Notification.Name("fixture.interruption")
  static let mediaServicesWereResetNotification = Notification.Name("fixture.reset")
  static let routeChangeNotification = Notification.Name("fixture.route")
  private static let instance = AVAudioSession()
  static func sharedInstance() -> AVAudioSession { instance }
  var category = Category.soloAmbient
  var mode = Mode.default
  var categoryOptions: CategoryOptions = []
  func setCategory(_ category: Category, mode: Mode, options: CategoryOptions) throws {
    self.category = category; self.mode = mode; categoryOptions = options
  }
  func setActive(_ value: Bool, options: SetActiveOptions) throws {}
}
let AVAudioSessionInterruptionTypeKey = "interruption"
let AVAudioSessionRouteChangeReasonKey = "route"

protocol AVAudioPlayerDelegate: AnyObject {}
final class AVAudioPlayer {
  static var canPlay = true
  static weak var latest: AVAudioPlayer?
  var numberOfLoops = 0
  weak var delegate: AVAudioPlayerDelegate?
  private(set) var isPlaying = false
  init(data: Data) throws {
    precondition(data.count == 16044 && String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    precondition(data.dropFirst(44).allSatisfy { $0 == 0 })
    Self.latest = self
  }
  func play() -> Bool { isPlaying = Self.canPlay; return isPlaying }
  func stop() { isPlaying = false }
}
final class UIApplication {
  enum State { case active, inactive, background }
  static let shared = UIApplication()
  var applicationState = State.active
}
enum CLAuthorizationStatus { case notDetermined, restricted, denied, authorizedAlways, authorizedWhenInUse }
protocol CLLocationManagerDelegate: AnyObject {}
final class CLLocation {}
let kCLLocationAccuracyThreeKilometers = 3000.0
struct CLError: Error {
  enum Code { case locationUnknown, denied }
  let code: Code
}
final class CLLocationManager {
  static var services = true
  static var requests = 0
  static weak var latest: CLLocationManager?
  static func locationServicesEnabled() -> Bool { services }
  weak var delegate: CLLocationManagerDelegate?
  var authorizationStatus = CLAuthorizationStatus.notDetermined
  var desiredAccuracy = 0.0
  var distanceFilter = 0.0
  var pausesLocationUpdatesAutomatically = false
  var allowsBackgroundLocationUpdates = false
  var showsBackgroundLocationIndicator = false
  private(set) var started = false
  init() { Self.latest = self }
  func requestAlwaysAuthorization() { Self.requests += 1 }
  func startUpdatingLocation() { started = true }
  func stopUpdatingLocation() { started = false }
}

final class RecordingBackend: IOSAudioSessionBackend {
  var configuration = IOSAudioSessionConfiguration(category: .soloAmbient, mode: .default, options: [])
  var writes = 0
  func configure(_ value: IOSAudioSessionConfiguration) throws { writes += 1; configuration = value }
  func activate(_ value: Bool) throws { writes += 1 }
}
'''

fixture = r'''
@main struct BackgroundProtectionFixture {
  static func main() throws {
    precondition(Thread.isMainThread)
    // Execute all combinations of production consent/demand policy.
    for bits in 0..<32 {
      var policy = IOSBackgroundProtectionPolicy()
      policy.audioEnabled = bits & 1 != 0
      policy.locationEnabled = bits & 2 != 0
      policy.engineRunning = bits & 4 != 0
      policy.taskRunning = bits & 8 != 0
      policy.background = bits & 16 != 0
      let demand = bits & 28 == 28
      precondition(policy.wantsAudio == (demand && bits & 1 != 0))
      precondition(policy.wantsLocation == (demand && bits & 2 != 0))
    }
    // Every pre-existing role preempts silence, but silence can preempt none.
    for role in [IOSAudioSessionRole.recording, .call, .companion, .pictureInPicture, .nativeMedia, .silentVideo] {
      let backend = RecordingBackend()
      let coordinator = IOSAudioSessionCoordinator(session: backend)
      var stopped = false
      let background = try coordinator.acquire(.backgroundProtection) { _, reason in
        precondition(reason == .preempted); stopped = true
      }
      let owner = try coordinator.acquire(role) { _, _ in }
      precondition(stopped && !coordinator.isValid(background) && coordinator.isValid(owner))
      coordinator.release(background)
      let writes = backend.writes
      do {
        _ = try coordinator.acquire(.backgroundProtection) { _, _ in }
        preconditionFailure("silence took over a higher priority role")
      } catch { precondition(error as? IOSAudioSessionFailure == .busy) }
      precondition(backend.writes == writes && coordinator.isValid(owner))
      coordinator.release(owner)
      let next = try coordinator.acquire(.backgroundProtection) { _, _ in }
      precondition(coordinator.isValid(next))
      coordinator.release(next)
    }
    let suite = "dsh-background-fixture-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let protection = IOSBackgroundProtection(defaults: defaults)
    let manager = CLLocationManager.latest!
    precondition(!manager.pausesLocationUpdatesAutomatically && !manager.started)
    var observed: [String: Any] = [:]
    protection.onChange = { observed = $0 }
    func active(_ key: String) -> Bool { protection.status()[key] as? Bool == true }
    UIApplication.shared.applicationState = .background
    protection.update(engineRunning: true, taskRunning: true, background: true)
    precondition(!active("audioActive") && !active("locationActive") && !manager.started)
    precondition(CLLocationManager.requests == 0)
    let deniedChange = protection.set(audioEnabled: true, locationEnabled: true)
    precondition(deniedChange["error"] as? String == "ios_background_foreground_required")
    precondition(!active("audioEnabled") && CLLocationManager.requests == 0)
    UIApplication.shared.applicationState = .active
    protection.update(background: false)
    let pending = protection.set(audioEnabled: true, locationEnabled: true)
    precondition(CLLocationManager.requests == 1)
    precondition(pending["locationAuthorization"] as? String == "notDetermined")
    precondition(!active("audioActive") && !active("locationActive") && !manager.started)
    manager.authorizationStatus = .authorizedAlways
    protection.locationManagerDidChangeAuthorization(manager)
    precondition(!manager.started && !active("locationActive"))
    UIApplication.shared.applicationState = .background
    protection.update(background: true)
    let firstPlayer = AVAudioPlayer.latest!
    precondition(active("audioActive") && manager.started && !active("locationActive"))
    protection.locationManager(manager, didUpdateLocations: [CLLocation()])
    precondition(active("locationActive") && observed["locationActive"] as? Bool == true)
    IOSAudioSessionCoordinator.shared.interruptionBegan()
    precondition(!active("audioActive") && !firstPlayer.isPlaying && active("locationActive"))
    IOSAudioSessionCoordinator.shared.interruptionEnded()
    protection.update(engineRunning: true)
    precondition(!active("audioActive"), "interruption callback cannot silently reactivate silence")
    protection.locationManagerDidPauseLocationUpdates(manager)
    precondition(!active("locationActive") && !manager.started)
    precondition(protection.status()["error"] != nil)
    UIApplication.shared.applicationState = .active
    protection.update(background: false)
    UIApplication.shared.applicationState = .background
    protection.update(background: true)
    precondition(active("audioActive") && manager.started)
    let currentPlayer = AVAudioPlayer.latest!
    protection.audioPlayerDidFinishPlaying(firstPlayer, successfully: false)
    precondition(currentPlayer.isPlaying && active("audioActive"), "late old player callback stopped new audio")
    protection.locationManager(manager, didUpdateLocations: [CLLocation()])
    protection.update(taskRunning: false)
    precondition(!currentPlayer.isPlaying && !manager.started && !active("audioActive") && !active("locationActive"))
    protection.update(taskRunning: true)
    protection.locationManager(manager, didUpdateLocations: [CLLocation()])
    protection.update(engineRunning: false)
    precondition(!active("audioActive") && !active("locationActive") && !manager.started)
    protection.update(engineRunning: true)
    CLLocationManager.services = false
    protection.update(engineRunning: true)
    precondition(!active("locationActive") && !manager.started)
    precondition(protection.status()["error"] as? String == "ios_background_location_services_disabled")
    CLLocationManager.services = true
    manager.authorizationStatus = .denied
    protection.locationManagerDidChangeAuthorization(manager)
    precondition(!active("locationActive") && active("audioActive"))
    precondition(protection.status()["error"] as? String == "ios_background_location_denied")
    UIApplication.shared.applicationState = .active
    protection.update(background: false)
    _ = protection.set(audioEnabled: false, locationEnabled: false)
    precondition(CLLocationManager.requests == 1, "callbacks or disable requested permission again")
    UIApplication.shared.applicationState = .background
    protection.update(background: true)
    precondition(!active("audioActive") && !active("locationActive"))
    UIApplication.shared.applicationState = .active
    protection.update(background: false)
    _ = protection.set(audioEnabled: true, locationEnabled: false)
    AVAudioPlayer.canPlay = false
    UIApplication.shared.applicationState = .background
    protection.update(background: true)
    precondition(!active("audioActive"))
    precondition(protection.status()["error"] as? String == "ios_background_audio_play_failed")
    protection.update(taskRunning: false)
    AVAudioPlayer.canPlay = true
    // Restoring settings does not request permission or start idle protection.
    let restored = IOSBackgroundProtection(defaults: defaults)
    precondition(restored.status()["audioEnabled"] as? Bool == true)
    precondition(restored.status()["audioActive"] as? Bool == false && CLLocationManager.requests == 1)

    // Exercise production EngineLifecycle, not a duplicate OR model.
    let queue = DispatchQueue(label: "background-protection-fixture")
    var nativeGrant = false
    let lifecycle = EngineLifecycle(queue: queue, updateNative: { _, allowed in nativeGrant = allowed }, changed: {}, lostServer: {})
    for bits in 0..<16 {
      lifecycle.observe(continued: bits & 1 != 0)
      lifecycle.observe(pictureInPicture: bits & 2 != 0)
      lifecycle.observe(backgroundAudio: bits & 4 != 0, backgroundLocation: bits & 8 != 0)
      precondition(lifecycle.continued == (bits != 0))
      precondition(nativeGrant == (bits != 0))
      let status = lifecycle.status()
      precondition(status["backgroundAudio"] as? Bool == (bits & 4 != 0))
      precondition(status["backgroundLocation"] as? Bool == (bits & 8 != 0))
    }
    lifecycle.observe(backgroundAudio: false, backgroundLocation: false)
    precondition(lifecycle.continued, "stopping enhancements removed BG/PiP")
    lifecycle.observe(continued: false)
    precondition(lifecycle.continued, "stopping continued removed PiP")
    lifecycle.observe(pictureInPicture: false)
    precondition(!lifecycle.continued)
    print("Background protection: consent, demand, arbitration, revocation and source composition passed")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='dsh-background-protection-') as directory:
    directory = Path(directory)
    swift = directory / 'fixture.swift'
    executable = directory / 'fixture'
    swift.write_text('\n\n'.join([stubs, recovery, coordinator, protection, lifecycle, fixture]))
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=60)
