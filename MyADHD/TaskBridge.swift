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
           and a reload of every timeline. */
        let stamp = String(blob.hashValue)
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

        for task in raw {
            guard let id = task["id"] as? String,
                  let title = task["title"] as? String else { continue }
            if task["skipped"] as? Bool == true { continue }

            let done = task["done"] as? Bool == true
            let day = task["when"] as? String

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

        let dropped = max(0, kept.count - taskMax)
        return TaskSnapshot(
            generated: Date(),
            day: today,
            tasks: Array(kept.prefix(taskMax)),
            dropped: dropped
        )
    }

    /// Only reached by a list long enough to blow the budget, which the
    /// caps above should already have prevented. Gives up the first step
    /// before it gives up tasks, because a task the widget cannot name at
    /// all is worse than one it cannot tell you how to start.
    private static func shrink(_ s: TaskSnapshot, round: Int) -> TaskSnapshot {
        if round == 0 {
            let stripped = s.tasks.map {
                SnapTask(id: $0.id, title: $0.title, minutes: $0.minutes, at: $0.at,
                         category: $0.category, energy: $0.energy, urgency: $0.urgency,
                         importance: $0.importance, firstStep: nil, done: $0.done)
            }
            return TaskSnapshot(generated: s.generated, day: s.day, tasks: stripped, dropped: s.dropped)
        }
        let half = max(4, s.tasks.count / 2)
        return TaskSnapshot(
            generated: s.generated,
            day: s.day,
            tasks: Array(s.tasks.prefix(half)),
            dropped: s.dropped + (s.tasks.count - half)
        )
    }

    // MARK: - bits

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    /// The same "YYYY-MM-DD" in the device's own zone that app.js writes.
    /// Not ISO8601 with a Z on it: the web app's days are local days.
    static func dayKey(_ date: Date) -> String {
        let p = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }
}
