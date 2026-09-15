/* ============================================================
   my.adhd for iOS — the widgets

   Two of them, and one thing between them: what to do next. Next Up says
   it in words, Today Timeline says it in a band. Neither can reach the web
   view — a timeline provider runs in its own process, on iOS's schedule,
   with no app around it — so both read the keychain snapshot the app
   leaves behind. See Shared/TaskSnapshot.swift.

   This target touches neither UserDefaults nor the filesystem, and that is
   deliberate: SecItem* is not a required-reason API, so PrivacyInfo here
   can declare nothing at all. Reaching for a file timestamp or a disk-space
   check would end that and put C617.1 / E174.1 in the manifest.
   ============================================================ */

import WidgetKit
import SwiftUI

// MARK: - the timeline

struct SnapEntry: TimelineEntry {
    let date: Date
    let snapshot: TaskSnapshot?
    /// Set only for the gallery, where a real empty state looks broken.
    let isSample: Bool
}

struct SnapProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapEntry {
        SnapEntry(date: Date(), snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        if context.isPreview {
            completion(SnapEntry(date: Date(), snapshot: .sample, isSample: true))
            return
        }
        completion(SnapEntry(date: Date(), snapshot: TaskStore.read(), isSample: false))
    }

    /* The now-line has to move, and a provider gets called something like
       forty to seventy times a day. The budget is on reloading the
       timeline, not on walking through it — entry.date is readable inside
       the view — so the line's whole journey is encoded as entries and
       costs one call.

       Five minutes for the next two hours, which at this scale is about a
       point and a half a step and reads as continuous. A quarter of an
       hour after that, where nobody is looking closely. */
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let snapshot = TaskStore.read()
        let now = Date()

        var dates: [Date] = [now]
        var t = now
        let fine = now.addingTimeInterval(2 * 60 * 60)
        while t < fine {
            t = t.addingTimeInterval(5 * 60)
            dates.append(t)
        }
        let endOfDay = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        while t < endOfDay && dates.count < 150 {
            t = t.addingTimeInterval(15 * 60)
            dates.append(t)
        }

        let entries = dates.map { SnapEntry(date: $0, snapshot: snapshot, isSample: false) }

        /* Midnight flips the day for free. The six-hour term is for a phone
           nobody opens: a Shortcut or the share extension may have moved
           something without the app ever coming to the front. Fresh data
           otherwise arrives by TaskBridge calling reloadAllTimelines(),
           which is a user-initiated reload and is not rationed. */
        let refresh = min(endOfDay, (snapshot?.generated ?? now).addingTimeInterval(6 * 60 * 60))
        completion(Timeline(entries: entries, policy: .after(max(refresh, now.addingTimeInterval(15 * 60)))))
    }
}

