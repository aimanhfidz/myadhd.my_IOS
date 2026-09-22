/* ============================================================
   Copy — every user-facing string the core loop draws

   Copy is the product. Nothing here is a paraphrase: each constant
   was grepped out of app.js or app.html and pasted, em-dashes,
   ellipses, capitalisation and full stops included. The trailing
   comment on each one names the file and line it came from.

   Checks/copy.sh greps every literal in this file back against
   app.js, app.html and MyADHD/BridgeScript.swift and fails naming
   any that is not found, so a paraphrase cannot land quietly.
   Because of that:

   - No comment in this file contains a double-quote character. The
     extractor in copy.sh pulls every quoted run out of the source
     and a quote in prose would hand it a fragment of a sentence.
   - Where the web builds a line out of parts, this file reproduces
     the construction as a function rather than flattening it, so
     each literal fragment still greps.
   ============================================================ */

import Foundation

enum Copy {

    /// The separator between the parts of a meta line. app.js writes it
    /// inline in half a dozen template strings; one constant here so the
    /// spacing cannot drift between them.
    static let metaSeparator = " · "   // app.js:1258-1260, 748, 4221

    // MARK: - Tab bar (app.html:1058-1076; app.js:426-473)

    enum Tabs {
        static let navAria = "Sections"            // app.html:1058
        static let home = "Home"                   // app.html:1059
        static let calendar = "Calendar"           // app.html:1062
        static let add = "Add to your lists"       // app.html:1066
        static let lists = "My lists"              // app.html:1069
        static let notes = "Notes"                 // app.html:1073

        /// Both marks cap their number the same way.
        static let badgeCap = "99+"                // app.js:456, 470

        /// The lists mark: a plain dot while nothing is late, and a count
        /// the moment something is — how many you have missed is worth a
        /// number where merely having tasks is not. Empty string means the
        /// dot, exactly as app.js:454 leaves textContent empty.
        static func listsMark(late: Int) -> String {
            guard late > 0 else { return "" }
            return late > 99 ? badgeCap : String(late)
        }                                          // app.js:456

        /// The calendar badge always carries its count.
        static func calendarBadge(dated: Int) -> String {
            dated > 99 ? badgeCap : String(dated)
        }                                              // app.js:470
    }

    /// The four tab screens' own names, in the place a website puts its
    /// wordmark. `ScreenHeader` draws them; the reasoning is in that file.
    enum ScreenTitle {
        static let home = "Home"          // BridgeScript.swift:143
        static let calendar = "Calendar"  // BridgeScript.swift:144
        static let lists = "Lists"        // BridgeScript.swift:145
        static let notes = "Notes"        // BridgeScript.swift:146
    }

    // MARK: - Theme toggle (app.html:216; theme.js paint)

    enum Theme {
        static let toDark = "Switch to dark mode"    // app.html:216, theme.js:29
        static let toLight = "Switch to light mode"  // theme.js:29
    }

    // MARK: - Home (app.html:199-291; app.js:4131-4247)

    enum Home {
        static let brandAria = "my.adhd home"   // app.html:201
        static let settingsAria = "Settings"    // app.html:213

        // the cold start (app.html:241-256)
        static let welcomeAlt = "Morpheus, from The Matrix: what if I told you my ADHD thoughts have a group chat and everyone's typing."   // app.html:244
        static let headline = "What's on your mind?"   // app.html:247
        static let startHint = "Everything gets sorted into lists. Nothing is thrown away."   // app.html:248-249
        static let startButton = "Clear my head"       // app.html:252

        // the Today card (app.html:266-275; app.js:4189-4201)
        static let todayToday = "Next up"       // app.js:4193 fallback, app.html:270
        static let todayNow = "Today"           // app.js:4193
        static let more = "All lists"           // app.html:271
        static let empty = "Head's clear. Nothing waiting."   // app.html:274

        /// The heading carries the bad news, because it is the line that
        /// gets read whether or not the rows below it do.
        static func todayTitle(late: Int, today: Int) -> String {
            if late > 0 { return late == 1 ? "1 late" : "\(late) late" }   // app.js:4191
            return today > 0 ? todayNow : todayToday                        // app.js:4193
        }

        /// RAW minutes, not minutesLabel: a 90-minute task reads 90 min
        /// here and 1.5 hr on the lists, and that difference is app.js's.
        static func rowMeta(when: String?, minutes: Int) -> String {
            [when, "\(minutes) min"]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: metaSeparator)
        }                                        // app.js:4221

