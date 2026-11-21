import ActivityKit
import Flutter
import UIKit

/// The pet's live activity on the lock screen and in the Dynamic Island: the LivePush
/// Android turns into a promoted notification (lib/state/live_activity_state.dart),
/// drawn by CompanionWidget/LiveActivityWidget.swift. Reached through `dsh/notify`.
///
/// - One activity, following the pet's conversation. iOS lets an app start one only
///   while it is in front, so one that couldn't start waits for the app to come back.
/// - Swiped away, it stays away until nothing runs or another conversation takes over.
/// - While the app runs it renews its stale date every minute; once iOS suspends the app
///   the card says it has stopped updating, rather than a clock that may be wrong.
/// - A run that ends in the background keeps its card up to 20 seconds for its result,
///   which arrives a moment after the run leaves the list.
/// - A finished turn stays on the lock screen for a while and goes when the app is opened.
final class IOSLiveActivity {
  static let shared = IOSLiveActivity()

  /// `dsh/notify`, which Dart answers 停止 on.
  weak var channel: FlutterMethodChannel?
  private var engine: AnyObject?

  private init() {
    if #available(iOS 17.0, *) {
      DSHLiveStopIntent.handler = { host, session in
        await IOSLiveActivity.shared.stop(host: host, session: session)
      }
    }
  }

  /// Called at launch, before an engine: 停止 can bring the app up in the background.
  func prepare() {}

  func status() -> [String: Any] {
    guard #available(iOS 16.2, *),
      UIDevice.current.userInterfaceIdiom == .phone || ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0))
    else { return ["supported": false, "allowed": false, "settings": false] }
    return ["supported": true, "allowed": ActivityAuthorizationInfo().areActivitiesEnabled, "settings": true]
  }

  func live(_ args: [String: Any]) {
    guard #available(iOS 16.2, *) else { return }
    current.apply(args)
  }

  /// A tap on the activity (`dshgo://live?…`), as the tap on a notification Dart reads.
  static func tap(_ url: URL) -> [AnyHashable: Any]? {
    guard url.scheme == "dshgo", url.host == "live",
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard let session = value("sessionId"), !session.isEmpty, session.count <= 200 else { return nil }
    var tap: [AnyHashable: Any] = ["sessionId": session, "kind": "live"]
    if let host = value("host") { tap["host"] = host }
    if let event = value("eventId") { tap["eventId"] = event }
    return tap
  }

  @available(iOS 16.2, *)
  private var current: LiveActivityEngine {
    if let engine = engine as? LiveActivityEngine { return engine }
    let made = LiveActivityEngine()
    engine = made
    return made
  }

  /// Dart decides, with the floating pet's own checks. Without an answer in ten
  /// seconds (no engine yet, Dart busy) the button simply did nothing.
  private func stop(host: String, session: String) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async {
        var finished = false
        let finish = {
          guard !finished else { return }
          finished = true
          done.resume()
        }
        guard let channel = self.channel else { return finish() }
        channel.invokeMethod("liveStop", arguments: ["host": host, "sessionId": session]) { _ in finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: finish)
      }
    }
  }
}

@available(iOS 16.2, *)
private final class LiveActivityEngine {
  private typealias State = DSHLiveAttributes.ContentState

  /// The last push with the extras that came with it: a push without them (the
  /// settings page sends one on return) keeps the colours, words and picture.
  private var latest: [String: Any] = [:]
  private var tail: Task<Void, Never>?
  /// The conversation this run of the activity is about, and whether the person
  /// swiped it away; an activity of ours having been there tells the two apart.
  private var episode: String?
  private var dismissed = false
  private var shown = false
  /// The pet's conversation's run: when it started and, once over, when it ended.
  private var run: (session: String, since: Date, until: Date?)?
  private var refresh: Timer?
  /// A run that just ended in the background: its card waits this long for the
  /// result, which comes a moment after the run leaves the list.
  private var hold: Timer?

