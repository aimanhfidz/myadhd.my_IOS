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

        for (day, n) in fresh where day != today {
            stored[day] = max(stored[day] ?? 0, n)
        }

        /* Today is overwritten whether or not `fresh` mentions it. It used
           to be overwritten only when it did — and `fresh` only has an
           entry for a day with something done on it, so ticking one thing
           off and undoing it left today at 1 for good: the undo emptied
           the store's count and the ledger never heard about it, and the
           square, the streak and "this week" all kept the tick. Absent
           means nothing done today, and that is a number: zero.

           It is also, as a side effect worth having, what marks the first
           day the ledger ran — see `from` below. */
        stored[today] = fresh[today] ?? 0

        let floor = DayKey.adding(-keep, to: today)
        stored = stored.filter { $0.key >= floor && $0.key <= today }
        UserDefaults.standard.set(stored, forKey: key)

        /* From the first day there is anything to say about, not from half
           a year ago regardless. This used to hand back `today - 181`
           every time, so DoneGraph — which sizes itself to the history it
           is given and says "Since <date>" underneath precisely so that it
           never draws months nobody was counting — always got six months,
           always drew eighteen weeks, and always claimed to have been
           counting since the spring, a week after it shipped.

           The earliest key the ledger holds is the honest start: the first
           day it ran (today is always written, above), or earlier when the
           store handed over a week of done tasks or the page's own pruned
           counts on that first run. Capped at `span` as before. `from` is
           counted back from today rather than taken from the key itself,
           so the array always ends on today whatever that key looks like —
           TaskBridge.shrink and TaskSnapshot.completed(on:) both rely on
           the last value being today's.

           An anchored array rather than the dictionary itself: measured,
           the same information costs about a quarter as much once zlib has
           had it, because a run of zeros compresses to nothing and a
           thousand near-identical date strings do not. */
        let reach = stored.keys.min().flatMap { DayKey.between($0, today) } ?? 0
        let count = min(span, max(0, reach) + 1)
        let from = DayKey.adding(-(count - 1), to: today)
        let values = (0..<count).map { stored[DayKey.adding($0, to: from)] ?? 0 }
        return (from, values)
    }
}
