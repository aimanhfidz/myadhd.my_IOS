/* ============================================================
   MyADHDWidgets/MatrixWidget.swift — the four boxes, on the home screen

   Ink has four widgets built around the matrix; this app had the matrix
   screen and the matrix wallpaper and no tile. Medium shows the top task
   in each box, large shows two and a "+N more". Every row can be ticked,
   through the same TickIntent as the Today tile, because a picture of a
   list you cannot act on is the wallpaper again.

   **Where a task lands** is `SnapTask.quadrant(on:)`, the app's own
   `quadrantOf`: a box the person chose wins, otherwise urgency and
   importance decide. Inside a box the order is the snapshot's, which is
   the Next Up order — the same one the app's Now card leads with.

   **What the counts can see.** The snapshot carries open tasks up to its
   horizon (TaskBridge `daysAhead`) and drops the least pressing past its
   size budget, so a box's count is what is on this phone's copy of the
   list, not the store. Far-off dated tasks land in Plan and Drop, the two
   boxes where an undercount costs least.

   Colours: the matrix's sanctioned four (BRAND.md §11.3, QuadrantCell.swift
   `QuadrantPalette`), the label in ink because orange as text on a light
   ground is never allowed (§3.3); the hue rides on the tick circle.
   ============================================================ */

import AppIntents
import SwiftUI
import WidgetKit

struct MatrixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.matrix", provider: SnapProvider()) { entry in
            MatrixView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Matrix")
        .description("Do now, Plan, Delegate, Drop — and a box to tick when one is done.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MatrixView: View {

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: SnapEntry

    private var perBox: Int { family == .systemLarge ? 2 : 1 }

    private static let boxes: [(key: String, label: String)] = [
        ("do", "Do now"), ("plan", "Plan"), ("delegate", "Delegate"), ("drop", "Drop"),
    ]

    var body: some View {
        if let snap = entry.snapshot {
            let today = snap.effectiveDay(entry.date)
            let open = snap.ordered(now: entry.date)
            let rows = [Array(Self.boxes[0..<2]), Array(Self.boxes[2..<4])]
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(rows[r], id: \.key) { box in
                            cell(box.key, box.label,
                                 open.filter { $0.quadrant(on: today) == box.key })
                        }
                    }
                }
            }
        } else {
            Text("Open my.adhd once to wake this up.")
                .font(.baloo(13, .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cell(_ key: String, _ label: String, _ items: [SnapTask]) -> some View {
        let hue = MatrixHue.hue(key, dark: scheme == .dark)
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 7 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.baloo(12, .heavy))
                Spacer(minLength: 4)
                Text(String(items.count))
                    .font(.baloo(11.5, .bold))
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(perBox)) { task in
                HStack(spacing: 6) {
                    Button(intent: TickIntent(id: task.id)) {
                        Circle()
                            .strokeBorder(hue, lineWidth: 2)
                            .frame(width: 13, height: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .invalidatableContent()

                    Text(task.title)
                        .font(.baloo(12.5, .semibold))
                        .lineLimit(1)
                }
            }
            if items.count > perBox, family == .systemLarge {
                Text("+\(items.count - perBox) more")
                    .font(.baloo(11.5, .bold))
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("Nothing here")
                    .font(.baloo(11.5, .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MatrixHue.wash(key, dark: scheme == .dark),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

/// QuadrantPalette's table, for a process that cannot see the app's
/// files. The two must stay value for value; QuadrantCell.swift is the
/// original and BRAND.md §3.1 names the green.
enum MatrixHue {

    static func hex(_ key: String, dark: Bool) -> UInt32 {
        switch key {
        case "do":       return dark ? 0xFF8A7E : 0xD92D20
        case "plan":     return dark ? 0xA97BFF : 0x7B3FE4
        case "delegate": return 0xF75C03
        case "drop":     return dark ? 0x4CC47A : 0x1F8A45
        default:         return dark ? 0xF3F2FB : 0x101018
        }
    }

    static func hue(_ key: String, dark: Bool) -> Color { color(hex(key, dark: dark)) }

    /// 13% of the hue on `--surface`, 14% for Delegate — the app's wash.
    static func wash(_ key: String, dark: Bool) -> Color {
        let share = key == "delegate" ? 0.14 : 0.13
        let a = hex(key, dark: dark), b: UInt32 = dark ? 0x101018 : 0xFFFFFF
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        func mix(_ s: UInt32) -> Double { (ch(a, s) * share + ch(b, s) * (1 - share)) / 255 }
        return Color(red: mix(16), green: mix(8), blue: mix(0))
    }

    private static func color(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}
