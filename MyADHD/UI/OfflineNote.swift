/* ============================================================
   MyADHD/UI/OfflineNote.swift — "these were sorted offline", and the offer
   to do it properly

   app.html:339-341 and `resortLocal` / `settleForOffline` / `dumpLine` /
   `keepDate` / `resortProblem` (app.js:1659-1748).

   The offline parser is good enough to be useful and not good enough to be
   trusted, so the lists say which of the two you are looking at. The note
   appears only while an OPEN task still carries `local === true`, and the
   button is the way to stop it appearing.

   **Re-sorting is a tidy-up, never a delete.** Everything about this
   guards that one promise:

   - The stale tasks go back to the model as *dump text*, day and all
     (`dumpLine`), because the wording that produced the day is long gone
     and re-sorting on a bare title would quietly unpick the one thing the
     offline pass got right.
   - A day that has already been is the one thing not to write down: the
     schema forbids the model to return a past date, and handed a line that
     asks for one it drops the task outright. So an overdue task goes in
     bare and gets its day back from `keepDate` afterwards.
   - Fewer tasks back than went in means one was swallowed and there is no
     telling which, so nothing is written at all — the offline reading
     stands and merely stops calling itself provisional. More back than
     went in is a line split in two; nothing is lost there, so it is taken.
   - An empty answer is the sorter's considered opinion, not a fault on the
     way there: a bare name or a half-written fragment is a line it will
     not turn into a task however many times it is asked. It settles, like
     a short answer does.

   **What a re-sort costs, and the web pays it too.** The fresh tasks are
   new rows with new ids. A quadrant the person dragged, a breakdown, an
   edited title and a hand-written first step all belong to the old id and
   all go. That is `state.tasks.filter(...).concat(fresh)` at app.js:1679,
   and it is the price of being re-read rather than patched.
   ============================================================ */

import SwiftUI

struct OfflineNote: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    /// `el.btnResort.disabled` — one re-sort at a time.
    @State private var sorting = false

    /// `open.filter(t => t.local)`.
    private var stale: [TaskItem] { store.staleLocalTasks }

    var body: some View {
        if !stale.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                sentence
                    .lineSpacing(13.5 * 0.55)
                    .foregroundStyle(theme.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await resort() }
                } label: {
                    Text(sorting ? Copy.OfflineNote.resorting : Copy.OfflineNote.resort)
                        .font(Font.baloo(14, .medium))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(sorting)
                .opacity(sorting ? 0.45 : 1)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(theme.wash)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.lineStrong, lineWidth: 1.5)
            )
            .overlay(alignment: .leading) { theme.orange.frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// `<strong id=offline-count>N</strong> <span id=offline-word>were</span> …`
    private var sentence: Text {
        Text("\(stale.count)")
            .font(Font.baloo(13.5, .bold))
            .foregroundColor(theme.orange)
        + Text(" \(Copy.OfflineNote.word(stale.count)) \(Copy.OfflineNote.body)")
            .font(Font.baloo(13.5))
            .foregroundColor(theme.inkSoft)
    }

    // MARK: - resortLocal (app.js:1660-1699)

    @MainActor
    private func resort() async {
        let stale = self.stale
        guard !stale.isEmpty, !sorting else { return }

        sorting = true
        defer { sorting = false }

        let today = WebDates.dayKey()
        let text = stale.map { Self.dumpLine($0, today: today) }.joined(separator: "\n")

        do {
            /* Not spoken, and no vocabulary: this is text the app wrote
               itself, not something somebody said. */
            var fresh = try await TriageClient().triage(text: text, today: today)

            if fresh.count < stale.count { settle(stale); return }
            if fresh.count == stale.count {
                for i in fresh.indices { Self.keepDate(&fresh[i], was: stale[i]) }
            }

            store.applyResort(staleIDs: stale.map(\.id), fresh: fresh)
            toasts.show(Copy.OfflineNote.resorted)
        } catch let error as TriageError {
            if case .noTasks = error { settle(stale); return }
            toasts.show(Self.problem(error))
        } catch {
            toasts.show(Copy.OfflineNote.problemEmpty)
        }
    }

    /// Keep the offline reading and stop calling it provisional.
    private func settle(_ stale: [TaskItem]) {
        store.settleForOffline(stale.map(\.id))
        toasts.show(Copy.OfflineNote.settled(stale.count))
    }

    /// A stale task written back out as a line of dump text, date and all.
    static func dumpLine(_ t: TaskItem, today: String) -> String {
        guard let when = t.when, !when.isEmpty, !Ordering.jsLess(when, today) else {
            return t.title
        }
        let phrase = WebDates.dayPhrase(when, today: today)
        guard let at = WebDates.timeLabel(t.at) else {
            return "\(t.title) \u{2014} \(phrase)"
        }
        return "\(t.title) \u{2014} \(phrase) at \(at)"
    }

    /// Put back a day the model was never shown. Only ever fills a blank:
    /// if the re-sort found a day of its own, that reading is the better
    /// one.
    static func keepDate(_ fresh: inout TaskItem, was: TaskItem) {
        // `if (fresh.when || !was.when) return;` — both are truthiness tests
        if let f = fresh.when, !f.isEmpty { return }
        guard let w = was.when, !w.isEmpty else { return }
        fresh.when = w
        fresh.at = was.at
    }

    /// Say which way it failed. Every failure used to report the same
    /// thing — that the backend was unreachable — including the ones where
    /// the backend answered and said no, which is the case you most need to
    /// tell apart from a dead connection.
    static func problem(_ error: TriageError) -> String {
        /* `!navigator.onLine`. The monitor starts out assuming a path, so
           this only ever says "offline" about a path it has actually
           seen go. */
        if Reachability.shared.hasObservedPath && !Reachability.shared.isOnline {
            return Copy.OfflineNote.problemOffline
        }
        if let status = error.statusCode {
            return Copy.OfflineNote.problemStatus(String(status))
        }
        if error.isTransport { return Copy.OfflineNote.problemUnreachable }
        return Copy.OfflineNote.problemEmpty
    }
}