        // the five numbers (app.html:280-287)
        static let statOpen = "on your lists"       // app.html:281
        static let statDone = "done"                // app.html:282
        static let statLists = "lists"              // app.html:283
        static let statDated = "on the calendar"    // app.html:284
        static let statOverdue = "overdue"          // app.html:286
    }

    // MARK: - Loading (app.html:292-301; app.js:508-534)

    enum Loading {
        /// Advanced every 1900 ms, wrapping. The first is also what
        /// app.html ships in the markup.
        static let lines = [
            "Untangling that…",                     // app.js:509
            "Sorting the noise from the signal…",   // app.js:510
            "Finding the one that matters…",        // app.js:511
            "Sizing everything up…",                // app.js:512
        ]
    }

    // MARK: - Composer (app.html:1084-1127; app.js:1875-2246)

    enum Composer {
        static let cancel = "Cancel"                            // app.html:1090
        static let title = "New dump"                           // app.html:1091
        static let post = "Sort it"                             // app.html:1092
        static let placeholder = "just tell me, i'll sort it out."   // app.html:1100
        static let datesLabel = "Heading for the calendar"      // app.html:1102
        static let micSR = "Hold to talk"                       // app.html:1122

        /// profile.name || you
        static let youFallback = "you"                          // app.js:1908, app.html:1098

        /// The overflow chip on the typing date preview.
        static func moreChips(_ n: Int) -> String { "+\(n) more" }   // app.js:5054
    }

    // MARK: - The faces (app.js:3881-3882)

    /// `AVATARS`, in its order. The first is the default, and it is what an
    /// unrecognised stored face is drawn as — `avatarFace` never writes the
    /// substitution back, so somebody's own choice survives a build that
    /// cannot draw it.
    ///
    /// They are user-facing strings like any other, and one drifting out of
    /// this list would change the face on somebody's composer without
    /// anything being written to their profile.
    enum Avatars {
        static let faces = ["🧔🏻", "🧔🏻‍♂️", "👨🏻", "👱🏻‍♂️", "👨🏻‍🦲", "👨🏼‍🦱",
                            "👩🏻", "🧑🏻", "👩🏻‍🦱", "👱🏻‍♀️", "👩🏻‍🦳", "🧑🏻‍🦰"]
    }

    // MARK: - Hold-to-talk (app.js:5280-5481)

    enum Mic {
        static let rest = "hold to talk"                        // app.js:5298
        static let opening = "opening the mic…"                 // app.js:5348
        static let listening = "listening… let go when done"    // app.js:5356
        static let warn = "nearly at the limit — wrap it up"    // app.js:5375
        static let tooQuick = "hold it down while you talk"     // app.js:5405
        static let writing = "writing it down…"                 // app.js:5415
        static let neverOpened = "the mic never opened"         // app.js:5438
        static let nothingHeard = "didn't catch anything that time"   // app.js:5441

        static let cappedToast = "That was the limit — got what you said so far."   // app.js:5382
        static let deniedToast = "no mic access — allow it in your browser settings"   // app.js:5388
        static let failedToast = "couldn't start the mic, try again"   // app.js:5389
        static let noPermissionToast = "Your browser did not let us open the mic — check its site permissions."   // app.js:5439
        static let roughToast = "Couldn't reach the transcriber — that's the rough version."   // app.js:5452
    }

    // MARK: - Triage (app.js:559-634)

    enum Triage {
        static let nothingToSort = "Give me something to work with."     // app.js:563
        static let offline = "Offline mode — sorted these myself."       // app.js:577
        static let nothingFound = "Couldn't find any tasks in there."    // app.js:583

        /// Dedupe is against OPEN titles only, and never within one dump.
        static func result(added: Int, dupes: Int) -> String? {
            if dupes == 1 { return "Added — one was already on a list." }   // app.js:610
            if dupes > 1 { return "Added — \(dupes) were already on a list." }   // app.js:611
            if added > 0 { return "Added \(added) to your lists." }         // app.js:613
            return nil
        }
    }

    // MARK: - Lists screen (app.html:306-398; app.js:1221-1657)

    enum Lists {
        static let eyebrowPlain = "Sorted into lists."      // app.js:1244, app.html:336
        static func eyebrow(name: String) -> String { "Sorted, \(name)." }   // app.js:1243

        /// N things · N lists · about 1.5 hr all in
        ///
        /// The words are hoisted out of the interpolations on purpose:
        /// Checks/copy.sh splits a literal on its interpolations, and a
        /// nested string literal inside one would hand it half a sentence.
        static func summary(open: Int, lists: Int, totalMinutes: Int) -> String {
            let thingWord = open == 1 ? "thing" : "things"
            let listWord = lists == 1 ? "list" : "lists"
            let spent = WebDates.minutesLabel(totalMinutes)
            return "\(open) \(thingWord)"
                + metaSeparator
                + "\(lists) \(listWord)"
                + metaSeparator
                + "about \(spent) all in"
        }                                                   // app.js:1258-1261

        // the view toggle names the view you are NOT in (app.js:1301-1309)
        static let viewToMatrix = "Matrix"                  // app.js:1303, app.html:326
        static let viewToList = "List"                      // app.js:1303
        static let viewAriaToMatrix = "Show the matrix"     // app.js:1306
        static let viewAriaToList = "Show the lists"        // app.js:1307

        static let catBarAria = "Filter by list"            // app.html:363
        static let catAll = "All"                           // app.js:1396

        // the empty state (app.html:393-396)
        static let clearedStrong = "Head's clear."                 // app.html:394
        static let clearedRest = "Nothing left in the queue."      // app.html:394
        static let dumpAgain = "Dump again"                        // app.html:395
    }

    // MARK: - The offline note and re-sorting (app.html:339-341; app.js:1659-1748)

    enum OfflineNote {
        /// N was / N were sorted offline — …
        static func word(_ n: Int) -> String { n == 1 ? "was" : "were" }   // app.js:1253
        static let body = "sorted offline — the times and lists are rough guesses, not the real analysis."   // app.html:340

        static let resort = "Sort these properly"       // app.html:341, app.js:1698
        static let resorting = "Sorting…"               // app.js:1666
        static let resorted = "Sorted properly."        // app.js:1683

        /// Kept the offline reading and stopped calling it provisional.
        static func settled(_ n: Int) -> String {
            n == 1
                ? "Kept as it was — the sorter had nothing to add."      // app.js:1711
                : "Kept as they were — the sorter had nothing to add."   // app.js:1712
        }

        // resortProblem() says which way it failed (app.js:1742-1748)
        static let problemOffline = "Still offline — no connection."          // app.js:1744
        static func problemStatus(_ status: String) -> String {
            "The sorter answered \(status). Try again in a moment."
        }                                                                     // app.js:1746
        static let problemUnreachable = "Cannot reach the backend from here." // app.js:1747
        static let problemEmpty = "The sorter sent nothing back. Try again."  // app.js:1748
    }

    // MARK: - The signup offer (app.html:349-357)

    enum Signup {
        static let dismissAria = "No thanks"                            // app.html:350
        static let title = "Keep these on your other devices?"          // app.html:351
        static let body = "Right now this list lives in this browser only — clear your history and it is gone, and your phone and laptop each keep their own separate copy. Signing in gives you one list everywhere, and puts your dated tasks in Google Calendar without asking again."   // app.html:352-355
        static let button = "Sign in with Google"                       // app.html:356
    }

    // MARK: - A task row (app.js:1427-1552, 1752-1872)

    enum TaskRow {
        static func checkAria(title: String) -> String { "Mark \"\(title)\" done" }   // app.js:1437
        static func energyChip(_ energy: String) -> String { "\(energy) energy" }     // app.js:1457
        static let urgentChip = "urgent"                        // app.js:1473

        static let firstStepLabel = "Start here — 2 minutes"    // app.js:1487
        static let stepsLabel = "Broken down"                   // app.js:1497

        static let breakDown = "Too big — break it down"        // app.js:1504, 1869
        static let breakingDown = "Breaking it down…"           // app.js:1848
        static let brokenDown = "Broken down ✓"                 // app.js:1865
        static let breakDownFailed = "Needs the AI backend for this one."   // app.js:1870

        static let edit = "Edit"                                // app.js:1520
        static let remove = "Remove"                            // app.js:1526
        static let editAria = "Edit this task"                  // app.js:1762
        static let reworded = "Reworded."                       // app.js:1777
        static let removed = "Removed."                         // app.js:1805
        static let done = "Done."                               // app.js:1832
        static let undo = "Undo"                                // app.js:1591, 1806, 1833
    }

    // MARK: - Bucket headings (app.js:1128-1133)

    /// Four headings, in the order the day presses on you. Only the ones
    /// with something under them are drawn.
    enum Buckets {
        static let order = ["late", "today", "soon", "someday"]

        static func label(_ key: String) -> String {
            switch key {
            case "late":    return "Late"          // app.js:1129
            case "today":   return "Today"         // app.js:1130
            case "soon":    return "Coming up"     // app.js:1131
            case "someday": return "No date yet"   // app.js:1132
            default:        return key
            }
        }
    }

    // MARK: - Quadrant headings (app.js:1169-1174, 1361, 1371, 2856-2857)

    /// All four are always drawn: a 2x2 with a hole in it stops being a
    /// 2x2, and an empty Do now is worth seeing.
    enum Quadrants {
        static let order = ["do", "plan", "delegate", "drop"]

        static func label(_ key: String) -> String {
            switch key {
            case "do":       return "Do now"      // app.js:1170
            case "plan":     return "Plan"        // app.js:1171
            case "delegate": return "Delegate"    // app.js:1172
            case "drop":     return "Drop"        // app.js:1173
            default:         return key
            }
        }

        static func sub(_ key: String) -> String {
            switch key {
            case "do":       return "Important & urgent"        // app.js:1170
            case "plan":     return "Important, not urgent"     // app.js:1171
            case "delegate": return "Urgent, not important"     // app.js:1172
            case "drop":     return "Neither"                   // app.js:1173
            default:         return ""
            }
        }

        static let empty = "Nothing here."                      // app.js:1371
        static func addAria(label: String) -> String { "Add something to \(label)" }   // app.js:1361
        static func movedTo(label: String) -> String { "Moved to \(label)." }          // app.js:2857
    }

    // MARK: - Category names (app.js:1076-1089)

    /// Display names for the categories the model returns. Anything
    /// unexpected falls through to a title-cased version of whatever
    /// came back.
    enum Categories {
        static func label(_ c: String) -> String {
            switch c {
            case "work":    return "Work"              // app.js:1077
            case "admin":   return "Admin"             // app.js:1078
            case "money":   return "Money"             // app.js:1079
            case "health":  return "Health"            // app.js:1080
            case "home":    return "Home"              // app.js:1081
            case "social":  return "Social"            // app.js:1082
            case "errand":  return "Errands"           // app.js:1083
            case "general": return "Everything else"   // app.js:1084
            default:
                guard let first = c.first else { return c }
                return String(first).uppercased() + String(c.dropFirst())
            }                                          // app.js:1088
        }
    }

    // MARK: - The done pile (app.html:374-379; app.js:1563-1606)

    enum DonePile {
        static func count(_ n: Int) -> String {
            n == 1 ? "1 done" : "\(n) done"
        }                                              // app.js:1570

        static let undo = "Undo"                       // app.js:1591

        /// Only the most recent DONE_SHOWN are listed; the rest get a line.
        static let shown = 20                          // app.js:315

        static func hiddenNote(_ hidden: Int) -> String {
            let word = hidden == 1 ? "one is" : "ones are"
            return "\(hidden) older \(word) not shown. Finished tasks clear themselves after a week."
        }                                              // app.js:1606
    }

    // MARK: - The danger zone (app.html:381-391; app.js:1616-1657)

    /// Two confirmations, because there is no undo and no backup. The
    /// armed state also times out after 20 s.
    enum DangerZone {
        static let clearAll = "Clear everything"       // app.html:382
        static let cancel = "Cancel"                   // app.html:387

        static func firstAsk(_ n: Int) -> String {
            let what = n == 1 ? "the 1 task" : "all \(n) tasks"
            return "Delete \(what) on your lists? This cannot be undone."
        }                                              // app.js:1634
        static let firstGo = "Yes, clear everything"   // app.js:1635

        static func lastAsk(_ n: Int) -> String {
            let what = n == 1 ? "it" : "all \(n)"
            return "Last check — this permanently deletes \(what) and there is no backup."
        }                                              // app.js:1639
        static func lastGo(_ n: Int) -> String {
            n == 1 ? "Delete it" : "Delete all \(n)"
        }                                              // app.js:1640

        static func cleared(_ gone: Int) -> String {
            gone == 1 ? "Cleared. 1 task gone." : "Cleared. \(gone) tasks gone."
        }                                              // app.js:1649
    }

    // MARK: - Calendar (app.html:401-454; app.js:2252-2451)

    /// Nested inside `Copy`, so the name is `Copy.Calendar`. Nothing in
    /// this file names Foundation's calendar, so there is nothing to shadow.
    enum Calendar {
        static let prevMonth = "Previous month"        // app.html:415
        static let nextMonth = "Next month"            // app.html:418
        static let backToToday = "Back to today"       // app.html:448

        /// What the toast says after a task has been dragged onto a day.
        /// The same sentence the matrix says after a drop onto a quadrant
        /// (`Quadrants.movedTo`) and off the same line of app.js — one
        /// gesture with two kinds of target should not be two wordings.
        /// `label` is `WebDates.dayLabel`, so it reads `Moved to Today.`
        /// or `Moved to Wed 23 Sep.`
        ///
        /// Backticks and not quotes, deliberately: `copy.sh` pulls every
        /// double-quoted run out of this file, comments included, so an
        /// example written the natural way becomes a needle it then
        /// cannot find in app.js. It fails loudly, which is the check
        /// working — but the fix is to not write the example in quotes.
        static func movedTo(label: String) -> String { "Moved to \(label)." }   // app.js:2857
        /* No label for the hold itself. The matrix's has none either, and
           the web has no sentence for one — inventing an English string
           here would be the first piece of copy in this file that came
           from nowhere. It is a real gap for VoiceOver, in both gestures,
           and it wants a decision about wording rather than a guess. */

        /// The static day-name row, Monday first. Two of the seven are the
        /// same letter, which is why they are written out and not derived.
        static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]   // app.html:435

        /// `${MONTH_NAMES[m]} ${yyyy}` — September 2026.
        static func monthTitle(month: Int, year: Int) -> String {
            let name = WebDates.monthNames[min(max(month, 0), 11)]
            return "\(name) \(year)"
        }                                              // app.js:2350-2351

        /// A live cell's accessible name: the day, then how much is on it,
        /// then the first clock time if any of it is booked.
        static func dayAria(label: String, count: Int, from: String?) -> String {
            let word = count == 1 ? "thing" : "things"
            var out = label
            out += count > 0 ? ", \(count) \(word)" : ", nothing"
            if let from, !from.isEmpty { out += ", from \(from)" }
            return out
        }                                              // app.js:2318-2319

        /// The line under the month. nil at zero, where the web hides it.
        static func undated(_ n: Int) -> String? {
            if n <= 0 { return nil }
            if n == 1 { return "1 more thing has no day on it — it is waiting on your lists." }
            return "\(n) more things have no day on them — they are waiting on your lists."
        }                                              // app.js:2373-2374

        /// The overdue group's heading. It rides on today and nowhere else.
        static func overdueHead(_ n: Int) -> String { "\(n) overdue" }   // app.js:2387

        static let emptyToday = "Nothing on today. Say a day in the dump box and it lands here."   // app.js:2397
        static func emptyDay(_ phrase: String) -> String { "Nothing on \(phrase)." }   // app.js:2398

        /// A day with no time is not a 00:00 appointment.
        static let anyTime = "any time"                // app.js:2430

        /// A late row prints which day it was on; an on-time row prints how
        /// much energy it wants.
        static func lateMeta(day: String, minutes: String) -> String {
            day + metaSeparator + minutes
        }                                              // app.js:2437
        static func itemMeta(minutes: String, energy: String) -> String {
            minutes + metaSeparator + "\(energy) energy"
        }                                              // app.js:2438
    }

    // MARK: - The shell's four calendar views (BridgeScript.swift:786-1087)

    /// List, Day and Week exist only in the iOS shell: the pill beside the
    /// month title, and the three panes behind it.
    enum CalViews {
        static let list = "List"      // BridgeScript.swift:829
        static let day = "Day"        // BridgeScript.swift:829
        static let week = "Week"      // BridgeScript.swift:829
        static let month = "Month"    // BridgeScript.swift:829

        /// The chips above the hour grid, for everything on the day with no
        /// clock on it. Six, and then a count.
        static let anytime = "Anytime"                 // BridgeScript.swift:930
        static func andMore(_ n: Int) -> String { "+\(n)" }   // BridgeScript.swift:931
        static let anytimeMax = 6                      // BridgeScript.swift:930

        static let emptyList = "Nothing in the next two weeks. Say a day in the dump box and it lands here."   // BridgeScript.swift:952

        /// A block's second line: `9am · 30 min`.
        static func blockMeta(time: String, minutes: Int) -> String {
            time + metaSeparator + "\(minutes) min"
        }                                              // BridgeScript.swift:920
    }

    // MARK: - Meetings read off the phone (Meetings.swift)

    /// **The only block in this file with no web original.** Every other
    /// constant here was grepped out of the web app and pasted; these
    /// could not be, because the website has no way to read a diary and
    /// has therefore never had a sentence about one. `Checks/copy.sh`
    /// knows these by name and checks everything else as strictly as
    /// ever — the list is at the top of that script, and it is not a
    /// place to put a string that does have an original.
    ///
    /// The register is the web app's: second person, no jargon, and the
    /// sentence says what happens rather than what the feature is called.
    enum Meetings {
        static let switchTitle = "Show my meetings"
        static let switchNote = "Meetings already on this phone show up beside your tasks."

        /// iOS shows its prompt once and never again, so a refusal is a
        /// dead end unless the row says where the way back is.
        static let deniedNote = "my.adhd cannot see your calendar. iOS only asks once, so Settings is the way back."
        static let openSettings = "Open Settings"

        /// What the switch cannot say on its own: it is on, so why is the
        /// day still empty? Two numbers separate the two answers.
        ///
        /// No calendars means this phone has nothing to read — a Google
        /// account that lives only in the Google Calendar app and was
        /// never added under iOS Settings is invisible to every other app
        /// on the phone, this one included. Calendars but no meetings
        /// means the read worked and the window or the filters are what
        /// to look at next.
        static func readNote(_ calendars: Int, _ meetings: Int) -> String {
            let seen = calendars == 1 ? "1 calendar" : "\(calendars) calendars"
            let got = meetings == 1 ? "1 meeting" : "\(meetings) meetings"
            return "Reading \(seen). \(got) in the next 60 days."
        }

        /// The action on a meeting row. It copies the meeting into your
        /// own lists; it does not move it, and it changes nothing on the
        /// calendar it came from.
        static let makeTask = "Make this a task"

        /// The time column for a meeting that has no clock. NOT the
        /// task's `any time`, which means the opposite thing: an undated
        /// task could be done at any hour, and an all-day event is true
        /// of every hour whether you like it or not.
        static let allDay = "All day"

        /// A meeting row's second line: which calendar it came off, then
        /// how long it runs. Knowing a thing is on the work calendar is
        /// most of what you need to know about it.
        static func meta(calendar: String, minutes: String) -> String {
            calendar + metaSeparator + minutes
        }

        /// An all-day meeting has no length worth printing, so the line
        /// is only where it came from.
        static func allDayMeta(calendar: String) -> String { calendar }
    }

    // MARK: - How the matrix works (BridgeScript.swift:532-609)

    /// The four-page walkthrough behind the `?`. The sample tasks are made
    /// up on purpose — the point is the shape, not the person's own list.
    enum Walkthrough {
        static let title = "How the matrix works"      // BridgeScript.swift:545, 591
        static let close = "Close"                     // BridgeScript.swift:591
        static let back = "Back"                       // BridgeScript.swift:596

        struct Page {
            var head: String
            var body: String
            var cta: String
        }

        static let pages: [Page] = [
            Page(head: "One list, no order",
                 body: "Everything shouts the same. Nothing says what to do first.",
                 cta: "Sort them into boxes"),                       // BridgeScript.swift:575-576
            Page(head: "Four boxes, one decision",
                 body: "Urgent and important first. The rest waits, moves, or goes.",
                 cta: "Move one"),                                   // BridgeScript.swift:577
            Page(head: "Hold, then drag",
                 body: "Press a task and drop it in another box. Nothing is stuck where it landed.",
                 cta: "See it on the home screen"),                  // BridgeScript.swift:578
            Page(head: "On your home screen",
                 body: "The Today widget shows the next few things every time you look — and you can tick one off right there.",
                 cta: "Done"),                                       // BridgeScript.swift:579
        ]

        /// `T` — the eight sample rows and the quadrant each one starts in.
        static let samples: [(title: String, quadrant: String)] = [
            ("Send the invoice", "do"),
            ("Sort old photos", "drop"),
            ("Plan next month", "plan"),
            ("Reply to the vendor", "delegate"),
            ("Pay the rent", "do"),
            ("Watch that series", "drop"),
            ("Book the flights", "delegate"),
            ("Save for the trip", "plan"),
        ]                                              // BridgeScript.swift:554-557

        /// The one that moves on page three: out of Do now and into Plan,
        /// keeping its old ring so the move is the thing you see.
        static let moved = "Pay the rent"              // BridgeScript.swift:568

        // the phone on the last page (BridgeScript.swift:580-581)
        static let phoneDate = "Friday, 18 September"
        static let phoneTime = "05:59"
        static let widgetEyebrow = "TODAY"
        /// The three rows in the mock widget; the first is already ticked.
        static let widgetRows: [(title: String, quadrant: String, done: Bool)] = [
            ("Send the invoice", "do", true),
            ("Pay the rent", "do", false),
            ("Plan next month", "plan", false),
        ]                                              // BridgeScript.swift:581
    }

    // MARK: - Notes index (app.html:456-506; app.js:4360-4465)

    enum Notes {
        static let eyebrow = "Notes."                  // app.html:479
        static let newNote = "New note"                // app.html:483

        /// Empty string when there are none — the summary is hidden
        /// rather than emptied, but the words are these.
        static func summary(_ n: Int) -> String {
            n == 1 ? "1 note" : "\(n) notes"
        }                                              // app.js:4383

        static let emptyTitle = "Nothing written down yet."                        // app.html:496
        static let emptyBody = "Notes stay on this device. Nothing here gets sorted."   // app.html:497

        /// app.html ships Write one and the shell has always relabelled it
        /// on the way past. This build IS the shell, so it draws the label
        /// the shell drew.
        static let emptyGo = "Write a note"            // BridgeScript.swift:617

        static let hint = "Notes stay on this device. Signing in carries your lists between browsers; it does not carry these yet."   // app.html:503-504

        /// The card's fallback. The editor heading uses a different word
        /// for the same absence — see Note.heading.
        static let untitled = "Untitled"               // app.js:4365

        /// `2/3 done`, on the foot of a card that has a checklist on it.
        ///
        /// The index is native-only ground — the web has no such badge, so
        /// there is no line of app.js to cite for the whole of it. What it
        /// is built from is the web's: `done` is the word app.html:282 and
        /// app.js:1570 both use for finished work (`Home.statDone`,
        /// `DonePile.count`), and the slash is punctuation. `copy.sh` cuts
        /// this at its interpolations and checks ` done` against the web's
        /// own sources, which is the whole of what is assertable here.
        static func checkCount(done: Int, total: Int) -> String {
            "\(done)/\(total) done"
        }
    }

    // MARK: - The note editor (app.html:514-655; app.js:4570-4998)

    enum Note {
        static let back = "Back to notes"              // app.html:516
        static let done = "Save and close"             // app.html:520

        /// A note with no title is still a Note here and Untitled on the
        /// card. That is app.js:4575 against app.js:4365, not a slip.
        static let heading = "Note"                    // app.js:4575

        static let titlePlaceholder = "Title"          // app.html:528
        /// Only on the first block, and only while it is empty.
        static let firstBlockHint = "Write something"  // app.js:4626

        static let tickOff = "Tick off"                // app.js:4598
        static let notDone = "Not done"                // app.js:4598

        static let delete = "Delete note"              // app.html:535
        static let deleted = "Note deleted"            // app.js:4993

        // the right rail (app.html:543-556)
        static let toolPaper = "Paper colour"          // app.html:543
        static let toolType = "Text format"            // app.html:546
        static let toolCheck = "Turn this line into a checkbox"   // app.html:549
        static let toolClip = "Add a picture"          // app.html:552
        static let toolBell = "Remind me about this note"         // app.html:555

        static let closeSheet = "Close"                // app.html:568

        /// Text format (app.html:565-595)
        enum Format {
            static let title = "Text format"           // app.html:567
            static let typeGroup = "Line type"         // app.html:572
            static let markGroup = "Emphasis"          // app.html:579
            static let fontGroup = "Typeface"          // app.html:585
            static let alignGroup = "Alignment"        // app.html:590

            static let types = ["p", "h", "ul", "ol", "check"]
            static func typeLabel(_ t: String) -> String {
                switch t {
                case "p":     return "Body"            // app.html:573
                case "h":     return "Heading"         // app.html:574
                case "ul":    return "Bullet"          // app.html:575
                case "ol":    return "Number"          // app.html:576
                case "check": return "Checkbox"        // app.html:577
                default:      return t
                }
            }

            static let marks = ["b", "i", "u", "strike"]
            static func markLabel(_ m: String) -> String {
                switch m {
                case "b":      return "B"              // app.html:580
                case "i":      return "I"              // app.html:581
                case "u":      return "U"              // app.html:582
                case "strike": return "S"              // app.html:583
                default:       return m
                }
            }

            static func fontLabel(_ f: String) -> String {
                switch f {
                case "baloo": return "Baloo"           // app.html:586
                case "sans":  return "Sans"            // app.html:587
                case "mono":  return "Mono"            // app.html:588
                default:      return f
                }
            }

            static let aligns = ["left", "center", "right"]
            static func alignLabel(_ a: String) -> String {
                switch a {
                case "left":   return "Left"           // app.html:591
                case "center": return "Centre"         // app.html:592
                case "right":  return "Right"          // app.html:593
                default:       return a
                }
            }
        }

        /// Paper (app.html:597-616)
        enum Paper {
            static let title = "Paper"                 // app.html:599
            static let group = "Paper colour"          // app.html:607

            static func label(_ p: String) -> String {
                switch p {
                case "lavender": return "Lavender"     // app.html:608
                case "violet":   return "Violet"       // app.html:609
                case "blue":     return "Blue"         // app.html:610
                case "orange":   return "Orange"       // app.html:611
                case "red":      return "Red"          // app.html:612
                case "stone":    return "Stone"        // app.html:613
                case "white":    return "Plain"        // app.html:614
                default:         return p
                }
            }
        }

        /// Reminder (app.html:618-654; app.js:4899-4940)
        enum Remind {
            static let title = "Reminder"              // app.html:620
            static let day = "Day"                     // app.html:626
            static let time = "Time"                   // app.html:630
            static let repeats = "Repeat"              // app.html:634
            static let clear = "Clear"                 // app.html:643
            static let save = "Save"                   // app.html:644

            static let rules = ["", "daily", "weekly", "monthly"]
            static func ruleLabel(_ r: String) -> String {
                switch r {
                case "daily":   return "Every day"     // app.html:637
                case "weekly":  return "Every week"    // app.html:638
                case "monthly": return "Every month"   // app.html:639
                default:        return "Never"         // app.html:636
                }
            }

            /// `Reminder ${when}${every}` — the editor line under the
            /// paper, 12.5px in the accent.
            static func line(_ when: String, _ every: String) -> String {
                "Reminder \(when)\(every)"
            }                                          // app.js:4906

            /// The tail of that line. Empty for a reminder that does not
            /// come round again.
            static func every(_ rule: String) -> String {
                switch rule {
                case "daily":   return ", every day"   // app.js:4905
                case "weekly":  return ", every week"  // app.js:4905
                case "monthly": return ", every month" // app.js:4905
                default:        return ""
                }
            }
        }

        /// Pictures (app.js:4820-4896)
        enum Pictures {
            static let removeAria = "Remove this picture"   // app.js:4835

            /// Raised twice: once when there is no room at all, and again
            /// when more were picked than there was room for.
            static func full(_ max: Int) -> String {
                "A note holds \(max) pictures."
            }                                               // app.js:4875, 4894

            static let noRoom = "No room left on this device for that picture."   // app.js:4891
        }
    }

    // MARK: - The two characters the web writes as escapes

    /* app.js builds several of the lines below by concatenating string
       literals around a —, and app.html writes the same character as
       an entity. Neither form is the character, so the sentences here are
       assembled the way app.js assembles them and these two constants
       stand in for the escape. Checks/copy.sh then greps each literal
       fragment against the source it came from and the dash against the
       many places the web writes it out. */

    /// `—`, with the spaces the web puts either side of it.
    static let emDash = " — "      // app.js:3686, 2721

    /// `&hellip;` in app.html, a real ellipsis everywhere in app.js.
    static let ellipsis = "…"      // app.js:1666

    // MARK: - Settings (app.html:662-850; app.js:3944-3964)

    /// The Subscription group, the Plans screen and the two donate tins
    /// are deliberately absent — App Store 3.1.1, and nothing in the app
    /// is gated, so there is no feature behind them to lose (design §4,
    /// decision 4). No copy for them is carried here either: a string in
    /// this file is a promise that something draws it.
    enum Settings {
        static let backAria = "Back to home"    // app.html:664
        static let back = "Home"                // app.html:666
        static let title = "Settings"           // app.html:668

        // the captions over the groups
        static let capAccount = "Account"       // app.html:697
        static let capSync = "Sync calendars"   // app.html:763
        static let capAbout = "About"           // app.html:796

        // the one row in the Account group this build draws
        static let profileRow = "Profile"                 // app.html:703
        static let greetingPlain = "Hey there."           // app.html:704, app.js:3922
        static func greeting(name: String) -> String {
            "Hey \(name)."
        }                                                 // app.js:3922

        // the About group, in order
        static let feedbackRow = "Send feedback"                  // app.html:805
        static let feedbackNote = "Tell us what to fix."          // app.html:806
        static let shareRow = "Share with friends"                // app.html:813
        static let shareNote = "Someone you know has this too."   // app.html:814
        static let privacyRow = "Privacy policy"                  // app.html:821
        static let termsRow = "Terms"                             // app.html:830

        /* paintLocalNote (app.js:3677-3693). Three readings of the same
           question — where does this actually live — and which one is
           true depends on the account and the calendar, so the note is
           re-drawn whenever either of them moves. Each is written the way
           app.js writes it, one Swift literal per JS literal, so every
           fragment greps. */

        /// Signed in.
        static let localSignedIn =
            "Your lists are on this device and in your account, which is how they "
            + "reach your other devices. Your name, your face and the calendar link "
            + "stay on this device only."                 // app.js:3683-3685

        /// Signed out, with the calendar on offer.
        static let localCalendar =
            "Your tasks live in this browser only" + emDash + "no account, no server. The "
            + "calendar link above is the one exception, and only while it is "
            + "switched on."                              // app.js:3686-3688

        /// Signed out, and no calendar either.
        static let localAlone =
            "This lives in this browser only" + emDash + "no account, no sync, nothing "
            + "leaves the device."                        // app.js:3689-3690

        static let version = "v0.1.0"   // app.html:844
        static let versionTag = "Beta"  // app.html:844
    }

    // MARK: - Profile (app.html:855-887; app.js:3875-3942)

    /// `Copy.Profile`, which shadows the store's `Profile` inside this
    /// file and nowhere else — the same arrangement `Copy.Theme` already
    /// has with the palette.
    enum Profile {
        static let backAria = "Back to settings"   // app.html:860
        static let back = "Settings"               // app.html:862
        static let title = "Profile"               // app.html:864

        static let nameLabel = "What should I call you?"   // app.html:876
        static let namePlaceholder = "Your name"           // app.html:878
        /// `maxlength="24"`, and `slice(0, 24)` again behind it because a
        /// paste beats an attribute (app.html:877, app.js:5570).
        static let nameMax = 24

        static let pickLabel = "Pick a face"    // app.html:882
        static let pickAria = "Pick an avatar"  // app.html:883

        static func useFace(_ face: String) -> String {
            "Use \(face) as your face"
        }                                       // app.js:3937

        static let hint = "This name and face are on this device only. They are not "
            + "part of an account and they do not travel with your lists."   // app.html:886-887
    }

    // MARK: - Feedback (app.html:893-968; app.js:2654-2724)

    /// The tins are absent here for the same reason the plans are — see
    /// `Settings`. `MYADHD_DONATE_URL` is forced empty in the shell
    /// anyway (BridgeScript), so this screen has never drawn them on iOS.
    enum Feedback {
        static let backAria = "Back to settings"   // app.html:894
        static let back = "Settings"               // app.html:896
        static let title = "Feedback"              // app.html:898

        static let heading = "Tell us what to fix"   // app.html:910
        static let lede = "Your ADHD is already halfway through a list of things "
            + "this app should do differently. We would genuinely like that list. "
            + "No name, no account" + emDash + "just say it."   // app.html:911-913

        static let label = "What would make this better?"   // app.html:917
        static let placeholder = "the thing that annoyed you, the feature you keep "
            + "reaching for, the bit that made no sense" + ellipsis   // app.html:921

        /// `maxlength="2000"`, and the counter says so out loud.
        static let max = 2000
        static func counter(_ trimmed: Int) -> String {
            "\(trimmed) / 2000"
        }                                          // app.js:2673

        /// Under this many characters the button is dead and a press only
        /// moves the caret back into the box.
        static let minimum = 4                     // app.js:2674, 2680

        static let send = "Send it"                // app.html:928
        static let sending = "Sending…"            // app.js:2683

        /// `<strong>One a day.</strong>` and the rest of the paragraph.
        static let noteStrong = "One a day."       // app.html:933
        static let noteRest = " Keeps the spam out, and it means the notes "
            + "that land are the ones someone actually thought about. Nothing you send "
            + "is tied to you" + emDash + "no name, no account, no email."   // app.html:933-935

        static let thanksTitle = "Got it. Thank you."   // app.html:950

        /// The default on the card, and what a 2xx leaves behind.
        static let thanksToday =
            "That is your one for today — the box opens again tomorrow."   // app.js:2707
        /// A 429: the server already had one from here today. The device
        /// is spent either way, so this counts as a send.
        static let thanksAlready =
            "Looks like one already came through from here today — the box opens again tomorrow."   // app.js:2706

        // the three failures, each of which becomes `Could not send — …`
        static let noSignal = "no signal. Your note is still here"      // app.js:2696
        static let notWired = "the feedback box is not wired up yet"    // app.js:2714
        static let broke = "something broke on our end"                 // app.js:2715

        static func failed(_ message: String) -> String {
            "Could not send — \(message)."
        }                                                               // app.js:2718
    }

    // MARK: - Share with friends (app.js:4108-4128)

    enum Share {
        static let title = "my.adhd"   // app.js:4119
        static let text = "my.adhd — dump everything on your mind, get back one thing to do."   // app.js:4111
        static let url = "https://myadhd.my"   // app.js:4110
    }

    // MARK: - The account card (app.html:714-753; app.js:3593-3826)
    //
    // Two of these come from cloud.js rather than app.js — the sync's own
    // error strings, which the hint line prints verbatim. They are why
    // `Checks/copy.sh` now greps cloud.js and auth.js as well.
    //
    // Every literal here breaks where the JavaScript breaks it. app.js
    // builds most of these sentences out of two or three concatenated
    // strings, and a Swift constant holding the joined-up sentence would
    // not grep back to any single line of the source.

    enum Account {

        // signed out (app.js:3609-3620)
        static let face = "\u{1F464}"                  // app.js:3609
        static let outTitle = "Just this device"       // app.html:718, app.js:3610
        static let outState = "Not signed in"          // app.html:719, app.js:3611
        static let outNote =
            "Your lists live in this browser alone, so your phone and your laptop "
            + "each keep a separate one. Sign in and they become the same list — and "
            + "the calendar link stops asking you to reconnect."   // app.js:3613-3615
        static let signIn = "Sign in with Google"      // app.html:723, app.js:3616
        /// The button while Safari is opening — the same words the signup
        /// offer writes (app.js:5559).
        static let takingYou = "Taking you to Google…"   // app.js:3700

        // signed in (app.js:3624-3671)
        static let inFace = "\u{2713}"                 // app.js:3624
        static let inTitle = "Signed in"               // app.js:3626

        /// The note gains a sentence when the calendar is linked and not
        /// stale, because this button drives that too.
        static func inNote(pushesBoth: Bool) -> String {
            "Your lists sync to every device you sign in on, and the calendar link "
                + (pushesBoth
                   ? "renews itself. Sync now pushes both."
                   : "renews itself.")
        }                                              // app.js:3631-3636

        static let syncNow = "Sync now"                // app.js:3657
        static let syncing = "Syncing…"                // app.js:3657
        static let signOut = "Sign out"                // app.html:729

        // the hint line, which doubles as the sync's only report
        static let bringingUpToDate = "Bringing this device up to date…"   // app.js:3666
        static let signingOutIsSafe = "Signing out leaves this device’s copy alone."   // app.js:3670

        /// `Your lists are not travelling right now${err ? ` — ${err}` : ''}. It keeps trying.`
        static func notTravelling(_ reason: String?) -> String {
            "Your lists are not travelling right now"
                + (reason.map { " — " + $0 } ?? "")
                + ". It keeps trying."
        }                                              // app.js:3668

        // cloud.js's own two, printed by the line above
        static let unreachable = "could not reach the server"   // cloud.js:147
        static func serverAnswered(_ status: Int) -> String {
            "the server answered \(status)"
        }                                              // cloud.js:237

        // syncEverything's answers (app.js:3735-3748)
        static let listsUnreachable = "Could not reach your lists. It keeps trying."   // app.js:3735
        static let googleSilent = "Lists are up to date. Google did not answer — it keeps trying."   // app.js:3737
        static let googleStale = "Lists are up to date. Google wants you to sign in again."   // app.js:3741

        static func cameOver(_ added: Int) -> String {
            "Up to date. " + (added == 1 ? "1 task" : "\(added) tasks") + " came over."
        }                                              // app.js:3746
        static let otherDeviceRemoved = "Up to date. Your other device had removed some."   // app.js:3747
        static let alreadyUpToDate = "Already up to date."   // app.js:3748

        // signing out, and coming back (app.js:3750, 3866)
        static let signedOut = "Signed out. Your lists are still here."   // app.js:3750
        static let signedIn = "Signed in. Bringing your lists together…"   // app.js:3866

        // ending the account (app.html:742-752; app.js:3777-3826)
        static let delete = "Delete account"           // app.html:744
        static let cancel = "Cancel"                   // app.html:748
        static let firstAsk =
            "Delete your account? Your lists stay on this device. What goes is the "
            + "copy that lets your devices meet — and the Google Calendar link with it."   // app.js:3790-3791
        static let firstGo = "Yes, delete my account"  // app.js:3792
        static let lastAsk =
            "Last check — this ends the account for good. Signing in again starts a "
            + "new empty one; it cannot bring this one back."   // app.js:3796-3797
        static let lastGo = "Delete my account"        // app.js:3798
        static let deleting = "Deleting…"              // app.js:3801
        static let deleteFailed = "Could not delete the account. Nothing has changed."   // app.js:3815
        static let deleted = "Account deleted. Your lists are still on this device."   // app.js:3823

        /// `setTimeout(resetAcctDelete, 20000)` — the same disarm the
        /// lists' danger zone has (app.js:3824).
        static let disarmAfter: TimeInterval = 20
    }
}
