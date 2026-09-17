/* ============================================================
   my.adhd for iOS — pushing the list out to where a widget can see it

   Reminders.sync() already asks the page for localStorage at the four
   moments the shell gets one: first paint, every debounced write, on the
   way out, and on the way back. This rides on that read rather than
   adding a second round trip — one evaluateJavaScript, two consumers.

   Where it sits inside Reminders.sync matters and is easy to get wrong.
   It goes ABOVE the notification-permission gate: sync() abandons the
   rest of the chain when the user has declined notifications, and a
   widget has nothing to do with notifications. Put it below and the
   widget quietly stays empty for everyone who said no to the prompt.
   ============================================================ */

import Foundation
import UIKit
import WidgetKit

enum TaskBridge {

    /// Today and tomorrow. A widget cannot show more than a day and a
    /// wallpaper should not try, so the rest is weight for nothing.
    private static let daysAhead = 1

    /// Long enough to read on a tile, short enough that sixty of them fit
    /// in the budget.
    /* The month grid draws six weeks and has to stay right after midnight
       on the 1st, when the widget's own clock has rolled into a month this
       snapshot was not written for. So: back far enough to cover the
       leading cells of this month's grid, forward far enough to cover the
       trailing cells of next month's. Measured at 58 compressed bytes. */
    private static let calBack = 10
    private static let calSpan = 77

    private static let titleMax = 64
    private static let stepMax = 96
    private static let taskMax = 64

    /// What was last written, so an unchanged store costs nothing. Typing
    /// in the composer writes myadhd.v1 on a 1.5s debounce and none of
    /// those writes change a single thing a widget draws.
    private static let stampKey = "myadhd.snapshot.stamp"

    // MARK: - the one entry point

