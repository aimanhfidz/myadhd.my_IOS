/* ============================================================
   my.adhd for iOS — today and tomorrow, side by side

   The one tile in Ink's gallery worth copying as it stands. Everything it
   needs was already in the snapshot — TaskBridge has always kept a day
   ahead — and until SnapTask carried `when` there was no way to tell the
   two days apart once they were in there.

   All of the drawing is AgendaPair in Shared/TaskRows.swift, so it can be
   rendered to a PNG without a phone. Read-only on purpose: the checklist
   is where things get ticked, and a tile looking at tomorrow is a tile you
   are planning with rather than working from.
   ============================================================ */

import WidgetKit
import SwiftUI

struct AgendaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.agenda", provider: SnapProvider()) { entry in
            AgendaView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "myadhd://open"))
        }
        .configurationDisplayName("Agenda")
        .description("Today and tomorrow, in two columns, with anything late at the top.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct AgendaView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    var body: some View {
        AgendaPair(snapshot: entry.snapshot,
                   now: entry.date,
                   limit: family == .systemLarge ? 8 : 3,
                   titleSize: family == .systemLarge ? 13 : 12)
    }
}