// MARK: - Next Up

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.nextup", provider: SnapProvider()) { entry in
            NextUpView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "myadhd://open"))
        }
        .configurationDisplayName("Next up")
        .description("The next thing, and the two-minute step that starts it.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct NextUpView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    private var task: SnapTask? { entry.snapshot?.next }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(task?.title ?? "Nothing waiting")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "asterisk")
                        .font(.system(size: 11, weight: .bold))
                    Text(task.map { "\($0.minutes)m" } ?? "—")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.snapshot == nil ? "MY.ADHD" : "NEXT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(.secondary)

            if let task {
                Text(task.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .padding(.top, 5)

                if let step = task.firstStep {
                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.top, 4)
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    if task.urgency >= 4 {
                        Circle().fill(CategoryTint.urgent).frame(width: 5, height: 5)
                    }
                    Text(minutesLabel(task.minutes))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if entry.snapshot?.isStale(now: entry.date) == true {
                        Text("· old").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text(emptyLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Three different nothings, and they want three different sentences.
    /// "No tasks" for a snapshot that was never written is a lie about an
    /// app the person has not opened yet.
    private var emptyLine: String {
        guard let snap = entry.snapshot else { return "Open my.adhd once to wake this up." }
        return snap.tasks.isEmpty ? "Head's clear." : "Nothing left in the queue."
    }

    private func minutesLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : String(format: "%.1f hr", Double(m) / 60)
    }
}

// MARK: - Today Timeline

struct TodayTimelineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "myadhd.timeline", provider: SnapProvider()) { entry in
            TodayTimelineView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "myadhd://open"))
        }
        .configurationDisplayName("Today")
        .description("Your day as one band, with a line where you are in it.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

struct TodayTimelineView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapEntry

    var body: some View {
        if family == .accessoryRectangular {
            rectangular
        } else {
            medium
        }
    }

    // MARK: medium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dayLine)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(subLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if entry.snapshot?.isStale(now: entry.date) == true {
                    Text("as of \(shortDay(entry.snapshot!.generated))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if let snap = entry.snapshot, !snap.timed.isEmpty {
                TimelineBand(tasks: snap.tasks, now: entry.date)
                    .opacity(snap.isStale(now: entry.date) ? 0.45 : 1)
            } else {
                emptyBand
            }

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                if let n = entry.snapshot?.untimed.count, n > 0 {
                    chip("\(n) anytime")
                }
                if let d = entry.snapshot?.dropped, d > 0 {
                    chip("+\(d) more")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A band drawn empty rather than a blank tile, so it still reads as a
    /// day with nothing in it and not as something broken.
    private var emptyBand: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineBand(tasks: [], now: entry.date, showTicks: true)
                .opacity(0.25)
            Text(entry.snapshot == nil
                 ? "Open my.adhd once to wake this up."
                 : "Nothing booked in today.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: rectangular

    /// A 160x72pt tile under the clock cannot carry twenty-four hours
    /// legibly, so it carries the six around now instead.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dayLine).font(.system(size: 12, weight: .bold))
            if let snap = entry.snapshot, !snap.timed.isEmpty {
                TimelineBand(tasks: nearby(snap), now: entry.date,
                             laneHeight: 9, laneGap: 2, maxLanes: 2, showTicks: false)
            } else {
                Text(subLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nearby(_ snap: TaskSnapshot) -> [SnapTask] {
        let now = TimelineBand.minutesOfDay(entry.date)
        return snap.tasks.filter { t in
            guard let s = TimelineBand.minutes(of: t.at) else { return false }
            return s + t.minutes >= now - 60 && s <= now + 5 * 60
        }
    }

    // MARK: bits

    private var dayLine: String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, EEEE"
        return f.string(from: entry.date)
    }

    private var subLine: String {
        guard let snap = entry.snapshot else { return "Not set up yet" }
        let open = snap.tasks.filter { !$0.done }.count
        if open == 0 { return "Head's clear" }
        return open == 1 ? "1 thing" : "\(open) things"
    }

    private func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - the bundle

@main
struct MyADHDWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextUpWidget()
        TodayTimelineWidget()
    }
}

// MARK: - the gallery's day

extension TaskSnapshot {
    /// Nobody adds a widget from the gallery that looks broken, so the
    /// preview gets a day rather than an empty state.
    static var sample: TaskSnapshot {
        let mk = { (id: String, title: String, at: String?, mins: Int, cat: String, urg: Int, step: String) in
            SnapTask(id: id, title: title, minutes: mins, at: at, category: cat,
                     energy: "medium", urgency: urg, importance: "high",
                     firstStep: step, done: false)
        }
        return TaskSnapshot(
            generated: Date(),
            day: "2026-09-15",
            tasks: [
                mk("s1", "Submit the expense claim", "09:00", 25, "work", 5,
                   "Open the expenses app and start a new claim."),
                mk("s2", "Pay the electricity bill", "11:30", 10, "money", 5,
                   "Find the bill and read the amount."),
                mk("s3", "Pick up the kids", "15:00", 30, "home", 3,
                   "Put your shoes on."),
                mk("s4", "Renew my passport", nil, 45, "admin", 2,
                   "Search \"passport renewal Malaysia\"."),
            ],
            dropped: 0
        )
    }
}