    static func write(from json: String?) {
        /* No page, no answer, unparseable, or a store with no tasks key —
           none of those is "the list is empty". Clearing on any of them
           would blank the widget every cold launch, because the first read
           happens before the page has painted. */
        guard let json,
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["tasks"] as? [[String: Any]]
        else { return }

        let snapshot = build(from: raw)
        guard var blob = TaskStore.encode(snapshot) else { return }

        var shrunk = snapshot
        var guard_ = 0
        while blob.count > TaskStore.budget && guard_ < 6 {
            shrunk = shrink(shrunk, round: guard_)
            guard let next = TaskStore.encode(shrunk) else { return }
            blob = next
            guard_ += 1
        }

        /* A hash of what would be written, not of the store. Two stores
           that differ only in a field no widget draws produce the same
           stamp and cost one comparison instead of a keychain round trip
           and a reload of every timeline.

           Not hashValue: Swift seeds its hasher per process, so a stamp
           written before a relaunch never matches the one computed after
           one, and every cold launch paid for a keychain write and a
           reload of every timeline it was supposed to save. */
        let stamp = digest(blob)
        if UserDefaults.standard.string(forKey: stampKey) == stamp { return }

        guard TaskStore.write(shrunk) else { return }
        UserDefaults.standard.set(stamp, forKey: stampKey)

        /* Only on a real change, and only ever just after the user was in
           the app — which is a user-initiated reload, not one of the
           rationed background ones. */
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - building it

    private static func build(from raw: [[String: Any]]) -> TaskSnapshot {
        let today = dayKey(Date())
        let horizon = dayKey(Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date())

        var kept: [SnapTask] = []

        /* Counted over the whole store, in this same pass, and before any
           of the trimming below. A month grid built from `kept` would
           under-count every day past tomorrow and lose the rest entirely
           once the cap bit — it would be wrong quietly, which is the worst
           way for a calendar to be wrong. */
        let calFrom = DayKey.adding(-calBack, to: today)
        var cal = [Int](repeating: 0, count: calSpan)
        var doneToday = 0

        /* The week of doneAt stamps the store can still see. DoneLedger
           folds it into everything remembered from before, because
           pruneDone() will have thrown these away by next Tuesday. */
        var finished: [String: Int] = [:]

        for task in raw {
            guard let id = task["id"] as? String,
                  let title = task["title"] as? String else { continue }
            if task["skipped"] as? Bool == true { continue }

            let done = task["done"] as? Bool == true
            let day = task["when"] as? String

            /* Ticked off today, counted here rather than off the snapshot:
               build() drops a done-and-undated task a few lines below, and
               one of those is still a thing the person did today. */
            if done, let on = doneDay(task, fallback: day) {
                finished[on, default: 0] += 1
                if on == today { doneToday += 1 }
            }

            if !done, let day, let i = DayKey.between(calFrom, day), i >= 0, i < calSpan {
                cal[i] += 1
            }

            /* Undated tasks come too: the widget counts them as "N
               anytime" and the wallpaper's next-up falls back to them
               when nothing is booked. What is dropped is another day's
               business — anything dated past tomorrow, and anything
               already ticked off on a day that is not today. */
            if let day {
                if day > horizon { continue }
                if done && day != today { continue }
            } else if done {
                continue
            }

            kept.append(SnapTask(
                id: id,
                title: clip(title, titleMax),
                minutes: min(240, max(2, (task["minutes"] as? Int) ?? 20)),
                when: day,
                at: day == nil ? nil : task["at"] as? String,
                category: (task["category"] as? String) ?? "general",
                energy: (task["energy"] as? String) ?? "medium",
                urgency: min(5, max(1, (task["urgency"] as? Int) ?? 3)),
                importance: task["importance"] as? String,
                firstStep: (task["firstStep"] as? String).map { clip($0, stepMax) },
                done: done
            ))
        }

        /* Booked things first and in clock order, then everything else by
           how much it is pressing. That is also the order the cap cuts
           from the bottom of, so what falls off is what mattered least. */
        kept.sort { a, b in
            let ka = a.at ?? "99:99", kb = b.at ?? "99:99"
            if ka != kb { return ka < kb }
            if a.urgency != b.urgency { return a.urgency > b.urgency }
            return a.minutes < b.minutes
        }

        let history = DoneLedger.merge(finished, today: today)

        let dropped = max(0, kept.count - taskMax)
        return TaskSnapshot(
            generated: Date(),
            day: today,
            tasks: Array(kept.prefix(taskMax)),
            dropped: dropped,
            doneToday: doneToday,
            calFrom: calFrom,
            cal: cal,
            histFrom: history.from,
            hist: history.values
        )
    }

    /// The day a task was finished on. `doneAt` is a JSON number, so it
    /// arrives as NSNumber and a null arrives as NSNull; falling back to
    /// `when` covers a store written before markDone stamped anything.
    private static func doneDay(_ task: [String: Any], fallback: String?) -> String? {
        if let ms = (task["doneAt"] as? NSNumber)?.doubleValue, ms > 0 {
            return dayKey(Date(timeIntervalSince1970: ms / 1000))
        }
        return fallback
    }

    /// Only reached by a list long enough to blow the budget, which the
    /// caps above should already have prevented. Gives up the first step
    /// before it gives up tasks, because a task the widget cannot name at
    /// all is worse than one it cannot tell you how to start.
    private static func shrink(_ s: TaskSnapshot, round: Int) -> TaskSnapshot {
        if round == 0 {
            let stripped = s.tasks.map {
                SnapTask(id: $0.id, title: $0.title, minutes: $0.minutes, when: $0.when, at: $0.at,
                         category: $0.category, energy: $0.energy, urgency: $0.urgency,
                         importance: $0.importance, firstStep: nil, done: $0.done)
            }
            return s.with(tasks: stripped)
        }
        /* Half a year of history is a nice-to-have and a task is not, so
           the graph gets cut back to two months before a single row of the
           list goes. In practice neither happens — a full snapshot with
           everything in it measures under two kilobytes against a sixteen
           kilobyte budget — but the order matters if it ever does. */
        if round == 1, s.hist.count > 56 {
            let keep = Array(s.hist.suffix(56))
            return TaskSnapshot(generated: s.generated, day: s.day, tasks: s.tasks,
                                dropped: s.dropped, doneToday: s.doneToday,
                                calFrom: s.calFrom, cal: s.cal,
                                histFrom: DayKey.adding(-(keep.count - 1), to: s.day),
                                hist: keep)
        }

        let half = max(4, s.tasks.count / 2)
        return s.with(tasks: Array(s.tasks.prefix(half)),
                      dropped: s.dropped + (s.tasks.count - half))
    }

    /* Stable across launches, which hashValue is not. FNV-1a rather than a
       digest from CryptoKit: this is a change detector, not a checksum
       anybody is defending, and it wants no import. */
    private static func digest(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }

    // MARK: - bits

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    /// The same "YYYY-MM-DD" in the device's own zone that app.js writes.
    /// Lives in Shared/TaskSnapshot.swift now, because the widgets need the
    /// same arithmetic; kept here as a name the rest of the app already calls.
    static func dayKey(_ date: Date) -> String { DayKey.of(date) }
}
