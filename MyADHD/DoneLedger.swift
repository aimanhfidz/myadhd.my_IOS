/* ============================================================
   my.adhd for iOS — remembering what the web app forgets

   pruneDone() in app.js deletes any finished task more than DONE_TTL —
   seven days — old, on every startup. That is the right call for a list
   nobody wants to scroll, and it means the store can never hand over more
   than a week of history. A contribution grid needs months.

   So the shell keeps its own tally: one small integer per day, in
   UserDefaults, merged from the seven days the store can still see. It
   accrues from the day this shipped and it cannot be backfilled — a
   fortnight away from the app leaves a real hole, because the days that
   would have filled it were pruned before anybody looked.

   The alternative is a change to the website — either a longer DONE_TTL,
   or a counter that pruneDone() increments before it deletes — and that
   is a decision about the website, not a step in an iOS task. It is
   written up in ios/README.md rather than done here.

   UserDefaults is fine in THIS target: MyADHD/PrivacyInfo.xcprivacy
   already declares CA92.1. It would not be fine in MyADHDWidgets, whose
   manifest declares nothing at all — which is why the widget reads this
   out of the snapshot and never touches the ledger.
   ============================================================ */

import Foundation

enum DoneLedger {

    private static let key = "myadhd.done.ledger"

    /// Long enough to outlive anything a tile draws, short enough that the
    /// defaults entry stays a couple of kilobytes.
    private static let keep = 400

    /// What a tile is allowed to draw, which is about half a year. A
    /// medium tile fits eighteen weeks and a large one thirty.
    static let span = 182

    /// Folds today's view of the world into what was already known, and
    /// hands back the window the snapshot should carry.
    ///
    /// `max` for every past day and a straight overwrite for today: an
    /// undo on Tuesday should not quietly lower Tuesday's square days
    /// later, but an undo this morning should still count. This is a
    /// morale object, not an audit log, and that is the right trade.
    static func merge(_ fresh: [String: Int], today: String) -> (from: String, values: [Int]) {
        var stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]

        for (day, n) in fresh {
            stored[day] = day == today ? n : max(stored[day] ?? 0, n)
        }

        let floor = DayKey.adding(-keep, to: today)
        stored = stored.filter { $0.key >= floor && $0.key <= today }
        UserDefaults.standard.set(stored, forKey: key)

        /* An anchored array rather than the dictionary itself: measured,
           the same information costs about a quarter as much once zlib has
           had it, because a run of zeros compresses to nothing and a
           thousand near-identical date strings do not. */
        let from = DayKey.adding(-(span - 1), to: today)
        let values = (0..<span).map { stored[DayKey.adding($0, to: from)] ?? 0 }
        return (from, values)
    }
}
