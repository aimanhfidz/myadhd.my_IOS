# What's New

The text App Store Connect shows under **What's New in This Version**, one
entry per build, newest first. Each entry is exactly what gets pasted.

**Why this file exists.** Guideline 2.3.12: an update must describe what
actually changed in its What's New text, and App Store Connect refuses a
build number it has already seen. So every build carries its own entry, and
the MyADHD target's "What's New" build phase (`tools/release/whatsnew.sh`)
checks it on every build — a warning on ⌘R, an error that stops the archive.

**The routine:**

1. `tools/release/bump.sh` (or `bump.sh 1.1` for a new version) moves the
   build number in every target and opens an empty entry here.
2. Write what changed, for a person, not a commit log: what they can now do,
   what works better, what was broken and is not. No "bug fixes and
   performance improvements" on its own. Under 4,000 characters. No clinical
   claims (BRAND.md rule 8), and English, like the app.
3. Archive and upload. Then change that entry's `Uploaded: no` to
   `Uploaded: <date>` and commit — from then on that build number is spent.

The first version (1.0) has no What's New field in App Store Connect; its
entry is the record of what shipped.

## 1.0 (2)
Uploaded: no

The first version of my.adhd for iPhone.

- Type or say everything on your mind. It comes back as tasks, each with a two-minute first step, and one thing to do now.
- Works offline: your lists stay on your phone, and a dump is still sorted with no signal.
- Reminders at a task's time that show its first step, and nudges at the pace you choose.
- Widgets for the home and lock screen: Today, Next up, Timeline, Agenda, Month, Matrix and Done. Tick a task off without opening the app.
- The task you are on, as a Live Activity on the lock screen and in the Dynamic Island.
- Dump a thought from Siri, the Action Button, Control Centre or the share sheet, including the words in a photo.
- An optional lock-screen wallpaper of your day, kept up to date by a Shortcut.
- Optional Google sign-in to keep your lists in step with myadhd.my and put dated tasks on Google Calendar.
