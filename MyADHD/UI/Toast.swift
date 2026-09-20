/* ============================================================
   MyADHD/UI/Toast.swift — one slot, and what that costs

   app.js:483-506, inventory §1.17. There is exactly one toast element on
   the page and `toast()` overwrites it: a second message replaces the
   first and resets the timer, which means a toast carrying an Undo can be
   silently dropped by an unrelated one arriving two seconds later.

   That is reproduced here rather than fixed. Ticking two tasks off in
   quick succession is the case it costs, and on the web the second tick's
   toast takes the slot and the first task's undo is gone — so a queue, or
   a stack of toasts, would be a different app, not a better port of this
   one. `AppStore.undoDone` is still there, and the done pile still offers
   Undo on every row in it, so nothing is actually unrecoverable.

   Two lives, because a message only has to be read and an offer has to be
   reached: 6000 ms with an action, 2600 ms without.
   ============================================================ */

import SwiftUI

// MARK: - the slot

@MainActor
@Observable
final class ToastCenter {

    /// app.js:506.
    static let plainMS = 2600
    static let actionMS = 6000

    struct Message: Identifiable, Equatable {
        /// Fresh on every show, so SwiftUI restarts the entrance even when
        /// the same words arrive twice.
        let id = UUID()
        var text: String
        var actionLabel: String?

        static func == (a: Message, b: Message) -> Bool { a.id == b.id }
    }

    private(set) var current: Message?

    /// Held beside the message rather than inside it so `Message` can stay
    /// `Equatable` — a closure is not.
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var life: Task<Void, Never>?

    init() {}

    /// A plain message.
    func show(_ text: String) {
        put(Message(text: text, actionLabel: nil), action: nil, ms: Self.plainMS)
    }

    /// A message carrying an offer — in practice always the Undo behind a
    /// tick, a removal or a rewording.
    func show(_ text: String, undo label: String = Copy.TaskRow.undo, _ fn: @escaping () -> Void) {
        put(Message(text: text, actionLabel: label), action: fn, ms: Self.actionMS)
    }

    /// The button. Hides first and then runs, the way the web's click
    /// handler does, so the toast is never still up while the undo repaints
    /// the screen behind it.
    func fire() {
        let fn = action
        dismiss()
        fn?()
    }

    func dismiss() {
        life?.cancel()
        life = nil
        action = nil
        current = nil
    }

    private func put(_ message: Message, action fn: (() -> Void)?, ms: Int) {
        /* The replacement is the whole point: whatever was pending goes,
           timer and undo together. */
        life?.cancel()
        action = fn
        current = message
        life = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }
}

// MARK: - the pill

/// styles.css:1398-1425. Centred over everything, lifted clear of the tab
/// bar when the bar is up.
struct ToastView: View {

    @Environment(\.theme) private var theme
    let center: ToastCenter
    /// `body.has-tabbar .toast` moves the floor from 26 to 88.
    var hasTabBar: Bool = true

    var body: some View {
        if let message = center.current {
            HStack(spacing: 14) {
                Text(message.text)
                    .font(Font.baloo(14, .medium))
                    .foregroundStyle(theme.toastInk)
                    .multilineTextAlignment(message.actionLabel == nil ? .center : .leading)
                    .frame(maxWidth: .infinity,
                           alignment: message.actionLabel == nil ? .center : .leading)

                if let label = message.actionLabel {
                    Button(action: center.fire) {
                        Text(label)
                            .font(Font.baloo(12.5, .bold))
                            .kerning(0.01 * 12.5)
                            .foregroundStyle(theme.toastInk)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(
                                Capsule().strokeBorder(theme.toastInk, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                }
            }
            .padding(message.actionLabel == nil ? plainPadding : actionPadding)
            .background(theme.toastBG, in: Capsule())
            .shadow(color: Color(hex: 0x101018, opacity: 0.55), radius: 12, y: 9)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
            .padding(.horizontal, 20)
            .padding(.bottom, hasTabBar ? 88 : 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.offset(y: 10).combined(with: .opacity))
            .animation(Theme.ease(0.3), value: message.id)
            .allowsHitTesting(message.actionLabel != nil)
        }
    }

    private var plainPadding: EdgeInsets {
        EdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
    }

    /// `.toast--action` trades some of the right-hand padding for the
    /// button that now lives there.
    private var actionPadding: EdgeInsets {
        EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 12)
    }
}

// MARK: - hanging it over a screen

extension View {
    /// The toast is over everything and takes no space, so it goes on as an
    /// overlay rather than into anyone's layout.
    func toastLayer(_ center: ToastCenter, hasTabBar: Bool = true) -> some View {
        overlay(alignment: .bottom) {
            ToastView(center: center, hasTabBar: hasTabBar)
                .ignoresSafeArea(.keyboard)
        }
    }
}
