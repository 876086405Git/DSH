import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The pet's live activity, drawn from what Runner/IOSLiveActivity.swift tells
/// ActivityKit: the pet doing what DSH does, how long it has been at it, and the one
/// thing that matters when it needs you. One accent from the app's theme; amber only
/// for 等你处理, red only for an error.
@available(iOS 16.2, *)
struct DSHLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DSHLiveAttributes.self) { context in
      LiveLockScreen(state: context.state, stale: context.isStale)
        .widgetURL(context.state.url)
    } dynamicIsland: { context in
      let state = context.state
      let stale = context.isStale
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          LivePet(state: state, height: 44, maxWidth: 58)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          LiveClock(state: state, stale: stale, dark: true, size: 17, compact: false)
            .padding(.trailing, 4)
            .padding(.top, 6)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(state.title.isEmpty ? state.chip : state.title)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(Color.white)
            Text(stale ? state.staleLabel : state.text)
              .font(.system(size: 13))
              .foregroundStyle(Color.white.opacity(0.6))
          }
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          if state.kind == "running" && state.canStop {
            HStack {
              Spacer(minLength: 0)
              LiveStop(state: state, dark: true)
            }
            .padding(.top, 2)
          }
        }
      } compactLeading: {
        LivePet(state: state, height: 22, maxWidth: 30)
      } compactTrailing: {
        LiveCompactStatus(state: state, stale: stale)
      } minimal: {
        LiveMinimal(state: state)
      }
      .widgetURL(state.url)
      .keylineTint(LiveTone.color(state, dark: true))
    }
  }
}

// MARK: - Colour and symbols

@available(iOS 16.2, *)
private enum LiveTone {
  static func color(_ state: DSHLiveAttributes.ContentState, dark: Bool) -> Color {
    switch state.kind {
    case "waiting":
      return dark ? Color(red: 0.96, green: 0.76, blue: 0.47) : Color(red: 0.70, green: 0.45, blue: 0.08)
    case "failed":
      return dark ? Color(red: 0.95, green: 0.58, blue: 0.58) : Color(red: 0.74, green: 0.24, blue: 0.24)
    default:
      return argb(dark ? state.tintDark : state.tint)
    }
  }

  /// What a finished or waiting turn shows where a running one has its clock.
  static func symbol(_ state: DSHLiveAttributes.ContentState) -> String? {
    switch state.kind {
    case "waiting": return "hand.raised.fill"
    case "done": return "checkmark"
    case "failed": return "exclamationmark"
    default: return nil
    }
  }

  private static func argb(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
      blue: Double(value & 0xff) / 255)
  }
}

// MARK: - Pieces

/// The pet, from the still the app left; without one, a quiet symbol in the accent.
@available(iOS 16.2, *)
private struct LivePet: View {
  let state: DSHLiveAttributes.ContentState
  let height: CGFloat
  let maxWidth: CGFloat
  var dark = true
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    if let key = state.art, let data = LiveArtStore.load(key), let image = UIImage(data: data) {
      Image(uiImage: image)
        .resizable()
        .interpolation(state.pixelArt ? .none : .high)
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: maxWidth, maxHeight: height)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "sparkles")
        .font(.system(size: height * 0.62, weight: .medium))
        .foregroundStyle(LiveTone.color(state, dark: dark || scheme == .dark))
        .frame(width: height, height: height)
        .accessibilityHidden(true)
    }
  }
}

/// Counting up while it runs; how long it took once done; else its symbol. Once the
/// app has stopped updating it, a pause: a clock that may have stopped doesn't tick on.
@available(iOS 16.2, *)
private struct LiveClock: View {
  let state: DSHLiveAttributes.ContentState
  let stale: Bool
  let dark: Bool
  let size: CGFloat
  let compact: Bool

  var body: some View {
    Group {
      if stale && state.running {
        Image(systemName: "pause.fill")
          .font(.system(size: size * 0.7, weight: .semibold))
          .accessibilityLabel(state.staleLabel)
      } else if let since = state.since, let until = state.until, since < until {
        Text(timerInterval: since...until, pauseTime: until, countsDown: false, showsHours: !compact)
      } else if let since = state.since, state.running, since < Date.distantFuture {
        Text(timerInterval: since...Date.distantFuture, countsDown: false, showsHours: !compact)
      } else if let symbol = LiveTone.symbol(state) {
        Image(systemName: symbol)
      }
    }
    .font(.system(size: size, weight: .medium, design: .rounded))
    .monospacedDigit()
    .multilineTextAlignment(.trailing)
    .foregroundStyle(LiveTone.color(state, dark: dark))
    .opacity(stale ? 0.45 : 1)
    .lineLimit(1)
  }
}

/// The collapsed island's right side: the clock while it works, 待确认 / 待回答 in amber
/// when it waits on you, a mark once it is over, a pause once the app can't update it.
@available(iOS 16.2, *)
private struct LiveCompactStatus: View {
  let state: DSHLiveAttributes.ContentState
  let stale: Bool

  var body: some View {
    if stale && state.running {
      Image(systemName: "pause.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.55))
        .accessibilityLabel(state.staleLabel)
    } else if state.kind == "waiting" {
      Text(state.chip)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(LiveTone.color(state, dark: true))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: 52, alignment: .trailing)
    } else {
      LiveClock(state: state, stale: false, dark: true, size: 13, compact: true)
        .frame(width: 42, alignment: .trailing)
        .accessibilityLabel(state.chip)
    }
  }
}

/// When several apps share the island: the pet alone, with an amber dot when it needs you.
@available(iOS 16.2, *)
private struct LiveMinimal: View {
  let state: DSHLiveAttributes.ContentState

  var body: some View {
    LivePet(state: state, height: 20, maxWidth: 24)
      .overlay(alignment: .topTrailing) {
        if state.kind == "waiting" || state.kind == "failed" {
          Circle()
            .fill(LiveTone.color(state, dark: true))
            .frame(width: 6, height: 6)
            .offset(x: 2, y: -1)
        }
      }
      .accessibilityLabel(state.chip)
  }
}

/// 停止: ends the turn without opening the app (iOS 17 and later).
@available(iOS 16.2, *)
private struct LiveStop: View {
  let state: DSHLiveAttributes.ContentState
  let dark: Bool

  var body: some View {
    if #available(iOS 17.0, *) {
      Button(intent: DSHLiveStopIntent(host: state.host, session: state.session)) {
        Label(state.stopLabel, systemImage: "stop.fill")
          .labelStyle(.titleAndIcon)
          .font(.system(size: 13, weight: .semibold))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Capsule().fill(dark ? Color.white.opacity(0.14) : Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .foregroundStyle(dark ? Color.white.opacity(0.9) : Color.primary)
    }
  }
}

/// The lock screen: the pet, what it is doing and for how long. No conversation title
/// here, only the words that are safe for whoever holds the phone.
@available(iOS 16.2, *)
private struct LiveLockScreen: View {
  let state: DSHLiveAttributes.ContentState
  let stale: Bool
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    HStack(alignment: .center, spacing: 14) {
      LivePet(state: state, height: 46, maxWidth: 60, dark: dark)
        .frame(width: 60, height: 50)
      VStack(alignment: .leading, spacing: 3) {
        Text(state.text)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.primary)
        Text(stale && state.running ? state.staleLabel : "DSH Go")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 8) {
        LiveClock(state: state, stale: stale, dark: dark, size: 20, compact: false)
        if state.kind == "running" && state.canStop {
          LiveStop(state: state, dark: dark)
        }
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }
}
