import AVFoundation
import CoreLocation
import Foundation
import UIKit

// BEGIN IOSBackgroundProtectionPolicy: also executed by the macOS fixture.
struct IOSBackgroundProtectionPolicy {
  var audioEnabled = false
  var locationEnabled = false
  var engineRunning = false
  var taskRunning = false
  var background = false

  var wanted: Bool { engineRunning && taskRunning && background }
  var wantsAudio: Bool { wanted && audioEnabled }
  var wantsLocation: Bool { wanted && locationEnabled }
}
// END IOSBackgroundProtectionPolicy

/// Main-thread only. Settings express consent, never a system execution grant.
/// No location is retained, logged or passed to the engine.
final class IOSBackgroundProtection: NSObject, CLLocationManagerDelegate, AVAudioPlayerDelegate {
  var onChange: (([String: Any]) -> Void)?

  private var policy = IOSBackgroundProtectionPolicy()
  private let defaults: UserDefaults
  private let location = CLLocationManager()
  private let audio = IOSAudioSessionLease(role: .backgroundProtection)
  private var player: AVAudioPlayer?
  private var locationRequested = false
  private var locationActive = false
  private var audioError: String?
  private var locationError: String?
  private var timer: Timer?
  private var lastStatus: NSDictionary?
  private static let audioKey = "dsh.backgroundProtection.audioEnabled"
  private static let locationKey = "dsh.backgroundProtection.locationEnabled"

  init(defaults: UserDefaults = .standard) {
    precondition(Thread.isMainThread)
    self.defaults = defaults
    super.init()
    policy.audioEnabled = defaults.bool(forKey: Self.audioKey)
    policy.locationEnabled = defaults.bool(forKey: Self.locationKey)
    policy.background = UIApplication.shared.applicationState == .background
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    location.distanceFilter = 3000
    location.pausesLocationUpdatesAutomatically = false
    audio.onRevoked = { [weak self] reason in
      guard let self else { return }
      self.player = nil // The lease's resource stopper has already stopped playback.
      switch reason {
      case .preempted, .replaced: self.audioError = "ios_background_audio_replaced"
      case .interrupted, .routeLost: self.audioError = "ios_background_audio_interrupted"
      case .mediaReset: self.audioError = "ios_background_audio_reset"
      }
      self.publish()
    }
  }

  /// Only the foreground settings action calls this; callbacks never request permission.
  func set(audioEnabled: Bool?, locationEnabled: Bool?) -> [String: Any] {
    precondition(Thread.isMainThread)
    guard UIApplication.shared.applicationState == .active else {
      var value = status()
      value["error"] = "ios_background_foreground_required"
      return value
    }
    if let audioEnabled {
      policy.audioEnabled = audioEnabled
      defaults.set(audioEnabled, forKey: Self.audioKey)
      audioError = nil
      if audioEnabled { IOSAudioSessionCoordinator.shared.retry(userInitiated: true) }
    }
    if let locationEnabled {
      policy.locationEnabled = locationEnabled
      defaults.set(locationEnabled, forKey: Self.locationKey)
      locationError = nil
      if locationEnabled, CLLocationManager.locationServicesEnabled(),
         location.authorizationStatus == .notDetermined || location.authorizationStatus == .authorizedWhenInUse {
        location.requestAlwaysAuthorization()
      }
    }
    reconcile()
    return status()
  }

  func update(engineRunning: Bool? = nil, taskRunning: Bool? = nil, background: Bool? = nil) {
    precondition(Thread.isMainThread)
    if let engineRunning { policy.engineRunning = engineRunning }
    if let taskRunning { policy.taskRunning = taskRunning }
    if let background { policy.background = background }
    reconcile()
  }

  func status() -> [String: Any] {
    precondition(Thread.isMainThread)
    var value: [String: Any] = [
      "supported": true, "audioEnabled": policy.audioEnabled, "locationEnabled": policy.locationEnabled,
      "audioActive": policy.wantsAudio && player?.isPlaying == true && audio.isValid,
      "locationActive": policy.wantsLocation && locationRequested && locationActive && locationAllowed,
      "locationAuthorization": authorization,
    ]
    if let error = audioError ?? locationProblem ?? locationError { value["error"] = error }
    return value
  }

