/* ============================================================
   my.adhd for iOS — a timeline for the tiles with no now-line in them

   SnapProvider spends up to 150 entries walking a moving now-line through
   the day, which is exactly right for the band and pure waste for a month
   grid or a contribution grid. Neither of those changes between one
   midnight and the next.

   Same read, same overlay, different schedule.
   ============================================================ */

import WidgetKit
import Foundation

struct DayProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapEntry {
        SnapEntry(date: Date(), snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapEntry) -> Void) {
        if context.isPreview {
            completion(SnapEntry(date: Date(), snapshot: .sample, isSample: true))
            return
        }
        completion(SnapEntry(date: Date(), snapshot: SnapProvider.current(), isSample: false))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        let (snapshot, retry) = SnapProvider.read()

        /* Two entries: now, and the moment the date changes. The second is
           what rolls the grid over to a new month at 00:00 without waiting
           for anybody to open the app. Fresh data otherwise arrives by
           TaskBridge calling reloadAllTimelines().

           Unless the read failed. Midnight is the right next wake for a
           grid that has its data and the wrong one for a grid that could
           not get it: a phone rebooted at three and unlocked at seven would
           otherwise show an empty month and an empty done graph until
           midnight, or until somebody happened to open the app.
           SnapProvider.read() says how soon to ask again. */
        let next = retry.map { min(midnight, now.addingTimeInterval($0)) } ?? midnight
        completion(Timeline(
            entries: [SnapEntry(date: now, snapshot: snapshot, isSample: false),
                      SnapEntry(date: midnight, snapshot: snapshot, isSample: false)],
            policy: .after(next)
        ))
    }
}
