/* ============================================================
   my.adhd for iOS — the keyboard without its accessory bar

   WKWebView puts a bar above the keyboard for form fields: previous,
   next, done. It is a browser affordance for a page full of inputs, and
   in the note editor it landed exactly on top of the page's own tools —
   the format, checklist, picture and reminder buttons — so the person
   writing a note saw a row of arrows instead of the things they wanted.

   The bar comes from the content view inside the web view, not from
   WKWebView itself, and that view is private. The established way to
   remove it is to swap the content view's class for a one-off subclass
   whose inputAccessoryView returns nil. This does that once, when the
   content view first exists, and remembers the subclass so a second web
   view would reuse it. Nothing here depends on a private selector name
   beyond the class prefix "WKContent", which has been stable since iOS 8.
   ============================================================ */

import WebKit
import ObjectiveC

enum QuietKeyboard {

    private static var quietClass: AnyClass?

    static func apply(to webView: WKWebView) {
        guard let content = webView.scrollView.subviews.first(where: {
            NSStringFromClass(type(of: $0)).hasPrefix("WKContent")
        }) else { return }

        let current: AnyClass = type(of: content)
        if let quiet = quietClass, current == quiet { return }

        if quietClass == nil {
            guard let made = objc_allocateClassPair(current, "MyADHDQuietContentView", 0) else { return }
            let none: @convention(block) (AnyObject?) -> UIView? = { _ in nil }
            let imp = imp_implementationWithBlock(none)
            let sel = #selector(getter: UIResponder.inputAccessoryView)
            if let method = class_getInstanceMethod(current, sel) {
                class_addMethod(made, sel, imp, method_getTypeEncoding(method))
            }
            objc_registerClassPair(made)
            quietClass = made
        }
        if let quiet = quietClass { object_setClass(content, quiet) }
    }
}
