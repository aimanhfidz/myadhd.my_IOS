/* ============================================================
   my.adhd for iOS — the month, and Ink's "Month & Tasks" at large

   The grid is MonthGrid in Shared/, drawn off the per-day counts
   TaskBridge sweeps out of the whole store rather than off the trimmed
   task list — so it stays truthful even when the snapshot had to drop
   things for size.
   ============================================================ */

import WidgetKit
import SwiftUI

struct MonthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.month", provider: DayProvider()) { entry in
            MonthView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "myadhd://open"))
        }
        .configurationDisplayName("Month")
        .description("The month, with a mark on every day your list has something on it.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MonthView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    var body: some View {
        if family == .systemLarge {
            /* Ink calls this one "Month & Tasks". The grid answers "when",
               the rows answer "now", and the two together are the only
               reason to spend a large tile on a calendar. */
            VStack(alignment: .leading, spacing: 10) {
                MonthGrid(snapshot: entry.snapshot, now: entry.date, cellSize: 26)
                Divider()
                TodayList(snapshot: entry.snapshot, now: entry.date, rows: 4) { task in
                    Button(intent: TickIntent(id: task.id)) {
                        TickBox(done: task.done)
                    }
                    .buttonStyle(.plain)
                    .invalidatableContent()
                }
            }
        } else {
            MonthGrid(snapshot: entry.snapshot, now: entry.date, cellSize: 15)
        }
    }
}
