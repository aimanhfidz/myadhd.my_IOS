/* ============================================================
   my.adhd for iOS — "Hey Siri, dump a thought"

   The thought you have on the bus is gone by the time you have found a
   keyboard; voice.js exists for that reason and this is the same argument
   carried one step further back. Holding the mic still costs unlocking the
   phone, finding the icon and waiting for a page. This costs saying it.

   openAppWhenRun because the dump box is where the text has to land, and
   because seeing it arrive is what makes it believable that it did.
   ============================================================ */

import AppIntents

struct DumpIntent: AppIntent {

    static var title: LocalizedStringResource = "Dump a thought"

    static var description = IntentDescription(
        "Drops something into my.adhd's dump box, ready to be sorted."
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Thought", requestValueDialog: "What is in your head?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        Inbox.put(text)
        return .result()
    }
}

struct MyADHDShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DumpIntent(),
            phrases: [
                "Dump a thought into \(.applicationName)",
                "Add to \(.applicationName)",
                "Brain dump with \(.applicationName)"
            ],
            shortTitle: "Dump a thought",
            systemImageName: "brain.head.profile"
        )
    }
}
