# reference

Not built. Nothing in here is compiled into any target — `MyADHD/` is a
file-system-synchronised group and this folder is deliberately outside it.

## `BridgeScript.swift`

The JavaScript and CSS the old shell injected into myadhd.my, retired at
the cutover when the app stopped being a web view.

It is kept because it is the **only** written specification of the parts
of the iOS product that never existed on the website: the matrix drawn as
four coloured cards, the hold-and-drag between quadrants, the four-page
"?" walkthrough, the calendar's List / Day / Week / Month modes, the
pull-to-refresh strip and the native headers. Every one of those was
ported into Swift from this file, and several Swift files cite it by line.

It is also part of the haystack `Checks/copy.sh` greps: the sentences
those screens say were written here, not in `app.js`, so deleting it
would fail the check that proves the app's copy is the product's copy.

Delete it only when the screens that came from it are gone.