  init() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.cameToFront() }
  }

  func apply(_ args: [String: Any]) {
    let push = ["enabled", "packId", "activity"]
    for key in push { latest[key] = args[key] }
    for (key, value) in args where !push.contains(key) && key != "art" { latest[key] = value }
    let art = (args["art"] as? FlutterStandardTypedData)?.data
    let snapshot = latest
    enqueue { await $0.render(snapshot, art: art) }
  }

  private func enqueue(_ work: @escaping @MainActor (LiveActivityEngine) async -> Void) {
    let previous = tail
    tail = Task { @MainActor in
      await previous?.value
      await work(self)
    }
  }

  @MainActor
  private func render(_ args: [String: Any], art: Data?, mayHold: Bool = true) async {
    let all = Activity<DSHLiveAttributes>.activities
    let live = all.filter { $0.activityState == .active || $0.activityState == .stale }
    let enabled = args["enabled"] as? Bool == true
    guard enabled, let state = content(args) else {
      // The last run left the list and its 做完了 / 出错了 is still on the way. iOS
      // won't start a new card from the background, so this one waits for it.
      if enabled, mayHold, UIApplication.shared.applicationState != .active,
        live.contains(where: { $0.content.state.running }) {
        holdForResult()
        return
      }
      await finish(all)
      return
    }
    hold?.invalidate()
    hold = nil
    if let art, let key = state.art { LiveArtStore.save(key: key, png: art) }
    if let activity = live.first {
      for extra in live.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
      episode = state.session
      keepFresh(state)
      if !state.running && UIApplication.shared.applicationState != .active {
        // The turn is over: end it now with its 15 minutes, while the app still runs
        // to say so. Suspended before the next push, it would otherwise stay up for hours.
        await activity.end(ActivityContent(state: state, staleDate: nil),
          dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
        shown = false
      } else {
        await activity.update(ActivityContent(state: state, staleDate: staleDate(state)))
        shown = true
      }
      return
    }
    // A turn that is over doesn't start a card, or replace the one it left on the lock screen.
    guard state.running else { return }
    // Ours, and gone without us ending it: swiped away (or iOS's eight hours were up).
    if shown {
      shown = false
      dismissed = true
    }
    if state.session != episode {
      episode = state.session
      dismissed = false
    }
    guard !dismissed else { return }
    // Only in front; one that can't start now does when the app comes back (cameToFront).
    // Until then a finished turn's card stays where it is.
    guard UIApplication.shared.applicationState == .active else { return }
    // That card goes first: one DSH card at a time.
    for old in all { await old.end(nil, dismissalPolicy: .immediate) }
    do {
      _ = try Activity.request(attributes: DSHLiveAttributes(),
        content: ActivityContent(state: state, staleDate: staleDate(state)), pushType: nil)
      shown = true
      keepFresh(state)
    } catch {
      // Off in Settings, or too many activities.
      NSLog("dsh live activity: not started (%@)", String(describing: error))
    }
  }

  @MainActor
  private func holdForResult() {
    guard hold == nil else { return }
    hold = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] timer in
      self?.enqueue { engine in
        // Cancelled after it fired (a newer run came in while this waited in the queue).
        guard engine.hold === timer else { return }
        engine.hold = nil
        await engine.render(engine.latest, art: nil, mayHold: false)
      }
    }
  }

  /// Nothing to show: a finished turn's card stays on the lock screen for a while
  /// (unless the person is looking at the app), anything else goes now. That includes
  /// a card an earlier run of the app left there, which no foreground event will clear.
  @MainActor
  private func finish(_ all: [Activity<DSHLiveAttributes>]) async {
    episode = nil
    dismissed = false
    shown = false
    run = nil
    refresh?.invalidate()
    refresh = nil
    hold?.invalidate()
    hold = nil
    let away = UIApplication.shared.applicationState != .active
    for activity in all {
      switch activity.activityState {
      case .active, .stale:
        let last = activity.content.state
        let keep = away && !last.running
        await activity.end(ActivityContent(state: last, staleDate: nil),
          dismissalPolicy: keep ? .after(Date().addingTimeInterval(15 * 60)) : .immediate)
      case .ended where !away:
        await activity.end(nil, dismissalPolicy: .immediate)
      default:
        break
      }
    }
  }

  private func cameToFront() {
    enqueue { engine in
      // The person is back: a finished turn's card has done its job.
      for activity in Activity<DSHLiveAttributes>.activities where activity.activityState == .ended {
        await activity.end(nil, dismissalPolicy: .immediate)
      }
      // Whatever waited for the front settles now: a card that couldn't start, one
      // held for a result, one whose app was suspended mid-run.
      await engine.render(engine.latest, art: nil)
    }
  }

  /// Renews the stale date while the app runs: iOS marks the card stale only once
  /// the app has been suspended for a couple of minutes.
  @MainActor
  private func keepFresh(_ state: State) {
    guard state.running else {
      refresh?.invalidate()
      refresh = nil
      return
    }
    guard refresh == nil else { return }
    refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      self?.enqueue { engine in
        for activity in Activity<DSHLiveAttributes>.activities
        where activity.activityState == .active || activity.activityState == .stale {
          let state = activity.content.state
          guard state.running else { continue }
          await activity.update(ActivityContent(state: state, staleDate: engine.staleDate(state)))
        }
      }
    }
  }

  private func staleDate(_ state: State) -> Date? {
    state.running ? Date().addingTimeInterval(150) : nil
  }

  /// The content state for a push; nil when there is nothing (or nothing usable) to show.
  private func content(_ args: [String: Any]) -> State? {
    guard let activity = args["activity"] as? [String: Any],
      let kind = activity["kind"] as? String, ["running", "waiting", "done", "failed"].contains(kind),
      let session = activity["sessionId"] as? String, !session.isEmpty, session.count <= 200,
      let host = activity["host"] as? String, host.count <= 512 else { return nil }
    func text(_ value: Any?, _ limit: Int) -> String { String((value as? String ?? "").prefix(limit)) }
    func color(_ value: Any?) -> UInt32? { (value as? NSNumber).map { UInt32(truncatingIfNeeded: $0.int64Value) } }
    let labels = args["labels"] as? [String: Any] ?? [:]
    let started = (activity["sinceMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    // How long it took, from the start it showed while running (the reducer has none once done).
    var since = started, until: Date?
    if kind == "done" || kind == "failed" {
      if let known = run, known.session == session {
        let end = known.until ?? max(Date(), known.since)
        run = (session, known.since, end)
        since = known.since
        until = end
      }
    } else if let started {
      run = (session, started, nil)
    }
    let event = (activity["eventId"] as? String).flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
    let art = args["packId"] is String ? (args["artKey"] as? String).flatMap { $0.count <= 200 ? $0 : nil } : nil
    return State(kind: kind, mood: text(activity["mood"], 24), title: text(activity["title"], 80),
      text: text(activity["text"], 120), chip: text(activity["chip"], 24), since: since, until: until,
      host: host, session: session, event: event, art: art, pixelArt: args["artPixel"] as? Bool ?? false,
      tint: color(args["tint"]) ?? 0xFF6F8FB3, tintDark: color(args["tintDark"]) ?? 0xFF9DB8D9,
      canStop: args["canStop"] as? Bool ?? false,
      stopLabel: text(labels["stop"], 16).isEmpty ? "Stop" : text(labels["stop"], 16),
      staleLabel: text(labels["stale"], 60).isEmpty ? "Not updating" : text(labels["stale"], 60))
  }
}
