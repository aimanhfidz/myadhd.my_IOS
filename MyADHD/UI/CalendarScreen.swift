/* ============================================================
   MyADHD/UI/CalendarScreen.swift — the month, the day, and what is on it

   `showCalendar` and `renderCalendar` (app.js:2268-2376), the shell's
   four-way pill (BridgeScript.swift:786-1087), inventory §1.8 and §1.18.

   **The calendar reads, and moves one thing.** It used to only read:
   nothing here changed a day, a time or a title, and what a row could do
   was what a row on the lists can do — tick, swipe, undo. That rule was
   never about days being sacred. It was about not growing a second,
   quieter editor beside the real one, where a task could be half-changed
   somewhere nobody thinks of as a place that changes tasks.

   What has been added since is **dragging a task out of the agenda onto a
   day in the grid**, and it is allowed for the same reasons the rule was
   written to protect:

   - it is a gesture, not a form — no field, no sheet, and no second path
     to the same change;
   - moving a task to a day is the *whole* of what it can do, and the day
     it lands on is the day you dropped it on;
   - it says what it did and offers an Undo, like every other commit here;
   - a finished task refuses, so it cannot rewrite what already happened.

   Anything past that — a time, a title, a duration — still belongs to the
   editor and not to this screen. See `MonthTaskDrag`.

   **Two pieces of state, and neither is data.** `calPicked` is the day
   you are looking at and `calCursor` is the month on screen. The web
   keeps them in module variables, which survive a tab switch and die on a
   reload; `CalendarSession` is that, natively — `myadhd.native.*` in
   UserDefaults so they outlive a view being rebuilt, stamped with a
   per-launch id so a cold start still lands on today the way a fresh page
   load does. They are deliberately NOT on the document: a synced "which
   day am I looking at" would drag another device's cursor around.

   **`Back to today` hides only when BOTH are today's** — the picked day
   and the visible month. Picking the 3rd of next month and paging back to
   this one leaves the button up, because the day you are reading about is
   still over there.

   **The four views are the shell's.** List, Day and Week exist nowhere on
   the web; they would have gone with the web view. The pill keeps the
   month header above it in every one of them, which is what the shell's
   CSS does — `myadhd-view-*` hides the grid, the agenda and `Back to
   today`, and never `.cal-head`. The chosen view is remembered under
   `myadhd.native.calView`, which `LegacyImport` has already filled from
   the old `myadhd.ios.calView` in the page's localStorage.
   ============================================================ */

import SwiftUI

// MARK: - where you are looking

/// `calCursor` and `calPicked`. See the file header for why UserDefaults
/// and why a launch stamp.
@MainActor
@Observable
final class CalendarSession {

    static let pickedKey = "myadhd.native.calPicked"
    static let cursorKey = "myadhd.native.calCursor"
    /// Which run of the app wrote the two above. A different value means a
    /// different launch, and the pair is then treated as the null the web
    /// starts every page load with.
    static let sessionKey = "myadhd.native.calSession"

    private static let launch = UUID().uuidString

    private(set) var picked: String
    private(set) var cursor: MonthRef

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, today: String = WebDates.dayKey()) {
        self.defaults = defaults

        let sameRun = defaults.string(forKey: Self.sessionKey) == Self.launch
        let storedDay = sameRun ? defaults.string(forKey: Self.pickedKey) : nil
        let storedMonth = sameRun ? defaults.string(forKey: Self.cursorKey) : nil

        /* `if (!calPicked) calPicked = today;
            if (!calCursor) calCursor = keyToDate(calPicked.slice(0, 8) + '01');` */
        let day = storedDay.flatMap { WebDates.keyToDate($0) == nil ? nil : $0 } ?? today
        self.picked = day
        self.cursor = storedMonth.flatMap(MonthRef.init(key:)) ?? MonthRef(dayKey: day)

        defaults.set(Self.launch, forKey: Self.sessionKey)
        persist()
    }

    /// A cell was tapped.
    func pick(_ key: String) {
        picked = key
        persist()
    }

    /// `stepMonth(n)`.
    ///
    /// **`carryingDay` is what the arrows above Day, Week and List need.**
    /// Only the month grid reads `cursor`; the other three panes are all
    /// drawn from `picked`, so moving the month alone changed the words in
    /// the header and nothing underneath them. The day of the month comes
    /// across with it — the 18th of September steps to the 18th of October
    /// — clamped to the new month's length, so the 31st of January steps to
    /// the 28th of February rather than off the end of it.
    ///
    /// Month mode passes false and keeps the two apart, which is the web's
    /// own arrangement: there `picked` is the highlighted cell and the day
    /// the agenda under the grid is about, and paging the grid past it is
    /// the whole point of `Back to today`. It is also what `MonthPager`'s
    /// swipe does, and an arrow that behaved differently from a swipe on
    /// the same grid would be the worse bug.
    func step(_ n: Int, carryingDay: Bool = false) {
        let next = cursor.adding(n)
        if carryingDay {
            let day = Int(picked.suffix(2)) ?? 1
            picked = next.dayKey(min(day, next.days))
        }
        cursor = next
        persist()
    }

    func show(_ month: MonthRef) {
        cursor = month
        persist()
    }

    /// `#cal-today` — the day AND the month, together.
    func backToToday(_ today: String) {
        picked = today
        cursor = MonthRef(dayKey: today)
        persist()
    }

    /// Hidden exactly when there is nowhere to go back to.
    func isOnToday(_ today: String) -> Bool {
        picked == today && cursor == MonthRef(dayKey: today)
    }

    private func persist() {
        defaults.set(picked, forKey: Self.pickedKey)
        defaults.set(cursor.key, forKey: Self.cursorKey)
    }
}

