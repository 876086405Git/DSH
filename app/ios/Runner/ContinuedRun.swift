import BackgroundTasks
import UIKit

/// Keeps a turn the user started going after they leave the app, where the system allows it:
/// iOS 26 and later, while it isn't short of resources. The system shows its own progress card
/// and the user can end the task there. Elsewhere, and once it ends, the engine pauses at its
/// next tool call as it always did. Main thread only.
final class ContinuedRun {
  /// Whether the task is running now.
  var onChange: ((Bool) -> Void)?

  private var wanted = false
  /// The system or the user ended it: not again until the next turn.
  private var spent = false
  private var submitted: String?
  private var task: BGTask?
  private var progress: Timer?

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
  }

  func update(running: Bool) {
    guard running != wanted else { return }
    wanted = running
    trace(running ? "requested" : "idle")
    if running {
      spent = false
    } else {
      finish(success: true)
    }
  }

  /// Continued tasks show a system Live Activity as soon as submitted. Submit
  /// at the foreground-to-background boundary so an ordinary foreground chat
  /// does not leave an always-on progress card above the conversation.
  @objc private func willResignActive() {
    if wanted { submit() }
  }

  @objc private func becameActive() {
    // Returning through Control Center or from another app ends the card. A
    // still-running turn can request a fresh task on the next departure.
    finish(success: true)
  }

  private func submit() {
    guard #available(iOS 26.0, *), !spent, task == nil, submitted == nil,
      UIApplication.shared.applicationState != .background
    else { return }
    // Each request registers its own identifier, so a late launch can't be taken for a newer turn's.
    let identifier = "\(Bundle.main.bundleIdentifier ?? "dsh").continued.\(UUID().uuidString)"
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
      guard let self, let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self.started(task)
    }
    guard registered else { trace("registration-failed"); return }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: String(localized: "DSH Go is working"),
      subtitle: String(localized: "This conversation is still going"))
    // Now or not at all: a turn is no use to anyone once it has already paused.
    request.strategy = .fail
    submitted = identifier
    do {
      try BGTaskScheduler.shared.submit(request)
      trace("submitted")
    } catch {
      if submitted == identifier { submitted = nil }
      trace("submit-failed-\((error as NSError).code)")
      // The system said no. The engine pauses in the background, as it does without this.
    }
  }

  @available(iOS 26.0, *)
  private func started(_ task: BGContinuedProcessingTask) {
    guard wanted, task.identifier == submitted else {
      task.setTaskCompleted(success: false)
      return
    }
    submitted = nil
    self.task = task
    trace("running")
    task.expirationHandler = { [weak self, weak task] in
      DispatchQueue.main.async {
        guard let self, let task, self.task === task else { return }
        self.spent = true
        self.trace("expired")
        self.finish(success: false)
      }
    }
    // A turn's length isn't known and the system expects to see progress: this moves and never ends.
    task.progress.totalUnitCount = 1_000_000
    progress = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak task] _ in
      task?.progress.completedUnitCount += 1
    }
    onChange?(true)
  }

  // Bounded, content-free development evidence for actual OS acceptance.
  // Never include tool arguments, endpoints, tokens or conversation identifiers.
  private func trace(_ stage: String) {
    guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let file = directory.appendingPathComponent("dsh-background-task.log")
    let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let line = "\(Date().timeIntervalSince1970) continued \(stage)\n"
    try? (String(previous.suffix(8192)) + line).write(to: file, atomically: true, encoding: .utf8)
  }

  private func finish(success: Bool) {
    progress?.invalidate()
    progress = nil
    if let submitted {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submitted)
      self.submitted = nil
    }
    guard let running = task else { return }
    task = nil
    running.setTaskCompleted(success: success)
    onChange?(false)
  }
}
