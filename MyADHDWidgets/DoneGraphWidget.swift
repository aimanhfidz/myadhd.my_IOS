/* ============================================================
   my.adhd for iOS — the one tile that looks backwards

   Everything else here is about what is next. This is the opposite, and
   it is the only place in the app where finishing things accumulates into
   anything. Deliberately not a streak you can break: the number goes up
   and never scolds, there is no target, and a quiet week draws quiet
   rather than red.

   See Shared/DoneGraph.swift for why it is not green, and why the header
   names the date it is counting from.
   ============================================================ */

import WidgetKit
import SwiftUI

struct DoneGraphWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.done", provider: DayProvider()) { entry in
            DoneGraphView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "myadhd://open"))
        }
        .configurationDisplayName("Done")
        .description("Everything you have finished, one square a day.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct DoneGraphView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    var body: some View {
        if family == .systemLarge {
            VStack(alignment: .leading, spacing: 12) {
                DoneGraph(snapshot: entry.snapshot, now: entry.date, weeks: 18, cell: 15, gap: 3.5)
                Spacer(minLength: 0)
            }
        } else {
            DoneGraph(snapshot: entry.snapshot, now: entry.date, weeks: 18, cell: 12, gap: 3)
        }
    }
}
