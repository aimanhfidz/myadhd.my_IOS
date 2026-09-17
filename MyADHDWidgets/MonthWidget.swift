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
        .description("Where you are in the month, and the next thing on the right.")
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
                /* 22pt cells and three rows, not 26 and four: six grid rows
                   plus a header, a divider, a list and its footer have to
                   share 324pt, and the larger version clipped the month name
                   off the top and the footer off the bottom. */
                MonthGrid(snapshot: entry.snapshot, now: entry.date, cellSize: 22)
                Divider()
                TodayList(snapshot: entry.snapshot, now: entry.date, rows: 3) { task in
                    Button(intent: TickIntent(id: task.id)) {
                        TickBox(done: task.done)
                    }
                    .buttonStyle(.plain)
                    .invalidatableContent()
                }
            }
        } else {
            /* Google Calendar's shape: grid left, what is next right. The
               dotted full-width grid it replaces answered "when" and left
               half the tile saying nothing about "now". */
            MonthWithNext(snapshot: entry.snapshot, now: entry.date)
        }
    }
}
