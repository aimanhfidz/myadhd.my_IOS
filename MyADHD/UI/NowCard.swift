/* ============================================================
   MyADHD/UI/NowCard.swift — the one task

   app.html `#home-now`, app.js `paintNow` / `skipNow` / `moveNow`.

   One task, its first step, and three ways out of it: Done, Not now and
   Change day. Everything else about it is one tap away on the lists, and
   tapping its title goes there.

   The order is `Ordering.nowOrder`: the Today card's walk without its cap
   of three. Which one is showing is `Ordering.pickNow` against the set
   passed over with "Not now", which home holds and never saves: it is a
   shrug, not a decision, and a shrug that followed you onto the website
   tomorrow would be a snooze nobody set.

   Change day is a menu rather than the web's row of chips: Today,
   Tomorrow, Next week, and Pick a day, which opens the system calendar.
   Moved off today, the task steps aside like "Not now", or the card
   would keep showing the thing you just put off and look as if the button
   had not worked. Moved onto today, it stays: that is a decision to do it
   now.
   ============================================================ */

import SwiftUI

struct NowCard: View {

    @Environment(\.theme) private var theme

    let store: AppStore
    let toasts: ToastCenter
    let task: TaskItem
    let today: String
    /// How many open tasks there are to choose from, for "Not now".
    let choices: Int
    @Binding var passed: Set<String>
    var goToLists: () -> Void

    @State private var picking = false
    @State private var picked = Date()

    private var late: Bool { (task.when ?? "") < today && task.when != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Copy.Now.title)
                .font(Font.baloo(17, .heavy))
                .foregroundStyle(theme.ink)
                .padding(.bottom, 12)

            Button(action: goToLists) {
                Text(task.title)
                    .font(Font.baloo(22, .heavy))
                    .kerning(-0.02 * 22)
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            meta
                .padding(.top, 6)

            /* An empty "Start here" box is worse than none, and a task
               made on this phone starts with an empty first step. */
            if !task.firstStep.isEmpty {
                firstStep
                    .padding(.top, 16)
            }

            Button(action: done) {
                Text(Copy.Now.done)
                    .font(Font.baloo(16.5, .bold))
                    .foregroundStyle(Color(hex: 0xFFFFFF))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(theme.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)

            HStack(spacing: 10) {
                Button(action: skip) { soft(Copy.Now.notNow) }
                    .buttonStyle(.plain)

                Menu {
                    if task.when != today {
                        Button(Copy.Now.today) { move(to: today) }
                    }
                    Button(Copy.Now.tomorrow) { move(to: WebDates.addDays(1, toKey: today)) }
                    Button(Copy.Now.nextWeek) { move(to: WebDates.addDays(7, toKey: today)) }
                    Button(Copy.Now.pickDay) {
                        picked = WebDates.keyToDate(task.when ?? today) ?? Date()
                        picking = true
                    }
                } label: {
                    soft(Copy.Now.changeDay)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(theme.loudGlass)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(theme.loudEdge, lineWidth: 1.5)
        )
        .sheet(isPresented: $picking) { pickSheet }
    }

    // MARK: pieces

    /// Late is a word in an orange-edged chip, not orange text: colour
    /// alone tells VoiceOver nothing (BRAND.md §3.3).
    private var meta: some View {
        HStack(spacing: 8) {
            if late {
                Text(Copy.Now.late)
                    .font(Font.baloo(12.5, .bold))
                    .foregroundStyle(theme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(theme.orange, lineWidth: 1.5))
            }
            let line = [WebDates.whenLabel(when: task.when, at: task.at, today: today),
                        WebDates.minutesLabel(task.minutes)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: Copy.metaSeparator)
            Text(line)
                .font(Font.baloo(14))
                .foregroundStyle(theme.faint)
        }
    }

    /// `.first-step`, the lists' own panel: wash, accent down the left.
    private var firstStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.TaskRow.firstStepLabel.uppercased())
                .font(Font.baloo(11.5, .bold))
                .kerning(0.12 * 11.5)
                .foregroundStyle(theme.accent)
            Text(task.firstStep)
                .font(Font.baloo(15.5))
                .foregroundStyle(theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.wash)
        .overlay(alignment: .leading) { theme.accent.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func soft(_ label: String) -> some View {
        Text(label)
            .font(Font.baloo(15, .semibold))
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, minHeight: 46)
            .overlay(Capsule().strokeBorder(theme.lineStrong, lineWidth: 1.5))
            .contentShape(Capsule())
    }

    private var pickSheet: some View {
        NavigationStack {
            DatePicker("", selection: $picked,
                       in: (WebDates.keyToDate(today) ?? Date())...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 16)
                .navigationTitle(Copy.Now.pickDay)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Now.changeDay) {
                            picking = false
                            move(to: WebDates.dayKey(picked))
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: the three ways out

    /// The lists' tick, with the lists' toast and Undo.
    private func done() {
        let id = task.id
        guard store.markDone(id) else { return }
        toasts.show(Copy.TaskRow.done) {
            store.undoDone(id)
        }
    }

    private func skip() {
        guard choices > 1 else {
            toasts.show(Copy.Now.onlyOne)
            return
        }
        pass(task.id)
    }

    /// Everything already passed over and this one came round again: start
    /// the pile over with it, as the web clears `passedNow`.
    private func pass(_ id: String) {
        if passed.contains(id) { passed = [id] } else { passed.insert(id) }
    }

    private func move(to day: String) {
        let id = task.id
        let was = task.when
        guard store.moveToDay(id, to: day) else { return }
        if day > today { pass(id) }
        toasts.show(Copy.Calendar.movedTo(label: WebDates.dayPhrase(day, today: today))) {
            store.moveToDay(id, to: was)
            passed.remove(id)
        }
    }
}
