/* ============================================================
   my.adhd for iOS — is the lock screen automation working?

   The shortcut leaves two stamps:

       drawn      Update my.adhd wallpaper ran   (Wallpaper.lastRun)
       confirmed  Confirm my.adhd wallpaper ran  (Wallpaper.lastConfirmed)

   Shortcuts stops at the first action that fails, so a confirm stamp
   means Set Wallpaper Photo, between the two, succeeded. A drawn stamp
   alone means only that a picture was made. Reading the pair gives five
   cases, and each one says what to do:

       never        neither stamp                     how to set it up
       working      confirmed within 36h, and not     say when, stay quiet
                    behind the latest drawing
       noConfirm    drawn, never confirmed            add the confirm step
       unfinished   the latest drawing is newer       the last run stopped
                    than the last confirm             before the end
       stalled      confirmed, but over 36h ago       check Run Immediately

   Thirty-six hours rather than twenty-four: a daily automation that fires
   at 07:00 has not failed at 07:05 the next morning, and a warning that
   cries wolf once is never read again. Two minutes of slack between the
   stamps, because the confirm step lands a few seconds after the drawing
   in the same run.

   Pure — no UIKit, no app types — so Checks can hold it to every case.
   ============================================================ */

import SwiftUI

struct SetupHealth: Equatable {

    enum State: Equatable { case never, working, noConfirm, unfinished, stalled }

    let drawn: Date?
    let confirmed: Date?
    var now: Date = Date()

    static let freshFor: TimeInterval = 36 * 60 * 60
    static let slack: TimeInterval = 2 * 60

    var state: State {
        guard let confirmed else { return drawn == nil ? .never : .noConfirm }
        if let drawn, drawn.timeIntervalSince(confirmed) > Self.slack { return .unfinished }
        return now.timeIntervalSince(confirmed) < Self.freshFor ? .working : .stalled
    }

    var isWorking: Bool { state == .working }

    var symbol: String {
        switch state {
        case .never: return "bolt.badge.clock"
        case .working: return "checkmark.circle.fill"
        case .noConfirm, .unfinished, .stalled: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch state {
        case .never: return .accentColor
        case .working: return .green
        case .noConfirm, .unfinished, .stalled: return .orange
        }
    }

    var title: String {
        switch state {
        case .never: return "Not set up yet"
        case .working: return "Shortcut run detected"
        case .noConfirm: return "Almost there"
        case .unfinished: return "Last run didn't finish"
        case .stalled: return "Hasn't run since \(Self.day(confirmed))"
        }
    }

    var detail: String {
        switch state {
        case .never: return "About a minute, once. Then your lock screen redraws itself."
        case .working: return "Last run: \(stamp(confirmed))"
        case .noConfirm: return "Add Confirm my.adhd wallpaper as the shortcut's last action, after Set Wallpaper Photo."
        case .unfinished: return "The picture was made at \(stamp(drawn)), but the wallpaper wasn't set. Check Set Wallpaper Photo."
        case .stalled: return "Check the automation is set to Run Immediately."
        }
    }

    var action: String {
        switch state {
        case .never: return "Set up"
        case .working: return "Set up again"
        case .noConfirm, .unfinished, .stalled: return "Check"
        }
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "never" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        let time = f.string(from: date)
        guard Calendar.current.isDate(date, inSameDayAs: now) else { return "\(time), \(Self.day(date))" }
        /* Under a minute is "just now". The formatter reads a stamp a few
           milliseconds after `now` — the page opened, then the shortcut
           finished — as the future, and printed "in 0 seconds". */
        guard now.timeIntervalSince(date) >= 60 else { return "\(time) (just now)" }
        let ago = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        return "\(time) (\(ago))"
    }

    private static func day(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }
}
