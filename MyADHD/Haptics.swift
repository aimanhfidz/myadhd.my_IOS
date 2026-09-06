/* ============================================================
   my.adhd for iOS — the buzz

   The one thing a home-screen web app cannot do on an iPhone, and the
   thing this app is most improved by having: ticking a task off should be
   felt. The generators are kept alive rather than made per tap because a
   cold generator costs a few hundred milliseconds to warm up, which is
   long enough to arrive after the animation it was meant to accompany.
   ============================================================ */

import UIKit

enum Haptics {

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let notice = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    /// Names match the strings the injected bridge sends.
    static func play(_ kind: String) {
        switch kind {
        case "light":     light.impactOccurred()
        case "medium":    medium.impactOccurred()
        case "heavy":     heavy.impactOccurred()
        case "success":   notice.notificationOccurred(.success)
        case "warning":   notice.notificationOccurred(.warning)
        case "error":     notice.notificationOccurred(.error)
        default:          selection.selectionChanged()
        }
    }

    /// Called as the page comes up, so the first tap is as sharp as the rest.
    static func warm() {
        light.prepare()
        medium.prepare()
        notice.prepare()
        selection.prepare()
    }
}