  private var authorization: String {
    switch location.authorizationStatus {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedWhenInUse: return "authorizedWhenInUse"
    case .authorizedAlways: return "authorizedAlways"
    @unknown default: return "unknown"
    }
  }
  private var locationAllowed: Bool {
    CLLocationManager.locationServicesEnabled() && location.authorizationStatus == .authorizedAlways
  }
  private var locationProblem: String? {
    guard policy.locationEnabled else { return nil }
    if !CLLocationManager.locationServicesEnabled() { return "ios_background_location_services_disabled" }
    switch location.authorizationStatus {
    case .authorizedAlways: return nil
    case .denied: return "ios_background_location_denied"
    case .restricted: return "ios_background_location_restricted"
    default: return "ios_background_location_always_required"
    }
  }

  private func reconcile() {
    if !policy.wantsAudio {
      stopAudio()
      audioError = nil
    } else if audioError == nil, player == nil { startAudio() }
    if !policy.wantsLocation || !locationAllowed {
      stopLocation()
      if !policy.wantsLocation { locationError = nil }
    } else if !locationRequested, locationError == nil {
      location.allowsBackgroundLocationUpdates = true
      location.showsBackgroundLocationIndicator = true
      locationRequested = true
      location.startUpdatingLocation()
      // Starting a request is not proof of delivery; the first delegate update grants it.
    }
    if policy.wanted && (policy.audioEnabled || policy.locationEnabled) {
      if timer == nil {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
          guard let self else { return }
          if self.player != nil && (self.player?.isPlaying != true || !self.audio.isValid) {
            self.stopAudio()
            self.audioError = "ios_background_audio_stopped"
          }
          self.reconcile()
        }
      }
    } else { timer?.invalidate(); timer = nil }
    publish()
  }

  private func startAudio() {
    do {
      let output = try AVAudioPlayer(data: Self.silence())
      output.numberOfLoops = -1
      output.delegate = self
      audio.setOutputStop { output.stop() }
      try audio.acquire()
      guard output.play(), audio.isValid else {
        output.stop()
        audio.release()
        audioError = "ios_background_audio_play_failed"
        return
      }
      player = output
    } catch {
      audio.release()
      audioError = "ios_background_audio_unavailable"
    }
  }

  private func stopAudio() {
    player?.stop()
    player = nil
    audio.release()
  }
  private func stopLocation() {
    if locationRequested { location.stopUpdatingLocation() }
    locationRequested = false
    locationActive = false
    location.allowsBackgroundLocationUpdates = false
  }
  private func publish() {
    let value = status()
    let comparable = value as NSDictionary
    guard lastStatus != comparable else { return }
    lastStatus = comparable
    onChange?(value)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { reconcile() }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard locationRequested, policy.wantsLocation, locationAllowed, !locations.isEmpty else { return }
    locationActive = true
    locationError = nil
    publish()
  }
  func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
    guard locationRequested else { return }
    stopLocation()
    locationError = "ios_background_location_paused"
    publish()
  }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard locationRequested else { return }
    locationActive = false
    locationError = "ios_background_location_unavailable"
    if (error as? CLError)?.code != .locationUnknown { stopLocation() }
    publish()
  }
  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    guard player === self.player else { return }
    stopAudio()
    audioError = "ios_background_audio_decode_failed"
    publish()
  }
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard player === self.player else { return }
    stopAudio()
    audioError = "ios_background_audio_stopped"
    publish()
  }

  // One second of mono PCM silence in memory; no asset or temporary file.
  private static func silence() -> Data {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func word(_ value: UInt16) {
      data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    func integer(_ value: UInt32) { word(UInt16(truncatingIfNeeded: value)); word(UInt16(truncatingIfNeeded: value >> 16)) }
    text("RIFF"); integer(36 + 16000); text("WAVEfmt "); integer(16)
    word(1); word(1); integer(8000); integer(16000); word(2); word(16)
    text("data"); integer(16000); data.append(Data(count: 16000))
    return data
  }

  deinit {
    timer?.invalidate()
    let output = player
    let lease = audio
    let manager = location
    IOSAudioMainThreadCleanup {
      output?.stop()
      lease.release()
      manager.stopUpdatingLocation()
      manager.allowsBackgroundLocationUpdates = false
    }.perform()
  }
}
