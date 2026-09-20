/* ============================================================
   MyADHD/UI/CalendarModes.swift — List, Day, Week, Month

   BridgeScript.swift:786-1087. These three extra views exist only in the
   iOS shell: the website draws a month and an agenda and nothing else.
   They were injected JavaScript reading the page's own globals, so they
   would have gone with the web view — which is the whole reason they are
   in this port rather than left behind.

   **The pill is a preference, not data.** It says how you like to look at
   the calendar on this phone; it is not a task, it is not synced, and it
   has always lived under its own key. `LegacyImport` has already copied
   the old `myadhd.ios.calView` out of the page's localStorage into
   `myadhd.native.calView` (LegacyImport.swift:490-494), so somebody who
   had it set to Week in the shell opens the native build on Week. An
   unreadable or absent value is Month, as it always was.

   The icons are SF Symbols standing in for four hand-drawn SVGs: lines,
   a split rectangle, a rectangle in columns and a nine-dot grid. The
   accessible names are the labels, which ARE copy and are the shell's.
   ============================================================ */

import SwiftUI

// MARK: - the four

enum CalMode: String, CaseIterable, Identifiable {
    case list, day, week, month

    var id: String { rawValue }

    /// `LABEL` (BridgeScript.swift:829) — and the button's whole
    /// accessible name, since the icon carries no text.
    var label: String {
        switch self {
        case .list:  return Copy.CalViews.list
        case .day:   return Copy.CalViews.day
        case .week:  return Copy.CalViews.week
        case .month: return Copy.CalViews.month
        }
    }

    var symbol: String {
        switch self {
        case .list:  return "list.bullet"
        case .day:   return "rectangle.grid.1x2"
        case .week:  return "rectangle.split.3x1"
        case .month: return "square.grid.3x3.fill"
        }
    }

    // MARK: remembered

    /// The name `LegacyImport.calViewKey` writes the migrated value under
    /// (LegacyImport.swift:95). Written out rather than read from there
    /// because that type is `@MainActor` and this is read from a view's
    /// property initialiser, which is not — and a key is a name, not a
    /// piece of state to be actor-isolated.
    static let key = "myadhd.native.calView"

    /// `var view = 'month'; if (VIEWS.indexOf(saved) >= 0) view = saved;`
    static var remembered: CalMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = CalMode(rawValue: raw) else { return .month }
        return mode
    }

    func remember() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

// MARK: - the switcher

/// `.myadhd-calview` (BridgeScript.swift:329-333) — where the theme toggle
/// used to be, because the toggle lives on home now and only there.
struct CalModePill: View {

    @Environment(\.theme) private var theme

    @Binding var mode: CalMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CalMode.allCases) { option in
                button(option)
            }
        }
        .padding(3)
        .background(theme.wash, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    private func button(_ option: CalMode) -> some View {
        let on = option == mode
        return Button {
            guard option != mode else { return }
            mode = option
            option.remember()
        } label: {
            Image(systemName: option.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? theme.ink : theme.muted)
                .frame(width: 34, height: 30)
                .background {
                    if on {
                        Capsule()
                            .fill(theme.surface)
                            .shadow(color: Color(hex: 0x101018, opacity: 0.10), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

// MARK: - the days a view is showing

enum CalDays {

    /// `mondayOf(key)` — `(getDay() + 6) % 7` days back, which is
    /// `(weekday + 5) % 7` on Foundation's 1-based count.
    static func monday(of key: String) -> String {
        guard let date = WebDates.keyToDate(key) else { return key }
        let back = (WebDates.calendar.component(.weekday, from: date) + 5) % 7
        return WebDates.addDays(-back, toKey: key)
    }

    /// Monday to Sunday of the week the key is in.
    static func week(of key: String) -> [String] {
        let mon = monday(of: key)
        return (0..<7).map { WebDates.addDays($0, toKey: mon) }
    }

    /// Which days a mode is drawing an hour grid for. Month and List draw
    /// none, and scroll nowhere.
    static func shown(_ mode: CalMode, picked: String) -> [String] {
        switch mode {
        case .day:  return [picked]
        case .week: return week(of: picked)
        default:    return []
        }
    }
}
