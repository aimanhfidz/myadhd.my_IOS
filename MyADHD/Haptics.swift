/* ============================================================
   my.adhd for iOS — the buzz

   The one thing a home-screen web app cannot do on an iPhone, and the
   thing this app is most improved by having: ticking a task off should be
   felt. The generators are kept alive rather than made per tap because a
   cold generator costs a few hundred milliseconds to warm up, which is
   long enough to arrive after the animation it was meant to accompany.

   Kept alive is not the same as kept ready, which is what the prepare()
   after every buzz is for. The Taptic Engine is powered down again a
   couple of seconds after it is used, so a generator prepared once at
   load is warm for the first tap of a session and cold for every tap
   after a pause — and a late haptic does not read as late, it reads as a
   button that did not respond. Re-arming on the way out means the next
   one is always the fast case.
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
        case "light":     light.impactOccurred();  light.prepare()
        case "medium":    medium.impactOccurred(); medium.prepare()
        case "heavy":     heavy.impactOccurred();  heavy.prepare()
        case "success":   notice.notificationOccurred(.success); notice.prepare()
        case "warning":   notice.notificationOccurred(.warning); notice.prepare()
        case "error":     notice.notificationOccurred(.error);   notice.prepare()
        default:          selection.selectionChanged(); selection.prepare()
        }
    }

    /// Called as the page comes up, so the first tap is as sharp as the rest.
    static func warm() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        notice.prepare()
        selection.prepare()
    }
}
