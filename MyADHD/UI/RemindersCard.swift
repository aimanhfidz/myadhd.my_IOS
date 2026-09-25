/* ============================================================
   MyADHD/UI/RemindersCard.swift — the nudges' switch, how often, and when

   One switch, three levels and a waking window, in Settings under their
   own caption. The levels are the person's own words — HELP ME!!, Please
   Remind Me, It's Okay I Know — each with how often it rings under it;
   the window is the two clocks nothing rings outside of. The switch is
   `MeetingsCard`'s, for that card's reason: iOS shows its
   permission prompt exactly once, so turning this on asks, a refusal puts
   the switch back, and a switch that is on while iOS says no shows the
   way to Settings instead of pretending.

   The permission it asks for is the one the task reminders already use —
   there is only one per app — so somebody who has already let a dated
   task ring is never asked again here.

   Every change rebuilds the schedule on the spot from the store as it
   stands, rather than waiting for the next write or the next return to
   the app: a level turned up to every hour should not still ring every
   four tomorrow because nothing else happened in between.
   ============================================================ */

import SwiftUI
import UserNotifications

struct RemindersCard: View {

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    let store: AppStore

    @State private var enabled = NudgeSettings.enabled
    @State private var level = NudgeSettings.level
    @State private var window = NudgeSettings.window
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var asking = false

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: binding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Nudges.switchTitle)
                            .font(Font.baloo(15.5, .bold))
                            .kerning(-0.015 * 15.5)
                            .foregroundStyle(theme.ink)

                        Text(Copy.Nudges.switchNote)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .tint(theme.accent)
                .disabled(asking)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if enabled && status == .denied {
                    deniedRow
                } else if enabled && status != .notDetermined {
                    ForEach(NudgeLevel.allCases, id: \.self) { levelRow($0) }
                    windowRow
                }
            }
        }
        .task { await refresh() }
        /* Settings can hand the permission back while this screen is
           under the app switcher. */
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    // MARK: how often

    /// One level: its name, how often, and a tick on the chosen one. The
    /// whole row is the button.
    private func levelRow(_ option: NudgeLevel) -> some View {
        let chosen = option == level
        return Button {
            guard !chosen else { return }
            level = option
            NudgeSettings.level = option
            resync()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(Font.baloo(15.5, .bold))
                        .kerning(-0.015 * 15.5)
                        .foregroundStyle(theme.ink)

                    Text(option.note)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .opacity(chosen ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    // MARK: between which hours

    private var windowRow: some View {
        HStack(spacing: 6) {
            Text(Copy.Nudges.from)
                .font(Font.baloo(13.5, .bold))
                .foregroundStyle(theme.faint)
            DatePicker(Copy.Nudges.from, selection: clock(\.from), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)

            Text(Copy.Nudges.until)
                .font(Font.baloo(13.5, .bold))
                .foregroundStyle(theme.faint)
            /* No earlier than "from": a window that ends before it starts
               would be a single nudge a day, whatever the level said. */
            DatePicker(Copy.Nudges.until, selection: clock(\.until),
                       in: date(window.from)...,
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)

            Spacer(minLength: 0)
        }
        .tint(theme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    /// "HH:MM" in, a `Date` today at that time out, and back again.
    private func clock(_ end: WritableKeyPath<(from: String, until: String), String>) -> Binding<Date> {
        Binding(
            get: { date(window[keyPath: end]) },
            set: { picked in
                let c = DayKey.calendar.dateComponents([.hour, .minute], from: picked)
                window[keyPath: end] = String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
                /* Moving "from" past "until" takes "until" with it. */
                if let a = NudgePlanner.minutes(window.from),
                   let b = NudgePlanner.minutes(window.until), b < a {
                    window.until = window.from
                }
                NudgeSettings.window = window
                resync()
            }
        )
    }

    private func date(_ clock: String) -> Date {
        let m = NudgePlanner.minutes(clock) ?? 8 * 60
        return DayKey.calendar.date(bySettingHour: m / 60, minute: m % 60,
                                    second: 0, of: Date()) ?? Date()
    }

    // MARK: refused

    private var deniedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.Nudges.deniedNote)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openSettings) {
                Text(Copy.Meetings.openSettings)
                    .font(Font.baloo(13.5, .bold))
                    .foregroundStyle(theme.accent)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.line).frame(height: 1.5)
        }
    }

    // MARK: the switch

    /// On asks, if iOS has not been asked yet; a no puts it back off.
    private var binding: Binding<Bool> {
        Binding(
            /* Off until iOS has been asked. Nudges alone never raise the
               prompt (see `Reminders.sync`), so a switch drawn on before
               then would say they ring when nothing can; turning it on is
               what asks. */
            get: { enabled && status != .notDetermined },
            set: { want in
                enabled = want
                NudgeSettings.enabled = want
                guard want, status == .notDetermined else { resync(); return }
                /* Shown on while iOS decides, not snapped back under the
                   finger by the getter above. */
                status = .provisional
                asking = true
                Task {
                    let granted = (try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])) ?? false
                    await refresh()
                    asking = false
                    if !granted {
                        enabled = false
                        NudgeSettings.enabled = false
                    }
                    resync()
                }
            }
        )
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func resync() {
        Reminders.sync(json: store.doc.jsonString)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
