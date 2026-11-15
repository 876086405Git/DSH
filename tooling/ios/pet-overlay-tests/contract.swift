import Foundation

@main
struct PetOverlayContract {
  static var checks = 0
  static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
    checks += 1
  }

  static func main() throws {
    guard CommandLine.arguments.count == 2 else { fatalError("Pass app/assets/pets") }
    let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    checkFailureRecovery()
    checkRestoreAndTemporarySource()
    var policy = PetOverlayPolicy()
    check(!policy.enabled && !policy.alwaysShow && !policy.hasDemand, "default off")
    check(policy.begin(id: 3, sessionID: "fixture", line: "Maps"), "authenticated owner begin")
    check(!policy.hasDemand, "task cannot enable the feature")
    policy.enabled = true
    check(policy.hasDemand, "enabled active task has demand")
    check(!policy.end(id: 2) && policy.task?.id == 3, "stale end cannot end current task")
    check(policy.requestPause() == 3 && policy.paused, "system pause locks exact owner")
    check(policy.requestPause() == nil, "pause callback is delivered once")
    check(!policy.confirmResume(id: 2) && policy.paused, "stale resume cannot unlock current task")
    check(!policy.mayConfirmStop(id: 2) && policy.mayConfirmStop(id: 3), "stop confirmation is owner bound")
    check(policy.confirmResume(id: 3) && !policy.paused, "explicit current-owner resume")
    policy.update(id: 2, line: "stale", progress: 0.8)
    check(policy.task?.line == "Maps", "stale progress is ignored")
    check(policy.end(id: 3) && !policy.hasDemand, "task end is immediate, without Android grace period")
    check(!policy.begin(id: 3, sessionID: "fixture", line: nil), "ended task cannot be revived by stale begin")
    policy.alwaysShow = true
    check(policy.hasDemand, "separately chosen alwaysShow survives end")
    policy.snoozed = true
    check(!policy.hasDemand, "system close suppresses automatic restart")
    check(!PetOverlayState.safeAssetComponent("../deepy-whale"), "pack path cannot escape assets")
    let ignored = PetOverlayState(["state": "invented", "packId": "none", "active": true,
      "foreground": false, "bubble": ["id": "one", "text": "Approved title", "untilMs": 5000,
        "ask": ["text": "do not render private request"], "detail": "do not render reply"]])
    check(ignored.state == "idle" && ignored.packID == nil, "unknown mood and no-pet semantics")
    check(ignored.visibleBubble(at: 4000) == "Approved title", "only reduced bubble title is rendered")
    check(ignored.visibleBubble(at: 5000) == nil, "bubble expires without another Dart push")
    let quiet = PetOverlayState(["quiet": true, "bubble": ["id": "q", "text": "quiet", "untilMs": 10000]])
    check(quiet.visibleBubble(at: 0) == nil, "quiet suppresses title")

    let repeated = PetOverlayAnimation(name: "fixture", sheet: "fixture.png", frameWidth: 4,
      frameHeight: 3, columns: 2, box: PetOverlayBox(x: 1, y: 2, width: 4, height: 3),
      frames: [PetOverlayFrame(cell: 0, milliseconds: 40), PetOverlayFrame(cell: 0, milliseconds: 60),
        PetOverlayFrame(cell: 3, milliseconds: 90)], loops: true)
    check(repeated.frameIndex(at: 39) == 0 && repeated.frameIndex(at: 40) == 1,
      "unequal per-frame durations are not flattened")
    check(repeated.nextChange(after: 0) == 100 && repeated.nextChange(after: 80) == 20,
      "repeated cells preserve timing without redraw")
    check(repeated.sourceRect(cell: 3) == PetOverlayBox(x: 4, y: 3, width: 4, height: 3), "row-major grid")
    check(repeated.frameIndex(at: 190) == 0, "loop boundary wraps exactly")
    let oneShot = PetOverlayAnimation(name: "once", sheet: "fixture.png", frameWidth: 4,
      frameHeight: 3, columns: 2, box: repeated.box, frames: repeated.frames, loops: false)
    check(oneShot.frameIndex(at: 10000) == 2 && oneShot.nextChange(after: 190) == nil,
      "one-shot holds final frame with no timer")

    for id in ["deepy-whale", "whale-girl"] {
      let bytes = try Data(contentsOf: assets.appendingPathComponent(id + "/pack.json"))
      let pack = try PetOverlayPack(data: bytes, expectedID: id)
      check(pack.primary(state: "working", tier: 1).name == "typing", id + " working tier one")
      check(pack.primary(state: "working", tier: 3).name == "building", id + " working tier three")
      check(pack.primary(state: "juggling", tier: 2).name == "conducting", id + " subagent tier")
      check(pack.primary(state: "unknown", tier: 0).name == "idle", id + " fallback matches Dart")
      for density in [1.0, 2.0, 2.75, 3.0] {
        let s = pack.artScale(size: .small, deviceScale: density)
        let m = pack.artScale(size: .medium, deviceScale: density)
        let l = pack.artScale(size: .large, deviceScale: density)
        check(s.rounded() == s && m >= s + 1 && l >= m + 1, id + " distinct physical-pixel sizes")
      }
      for animation in pack.animations.values {
        var at = 0
        for (index, frame) in animation.frames.enumerated() {
          check(animation.frameIndex(at: at) == index, id + " " + animation.name + " boundary")
          check(animation.frameIndex(at: at + frame.milliseconds - 1) == index,
            id + " " + animation.name + " end-exclusive timing")
          at += frame.milliseconds
        }
      }
      let active = PetOverlayState(["packId": id, "state": "working", "tier": 1])
      var clock = PetOverlayFrameClock()
      let first = clock.frame(pack: pack, state: active, now: 1000, random: { 0.9 })
      clock.setPaused(true, now: 1020)
      let frozen = clock.frame(pack: pack, state: active, now: 9000, random: { 0.9 })
      check(first.index == frozen.index, id + " hiding freezes frame clock")
      clock.setPaused(false, now: 9000)
      let resumed = clock.frame(pack: pack, state: active, now: 9000, random: { 0.9 })
      check(resumed.index == frozen.index, id + " resume does not skip hidden time")
      let still = PetOverlayState(["packId": id, "state": "working", "tier": 1, "reduceMotion": true])
      let frame = clock.frame(pack: pack, state: still, now: 10000, random: { 0.9 })
      check(frame.index == 0 && frame.nextMilliseconds == nil, id + " reduced motion has no timer")
      var calm = PetOverlayFrameClock()
      let sleeping = PetOverlayState(["packId": id, "state": "sleeping"])
      _ = calm.frame(pack: pack, state: sleeping, now: 0, random: { 0 })
      let sleepAction = calm.frame(pack: pack, state: sleeping, now: 8000, random: { 0 })
      check(sleepAction.animation.name == "sleeping", id + " sleeping never invents a waking mood")
      var corrupt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      corrupt["scale"] = true
      do {
        _ = try PetOverlayPack(data: JSONSerialization.data(withJSONObject: corrupt), expectedID: id)
        fatalError("boolean scale accepted")
      } catch is PetOverlayPackFailure { checks += 1 }
    }
    print("PASS: \(checks) production Swift policy/pack/frame assertions; no AVKit/device claims")
  }

  static func checkRestoreAndTemporarySource() {
    var policy = PetOverlayPolicy()
    check(!policy.allowsTemporarySource && !policy.consumeRestore(), "idle has no preview or pending navigation")
    policy.enabled = true
    policy.alwaysShow = true
    check(policy.hasDemand && !policy.allowsTemporarySource,
      "alwaysShow alone needs a real embedded source, not a temporary window preview")
    check(policy.begin(id: 70, sessionID: "restore-owner", line: nil), "restore fixture owner begins")
    check(policy.allowsTemporarySource, "a current enabled phone task may show the temporary source")
    check(policy.requestPause() == 70 && policy.wantsRestore, "first pause requests one owner navigation")
    check(policy.consumeRestore(), "first foreground restore consumes navigation")
    check(policy.paused && policy.needsStopConfirmation && policy.allowsTemporarySource,
      "navigation does not approve, resume or remove the paused task preview")
    check(!policy.consumeRestore() && !policy.consumeRestore(),
      "repeated foreground returns do not repeatedly navigate while kept paused")
    check(policy.needsStopConfirmation, "later foreground confirmation is independent of consumed navigation")
    check(policy.requestPause() == nil && !policy.wantsRestore, "duplicate pause cannot request another navigation")
    for intent in ["system Restore", "reviewPausedTask"] {
      policy.requestRestore()
      check(policy.consumeRestore() && !policy.consumeRestore(), intent + " explicitly requests one more navigation")
      check(policy.paused && policy.needsStopConfirmation, intent + " cannot implicitly resume")
    }
    policy.requestRestore()
    check(!policy.confirmResume(id: 69) && policy.wantsRestore, "stale resume leaves current intent untouched")
    check(policy.confirmResume(id: 70) && !policy.wantsRestore && !policy.needsStopConfirmation,
      "confirmed resume clears the old pause intent")
    check(policy.requestPause() == 70 && policy.consumeRestore(), "a new pause can request navigation again")
    policy.requestRestore()
    check(!policy.end(id: 69) && policy.wantsRestore, "stale end cannot consume current navigation")
    check(policy.end(id: 70) && !policy.wantsRestore && !policy.allowsTemporarySource && policy.hasDemand,
      "task end removes pending navigation and temporary preview, retaining separate alwaysShow demand")
    policy.requestRestore()
    check(policy.consumeRestore() && !policy.consumeRestore(), "explicit no-task Restore can target the current chat once")
    policy.requestRestore()
    check(policy.begin(id: 71, sessionID: "next-owner", line: nil) && !policy.wantsRestore,
      "a new owner cannot inherit an old restore request")
    policy.snoozed = true
    check(!policy.allowsTemporarySource, "snooze forbids the temporary source")
    policy.snoozed = false
    policy.enabled = false
    check(!policy.allowsTemporarySource, "disabled forbids the temporary source even with an owner")
  }

  static func checkFailureRecovery() {
    var failure = PetOverlayFailureState()
    check(!failure.recover(protectedDataAvailable: true, audioMayPrepare: true), "no spurious recovery")
    failure.record("overlay_device_locked")
    check(!failure.recover(protectedDataAvailable: false, audioMayPrepare: true), "locked data stays blocked")
    check(failure.code == "overlay_device_locked", "lock error survives an unrelated audio event")
    check(failure.recover(protectedDataAvailable: true, audioMayPrepare: false), "unlock clears only the lock latch")
    check(failure.code == nil, "idle unlock no longer needs an explicit Recover tap")

    for code in ["overlay_audio_busy", "overlay_audio_replaced", "overlay_audio_interrupted",
      "overlay_audio_failed"] {
      failure.record(code)
      check(!failure.recover(protectedDataAvailable: false, audioMayPrepare: true), code + " cannot recover while locked")
      check(!failure.recover(protectedDataAvailable: true, audioMayPrepare: false), code + " requires eligible audio")
      check(failure.code == code, code + " survives a still-busy route change")
      check(failure.recover(protectedDataAvailable: true, audioMayPrepare: true), code + " recovers when conditions allow a new attempt")
      check(failure.code == nil, code + " does not permanently block a new task")
      check(!failure.recover(protectedDataAvailable: true, audioMayPrepare: true), code + " recovery is idempotent")
    }

    for code in ["overlay_unsupported", "overlay_pack_missing", "overlay_pack_invalid", "overlay_sheet_invalid",
      "overlay_source_missing", "overlay_pip_start_failed", "overlay_display_stalled", "overlay_render_failed",
      "overlay_media_reset"] {
      failure.record(code)
      check(!failure.recover(protectedDataAvailable: true, audioMayPrepare: true), code + " is not cleared by unrelated recovery")
      failure.record("overlay_device_locked")
      failure.record("overlay_audio_interrupted")
      check(failure.code == code, code + " is not hidden by a later transient failure")
      failure.clear()
    }

    var audio = PetOverlayAudioRecoveryState()
    check(audio.blocker == nil, "audio starts without a reset gate")
    audio.interrupted = true
    check(audio.blocker == "overlay_audio_interrupted", "interruption blocks a new attempt")
    audio.retry(userInitiated: false)
    check(audio.blocker == nil, "foreground can retry an interruption without an ended event")
    audio.mediaServicesReset()
    check(audio.blocker == "overlay_media_reset", "reset requires a later user action")
    audio.retry(userInitiated: false)
    check(audio.blocker == "overlay_media_reset", "foreground alone cannot clear a reset gate")
    audio.interrupted = true
    audio.interrupted = false
    check(audio.blocker == "overlay_media_reset", "later interruption events cannot clear a reset gate")
    failure.record("overlay_pack_invalid")
    failure.clear()
    check(audio.blocker == "overlay_media_reset", "displayed error changes cannot authorize audio after reset")
    audio.retry(userInitiated: true)
    check(audio.blocker == nil, "explicit user recovery permits a new activation attempt")
    audio.mediaServicesReset()
    check(audio.requiresUserAction, "a second reset requires another user action")

    var policy = PetOverlayPolicy()
    policy.enabled = true
    check(policy.begin(id: 40, sessionID: "recovery-fixture", line: nil), "recovery owner begins")
    check(policy.requestPause() == 40, "interrupted owner was paused")
    policy.snoozed = true
    failure.record("overlay_audio_interrupted")
    check(failure.recover(protectedDataAvailable: true, audioMayPrepare: true), "readiness recovers independently")
    check(policy.paused && policy.needsStopConfirmation && policy.snoozed,
      "automatic recovery cannot resume an existing task or clear user-close snooze")
    check(!policy.confirmResume(id: 39) && policy.paused, "recovery cannot authorize an old owner")
    check(policy.end(id: 40) && failure.code == nil, "ending the owner does not retain an old audio failure")
    policy.snoozed = false // Explicit user choice, not an effect of recovery.
    check(policy.begin(id: 41, sessionID: "next-fixture", line: nil) && !policy.paused && policy.hasDemand,
      "fresh owner is eligible after recovery; its action approval remains outside overlay policy")
  }
}
