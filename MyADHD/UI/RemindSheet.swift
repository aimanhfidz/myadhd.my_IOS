/* ============================================================
   MyADHD/UI/RemindSheet.swift — a day, a time, and how often

   `#sheet-remind` (app.html:618-654), `openRemindSheet` / `saveRemind` /
   `clearRemind` (app.js:4909-4940).

   **Prefilled with today and nine in the morning.** A sheet opened on a
   note that has no reminder yet shows `dayKey()` and `09:00`, so Save is
   one tap from meaning something. That is the web's `n.remindOn ||
   dayKey()` and `n.remindAt || '09:00'`, and it is the reason the day
   picker is never empty.

   **The day is the only field that matters.** `saveRemind` runs the day
   through `normalizeDay` and then keeps the time and the repeat ONLY if
   the day survived: a time on no day is a time on no calendar, and the
   store would not hold it anyway (`normalizeNote` nulls `remindAt` and
   empties `repeat` behind it).

   **This is one of the six places a note calls `save()`.** Everything
   else in the editor writes through `persistOnly`; a reminder does not,
   because a reminder is a thing the phone would have to schedule and the
   schedule is rebuilt off a full write.

   **And nothing schedules it.** Not app.js, not sw.js, not the shell —
   `Reminders.swift` has only ever read tasks. A note's reminder is stored
   and drawn on the card and in the editor line, and that is the whole of
   its life today. Making it ring is a feature, not a port.
   ============================================================ */

import SwiftUI

struct RemindSheet: View {

    @Environment(\.theme) private var theme

    let note: NoteItem
    var close: () -> Void
    /// day (YYYY-MM-DD), time (HH:MM), repeat rule.
    var save: (String, String, String) -> Void
    var clear: () -> Void

    @State private var day = Date()
    @State private var time = Date()
    @State private var rule = ""
    @State private var filled = false

    var body: some View {
        NoteSheetShell(title: Copy.Note.Remind.title, close: close) {
            VStack(alignment: .leading, spacing: 0) {
                field(Copy.Note.Remind.day) {
                    DatePicker("", selection: $day, displayedComponents: .date)
                        .labelsHidden()
                }
                field(Copy.Note.Remind.time) {
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                field(Copy.Note.Remind.repeats) {
                    Picker("", selection: $rule) {
                        ForEach(Copy.Note.Remind.rules, id: \.self) { r in
                            Text(Copy.Note.Remind.ruleLabel(r)).tag(r)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(theme.ink)
                }

                HStack(spacing: 12) {
                    Button(action: clear) {
                        Text(Copy.Note.Remind.clear)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(theme.faint)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        save(WebDates.dayKey(day), Self.clock(time), rule)
                    } label: {
                        Text(Copy.Note.Remind.save)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.muted)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 11)
                            .overlay(
                                Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 18)
            }
        }
        .onAppear(perform: prefill)
    }

    /// `.field` — a small caption over the control.
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.muted)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 22)
    }

    /// `remindOn || dayKey()`, `remindAt || '09:00'`, `repeat || ''`.
    private func prefill() {
        guard !filled else { return }
        filled = true
        day = WebDates.keyToDate(note.remindOn ?? "") ?? Date()
        time = Self.date(from: note.remindAt ?? "09:00") ?? Date()
        rule = NoteItem.repeats.contains(note.repeatRule) ? note.repeatRule : ""
    }

    // MARK: HH:MM, both ways

    /// The picker's instant as the clock time the store keeps. Read in
    /// the app's own Gregorian calendar rather than `Calendar.current` —
    /// a device on the Buddhist calendar still writes `09:00`.
    static func clock(_ d: Date) -> String {
        let p = WebDates.calendar.dateComponents([.hour, .minute], from: d)
        return WebDates.pad2(p.hour ?? 0) + ":" + WebDates.pad2(p.minute ?? 0)
    }

    static func date(from clock: String) -> Date? {
        guard let minutes = WebDates.clockMinutes(Normalize.normalizeTime(clock)) else { return nil }
        var parts = WebDates.calendar.dateComponents([.year, .month, .day], from: Date())
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        parts.second = 0
        return WebDates.calendar.date(from: parts)
    }
}
