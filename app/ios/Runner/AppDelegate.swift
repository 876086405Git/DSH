import Flutter
import Security
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var companionVoice: IOSCompanionVoice?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before launch finishes, or the tap that launched the app is lost.
    UNUserNotificationCenter.current().delegate = NotifyTaps.shared
    forgetPreviousInstall()
    #if DSH_PHONE_SELF_RUNNER_DIAGNOSTICS
    let preflight = ProcessInfo.processInfo.arguments.contains("--dsh-phone-preflight")
      || ProcessInfo.processInfo.environment["DSH_PHONE_PREFLIGHT"] == "1"
    IOSPhoneSelfRunner.diagnostic("launch preflight=\(preflight)")
    if preflight {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        Task { @MainActor in
          let owner = IOSPhoneSelfRunner.shared
          print("DSH_SELF_PREFLIGHT configured=\(owner.isConfigured)")
          IOSPhoneSelfRunner.diagnostic("preflight configured=\(owner.isConfigured)")
          for cycle in 1...2 {
            IOSPhoneSelfRunner.diagnostic("preflight cycle=\(cycle)")
            let result = await owner.prepare(ownerID: "device-preflight", current: { true })
            switch result {
            case .success:
              IOSPhoneSelfRunner.diagnostic("preflight ready cycle=\(cycle)")
            case .failure(let error):
              IOSPhoneSelfRunner.diagnostic("preflight failure=\(error)")
              owner.stop(ownerID: "device-preflight")
              return
            }
            owner.stop(ownerID: "device-preflight")
          }
          fflush(stdout)
        }
      }
    }
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// The Keychain outlives an uninstall and UserDefaults doesn't. On a fresh install
  /// anything in there belongs to the last one, and must not sign this one in.
  private func forgetPreviousInstall() {
    let marker = "dsh.installed"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: marker) else { return }
    SecItemDelete([kSecClass: kSecClassGenericPassword] as CFDictionary)
    defaults.set(true, forKey: marker)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DshPlugin") {
      DshPlugin.register(with: registrar)
      IOSPhoneControl.shared.register(messenger: registrar.messenger())
      IOSPhoneLink.shared.register(messenger: registrar.messenger(), presenter: { topViewController() })
      IOSPetOverlay.shared.register(registrar: registrar)
      companionVoice?.dispose()
      companionVoice = IOSCompanionVoice(messenger: registrar.messenger(), pipAudioConfigured: {
        IOSPetOverlay.shared.statusSnapshot["audioSessionConfigured"] as? Bool == true
      })
      IOSPetOverlay.shared.onTaskPauseRequested = { IOSPhoneControl.shared.pausePhoneTask(id: $0) }
      IOSPetOverlay.shared.onTaskStopConfirmed = { IOSPhoneControl.shared.stopPhoneTaskConfirmed(id: $0) }
      IOSPetOverlay.shared.onTaskResumeConfirmed = { IOSPhoneControl.shared.resumePhoneTask(id: $0) }
    }
  }
}