// MARK: - the screen

struct CalendarScreen: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter

    var today: String = WebDates.dayKey()

    /// Whether this screen draws its own header — the name and the pill.
    /// False where something above it has already put them on screen.
    var showsTools: Bool = true

    @State private var session = CalendarSession()
    @State private var mode = CalMode.remembered

    /// The sideways swipe's travel, and its guard against a second one
    /// landing mid-glide. Both used to live inside the panes; they are up
    /// here because the day header is up here too, and the column head has
    /// to travel with the columns it names.
    @State private var dx: CGFloat = 0
    @State private var busy = false

    /// The month grid's press-and-hold. Owned here rather than by the
    /// pager, because the scroller that has to stand down while a day is
    /// being scrubbed is this screen's.
    @State private var monthDrag = MonthDrag()

    /// And dragging a task out of the agenda onto one of those days. Two
    /// gestures over one set of cell frames: this one starts on a row,
    /// the one above starts on a cell.
    @State private var taskDrag = MonthTaskDrag()

    private var tasks: [TaskItem] { store.doc.tasks }

    /// `!done && !when` — on no day at all, and so on no calendar.
    private var undated: Int {
        tasks.filter { !$0.done && !(($0.when.map { !$0.isEmpty }) ?? false) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTools {
                ScreenHeader(title: Copy.ScreenTitle.calendar) {
                    CalModePill(mode: $mode)
                }
            }

            /* `.cal-head` stays up in all four views — the shell hides the
               grid, the agenda and Back to today, never the month row. */
            monthHead
                .padding(.bottom, 16)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        /* Somewhere to send Month and List, which have no
                           hour to settle on. Zero-height and invisible —
                           it exists to be an anchor. */
                        Color.clear
                            .frame(height: 0)
                            .id(Self.topAnchor)

                        switch mode {
                        case .month: monthView
                        case .list:  listView
                        case .day:   CalDayPane(tasks: tasks, today: today,
                                                session: session, dx: $dx)
                        case .week:  CalColumnsPane(tasks: tasks, today: today,
                                                    session: session, dx: $dx)
                        }
                    }
                    .frame(maxWidth: Theme.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.hidden)
                /* Once a day is airborne the finger belongs to the grid.
                   The 320ms hold and its 8pt of slop mean a flick was
                   already read as a scroll and called the lift off, so
                   this only ever bites after the gesture has committed. */
                .scrollDisabled(monthDrag.isDragging || taskDrag.isDragging)
                /* **The day header does not scroll.** On the web it was
                   `position: sticky` (reference/BridgeScript.swift:361-362)
                   and the port put it in the scroller instead, so the one
                   control that says which day you are on — and the only way
                   to change it without a swipe — went off the top the
                   instant `settleScroll` jumped to the working hours, and
                   never came back on its own.

                   A `safeAreaInset` is that stickiness: the header sits
                   above the content, does not move, and the scroll view
                   insets itself under it — which also means `scrollTo`'s
                   `.top` anchor now lands *below* the header rather than
                   behind it. That second half is the web's too: it scrolled
                   by `target - under`, where `under` was the bottom edge of
                   the stuck strip (reference/BridgeScript.swift:986-1000). */
                .safeAreaInset(edge: .top, spacing: 0) { dayHeader }
                /* `settleScroll` — the working hours, found once on the way
                   into the view. Keyed on the view alone: swiping to another
                   day, or tapping one on the strip, keeps the hour you were
                   looking at, which is what makes the strip worth having. */
                .onChange(of: mode) { _, next in findWorkingHours(proxy, next) }
                .onAppear { findWorkingHours(proxy, mode) }
            }
            /* The swipe is on the scroller rather than inside the pane, so
               that a finger starting on the pinned header moves the days
               too — it is the same gesture over what is visually one view. */
            .modifier(CalSideSwipe(step: swipeStep, session: session,
                                   dx: $dx, busy: $busy))
        }
        .padding(.horizontal, 20)
        /* `.cal-wrap{padding-top:clamp(6px,1.5vh,16px)}` is the header's
           own `.padding(.top, 10)` now, so the four tabs' titles line up. */
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.surface.ignoresSafeArea())
    }

    /// What stays on screen above the hours: a week of days to pick from
    /// on the Day view, the column names on the columned one, and nothing
    /// at all on Month and List, which have no hours to scroll past.
    ///
    /// The strip does not travel with a swipe — "the strip is the frame
    /// the days move inside", which is `CalWeekStrip`'s own description of
    /// itself. The column head does, because it names the columns and
    /// would otherwise be a row of wrong dates for the length of a glide.
    @ViewBuilder
    private var dayHeader: some View {
        switch mode {
        case .day:
            CalWeekStrip(base: session.picked, today: today) { session.pick($0) }
                .padding(.top, 2)
                .padding(.bottom, 12)
                .background(theme.surface)
        case .week:
            CalColumnHead(days: CalDays.window(from: session.picked,
                                               count: CalDays.columns),
                          today: today)
                .offset(x: dx)
                .padding(.bottom, 6)
                .background(theme.surface)
        case .month, .list:
            EmptyView()
        }
    }

    /// How far a sideways swipe moves, per view. Zero means the view has
    /// no such gesture — Month has the pager's own, and List is a list.
    private var swipeStep: Int {
        switch mode {
        case .day:  return 1
        case .week: return CalDays.columns
        default:    return 0
        }
    }

    /// The grid is 24 hours tall and starts at midnight; nobody is
    /// reading about midnight. `requestAnimationFrame` on the web, one
    /// runloop turn here — the pane has to exist before it can be scrolled
    /// to.
    private func findWorkingHours(_ proxy: ScrollViewProxy, _ next: CalMode) {
        let days = CalDays.shown(next, picked: session.picked)
        /* **Month and List go to the top instead of nowhere.** This used
           to return here, which was right when the four views were four
           scrollers and wrong the moment they shared one: leaving the
           3-day view at nine in the morning and tapping Month landed on a
           month grid scrolled a screen and a half past itself, because
           the offset was the scroller's and the scroller had not changed.
           Neither has an hour to settle on, so the answer is the top. */
        guard !days.isEmpty else {
            DispatchQueue.main.async { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            return
        }
        let hour = HourGridView.focusHour(days: days, today: today)
        DispatchQueue.main.async {
            proxy.scrollTo(HourGridView.anchor(hour), anchor: .top)
        }
    }

    /// The zero-height view at the very top of the scroller.
    private static let topAnchor = "myadhd.cal.top"

    // MARK: the month row

    private var monthHead: some View {
        HStack(spacing: 8) {
            arrow(-1, symbol: "chevron.left", label: Copy.Calendar.prevMonth)

            Text(session.cursor.title)
                .font(Font.baloo(19, .heavy))
                .kerning(-0.02 * 19)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.updatesFrequently)

            arrow(1, symbol: "chevron.right", label: Copy.Calendar.nextMonth)
        }
        .frame(maxWidth: Theme.measure)
        .frame(maxWidth: .infinity)
    }

    private func arrow(_ n: Int, symbol: String, label: String) -> some View {
        Button { session.step(n, carryingDay: mode != .month) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(theme.lineStrong, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: the month, and what is on the day

    private var monthView: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthPager(tasks: tasks, today: today, session: session,
                       drag: monthDrag, taskDrag: taskDrag)

            if !session.isOnToday(today) {
                Button { session.backToToday(today) } label: {
                    Text(Copy.Calendar.backToToday)
                        .font(Font.baloo(13.5, .semibold))
                        .foregroundStyle(theme.accent)
                        .underline()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }

            CalendarAgenda(tasks: tasks,
                           picked: session.picked,
                           today: today,
                           store: store,
                           toasts: toasts,
                           dayDrag: taskDrag)
                .padding(.top, 14)

            undatedLine
        }
        /* **The space the grid and the agenda agree in.** It has to be
           out here and not on the pager, because a task lifted out of the
           list below has to be findable over a cell above it, and those
           are two different views. Both drags read the same rectangles —
           see `MonthFramesKey`. */
        .coordinateSpace(name: MonthDrag.space)
        .onPreferenceChange(MonthFramesKey.self) { frames in
            monthDrag.frames = frames
            taskDrag.frames = frames
        }
        .overlay {
            if let air = taskDrag.airborne {
                MatrixGhost(label: air.label, point: air.point)
            }
        }
        /* A gesture that never got its release — the tab changed under a
           finger — would leave a chip in the air for as long as the app
           runs. */
        .onDisappear {
            monthDrag.cancel()
            taskDrag.cancel()
        }
    }

    // MARK: the next two weeks

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalendarListPane(tasks: tasks,
                             picked: session.picked,
                             today: today,
                             store: store,
                             toasts: toasts)
            undatedLine
        }
    }

    /// `#cal-undated`. Hidden at zero, and it is the one thing the List
    /// view keeps that Day and Week drop.
    @ViewBuilder
    private var undatedLine: some View {
        if let line = Copy.Calendar.undated(undated) {
            Text(line)
                .font(Font.baloo(13))
                .lineSpacing(13 * 0.55)
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
                .overlay(alignment: .top) { theme.line.frame(height: 1.5) }
                .padding(.top, 24)
        }
    }
}
