/* ============================================================
   my.adhd for iOS — Today, as a list you can actually tick

   Ink's equivalent is a checklist you can only look at; every widget in
   its gallery is a display surface, because a wallpaper cannot have a
   button in it. This one has buttons, and that is the whole argument for
   a widget over the picture they render.

   The rule is paintToday()'s, from app.js, and it is deliberately short:
   anything late, then anything dated today, then whatever is simply open.
   Three at most on the size most people will add — a list of ten is the
   question again, which is the thing this app exists to not do.

   The drawing lives in Shared/TaskRows.swift so it can be rendered to a
   PNG on a Mac. What is here is what cannot be: the family switch, the
   container background, and the tick button.
   ============================================================ */

import WidgetKit
import SwiftUI

struct TodayChecklistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.today", provider: SnapProvider()) { entry in
            TodayChecklistView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("The next few things, and a box to tick when one is done.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayChecklistView: View {

    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    private var small: Bool { family == .systemSmall }

    private var rows: Int {
        switch family {
        case .systemSmall: return 2
        case .systemLarge: return 8
        default: return 3
        }
    }

    var body: some View {
        TodayList(snapshot: entry.snapshot,
                  now: entry.date,
                  rows: rows,
                  titleSize: small ? 12 : 13.5,
                  rowGap: family == .systemLarge ? 11 : 9,
                  rowLines: small ? 2 : 1,
                  showMeta: !small) { task in

            /* The tick, and the only part of this tile that cannot be
               drawn off-device. WidgetKit reloads this widget when
               perform() returns; TickIntent asks for the rest too, so Next
               Up and the band agree with the tile in the same instant.

               invalidatableContent() greys the row for the fraction of a
               second the round trip takes, so a tap being handled does not
               look like a tap that was missed. */
            Button(intent: TickIntent(id: task.id)) {
                TickBox(done: task.done, size: small ? 15 : 17)
            }
            .buttonStyle(.plain)
            .invalidatableContent()
        }
    }
}
