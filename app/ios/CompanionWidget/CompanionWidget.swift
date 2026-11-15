import SwiftUI
import WidgetKit

private struct CompanionEntry: TimelineEntry {
  let date: Date
  let snapshot: CompanionSnapshot
}

private struct CompanionProvider: TimelineProvider {
  func placeholder(in context: Context) -> CompanionEntry {
    CompanionEntry(date: Date(), snapshot: CompanionSnapshot())
  }
  func getSnapshot(in context: Context, completion: @escaping (CompanionEntry) -> Void) {
    completion(CompanionEntry(date: Date(), snapshot: context.isPreview ? CompanionSnapshot() : CompanionSnapshotStore.load()))
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<CompanionEntry>) -> Void) {
    let now = Date()
    let snapshot = CompanionSnapshotStore.load()
    var entries = [CompanionEntry(date: now, snapshot: snapshot)]
    if let until = snapshot.untilMs.map({ Date(timeIntervalSince1970: $0 / 1000) }), until > now {
      entries.append(CompanionEntry(date: until, snapshot: snapshot))
    }
    completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(1800))))
  }
}

private struct CompanionView: View {
  let entry: CompanionEntry
  @Environment(\.widgetFamily) private var family
  private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
  private func words(_ en: String, _ zh: String) -> String { chinese ? zh : en }
  private var background: some View {
    LinearGradient(colors: [Color(red: 0.05, green: 0.20, blue: 0.29), Color(red: 0.10, green: 0.36, blue: 0.40)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "sparkles").font(.title2).foregroundColor(.mint)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.snapshot.name.isEmpty ? words("Companion", "伙伴小屋") : entry.snapshot.name)
            .font(.headline).lineLimit(1)
          Text(entry.snapshot.displayStatus(at: entry.date).isEmpty
            ? words("Come say hello", "来陪我待一会儿") : entry.snapshot.displayStatus(at: entry.date))
            .font(.caption).foregroundColor(.white.opacity(0.8)).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      Spacer(minLength: 0)
      Text(entry.snapshot.line.isEmpty ? words("Tap to visit your companion", "点一下，回到伙伴的小屋") : entry.snapshot.line)
        .font(family == .systemSmall ? .caption : .subheadline)
        .lineLimit(family == .systemSmall ? 3 : 2).privacySensitive()
      HStack(spacing: 3) {
        ForEach(0..<3) { index in
          Image(systemName: index < entry.snapshot.bond ? "heart.fill" : "heart")
        }
        Spacer()
        Text("DSH Go").font(.caption2)
      }.font(.caption2).foregroundColor(.white.opacity(0.65))
    }.foregroundColor(.white).padding(4)
      .widgetURL(URL(string: "dshgo://open/companion"))
  }
  var body: some View {
    if #available(iOS 17.0, *) {
      content.containerBackground(for: .widget) { background }
    } else {
      content.padding(12).background(background)
    }
  }
}

@main
struct DSHCompanionWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: CompanionSnapshotStore.kind, provider: CompanionProvider()) { entry in
      CompanionView(entry: entry)
    }
    .configurationDisplayName("Companion · 伙伴小屋")
    .description("Your companion’s latest words and activity. 查看伙伴的状态，点按回到小屋。")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
