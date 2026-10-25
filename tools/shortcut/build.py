#!/usr/bin/env python3
"""Build the "my.adhd Lock Screen" shortcut, signed, ready to import.

    python3 -I tools/shortcut/build.py            # build + sign
    python3 -I tools/shortcut/build.py --open     # ...and import it on this Mac

Apple gives no API for making a shortcut, and building one by hand on a
phone is how a three-action shortcut ends up with Show Preview on. So the
shortcut is written here as the plist Shortcuts itself saves, then signed
with `shortcuts sign --mode anyone`, which makes a file any iPhone will
import. Share its iCloud link from the Shortcuts app afterwards and paste
it into AppConfig.wallpaperShortcutURL.

What it does, and why each step is there, is in the header of
MyADHD/WallpaperIntent.swift. The shape follows Ink's "Refresh Lock Screen
V2": the app decides the mode, the shortcut only branches on it, and the
automations ship inside the shortcut instead of being built by hand.

The team id is read from Local.xcconfig, which is git-ignored, and goes
only into build/, which is git-ignored too. Nothing tracked writes it down.
"""

import plistlib
import re
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build"
# Bump VERSION on every change to what the shortcut does. Shortcuts cannot
# replace an installed shortcut, so each version lands beside the last one,
# and the number in the name is how anyone tells them apart: the
# automations have to be pointed at the new one by hand.
#   v1  2026-10-26  mode, set, redraw, confirm
#   v2  2026-10-26  Lock Screen only: the Home Screen gets the plain ground
VERSION = 2
NAME = f"my.adhd Lock Screen v{VERSION}"
BUNDLE = "my.adhd.ios"
APP_NAME = "my.adhd"

# Stable UUIDs, so two builds of the same shortcut diff clean.
NS = uuid.UUID("5d2c1f0e-7b3f-4e4a-9f75-c03a2d33e4f2")


def uid(label):
    return str(uuid.uuid5(NS, label)).upper()


def team_id():
    conf = ROOT / "Local.xcconfig"
    if not conf.exists():
        sys.exit("Local.xcconfig is missing; it holds DEVELOPMENT_TEAM. See CLAUDE.md.")
    m = re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*(\w+)", conf.read_text(), re.M)
    if not m:
        sys.exit("No DEVELOPMENT_TEAM in Local.xcconfig.")
    return m.group(1)


# ---------------------------------------------------------------- actions

def app_intent(team, intent, label):
    return {
        "WFWorkflowActionIdentifier": f"{BUNDLE}.{intent}",
        "WFWorkflowActionParameters": {
            "UUID": uid(label),
            "AppIntentDescriptor": {
                "TeamIdentifier": team,
                "BundleIdentifier": BUNDLE,
                "AppIntentIdentifier": intent,
                "Name": APP_NAME,
            },
        },
    }


def output(label, name):
    return {"OutputUUID": uid(label), "Type": "ActionOutput", "OutputName": name}


def attachment(label, name):
    return {"Value": output(label, name), "WFSerializationType": "WFTextTokenAttachment"}


def if_contains(group, label, name, text):
    """If <output> contains <text>. 99 is Shortcuts' "contains"."""
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
        "WFWorkflowActionParameters": {
            "GroupingIdentifier": uid(group),
            "WFControlFlowMode": 0,
            "WFCondition": 99,
            "WFConditionalActionString": text,
            "WFInput": {"Type": "Variable", "Variable": attachment(label, name)},
        },
    }


def end_if(group):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
        "WFWorkflowActionParameters": {
            "GroupingIdentifier": uid(group),
            "WFControlFlowMode": 2,
            "UUID": uid(group + ".end"),
        },
    }


def set_wallpaper(label, poster=None, screen="Lock Screen",
                  picture=("picture", "Update my.adhd wallpaper")):
    """Set Wallpaper Photo, one screen at a time. No preview: an automation
    that stops to ask is not an automation. No smart crop: the picture is
    drawn to this phone's own size and a crop would cut the matrix's edges.
    No legibility blur: the cards carry their own contrast, and the Home
    Screen is the person's own photo, which they chose to look like that."""
    params = {
        "UUID": uid(label),
        "WFInput": attachment(*picture),
        "WFWallpaperLocation": [screen],
        "WFWallpaperShowPreview": False,
        "WFWallpaperSmartCrop": False,
        "WFWallpaperLegibilityBlur": False,
    }
    if poster:
        params["WFSelectedPoster"] = attachment(poster, "Wallpaper")
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.wallpaper.set",
            "WFWorkflowActionParameters": params}


def actions(team):
    mode = ("mode", "my.adhd wallpaper mode")
    return [
        # 1. Ask the app. It answers skip, set or redraw (WallpaperMode.swift).
        app_intent(team, "WallpaperModeIntent", "mode"),

        # 2. Nothing moved since the last confirmed picture: stop, so the
        #    frequent triggers never flash an identical wallpaper.
        if_contains("if.skip", *mode, "skip"),
        {"WFWorkflowActionIdentifier": "is.workflow.actions.exit",
         "WFWorkflowActionParameters": {}},
        end_if("if.skip"),

        # 3. Draw it. Throws on an unreadable store, which stops the run and
        #    leaves yesterday's picture where it is.
        app_intent(team, "WallpaperIntent", "picture"),

        # 4. Put it on the lock screen.
        set_wallpaper("set"),

        # 5. Ink's repaint: set again on the wallpaper that came back, and
        #    switch to it. Only when the page's Force a redraw is on.
        if_contains("if.redraw", *mode, "redraw"),
        set_wallpaper("set.again", poster="set"),
        {"WFWorkflowActionIdentifier": "is.workflow.actions.posters.switch",
         "WFWorkflowActionParameters": {"UUID": uid("switch"),
                                        "WFPoster": attachment("set", "Wallpaper")}},
        end_if("if.redraw"),

        # 6. Lock Screen only: the Home Screen of the same wallpaper gets the
        #    ground with no boxes. Without it, a pair on "Original" copies the
        #    matrix behind the app icons. Ink's "pair" mode, the same way.
        if_contains("if.home", *mode, "home"),
        app_intent(team, "WallpaperHomeIntent", "home.picture"),
        set_wallpaper("set.home", poster="set", screen="Home Screen",
                      picture=("home.picture", "my.adhd home screen")),
        end_if("if.home"),

        # 7. Only reached if Set Wallpaper Photo succeeded, which is what
        #    lets the app say "working" and mean it (WallpaperHealth.swift).
        app_intent(team, "WallpaperConfirmIntent", "confirm"),
    ]


# --------------------------------------------------------------- triggers

def triggers(team):
    app = {"BundleIdentifier": BUNDLE, "Name": APP_NAME, "TeamIdentifier": team}
    return [
        # First thing in the morning: the day key moves, so this one always
        # really sets.
        {"WFTriggerIdentifier": "WFTimeOfDayTrigger",
         "WFTriggerUUID": uid("trigger.sunrise"),
         "WFTriggerSerializedParameters": {"WFTimeEvent": "sunrise"}},
        # Whatever was just changed in the app is on the lock screen before
        # the phone is locked.
        {"WFTriggerIdentifier": "WFAppInFocusTrigger",
         "WFTriggerUUID": uid("trigger.closed"),
         "WFTriggerSerializedParameters": {"WFAppState": "closed",
                                           "WFSelectedApps": app}},
        # iOS 27: every reminder and nudge my.adhd already sends becomes a
        # refresh. Skip makes the ones that change nothing free.
        {"WFTriggerIdentifier": "WFNotificationTrigger",
         "WFTriggerUUID": uid("trigger.notification"),
         "WFTriggerSerializedParameters": {"SelectedApps": [app]}},
    ]


def shortcut(team):
    return {
        "WFWorkflowName": NAME,
        "WFWorkflowClientVersion": "5037.111",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        # 2071128575 is the violet slot of Shortcuts' fixed palette.
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 2071128575,
                           "WFWorkflowIconGlyphNumber": 61440},
        # Not on the Watch: a watch cannot set a phone's wallpaper.
        "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch"],
        "WFWorkflowInputContentItemClasses": [],
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowImportQuestions": [],
        "WFQuickActionSurfaces": [],
        "WFWorkflowActions": actions(team),
        "WFWorkflowTriggers": triggers(team),
    }


def main():
    team = team_id()
    OUT.mkdir(exist_ok=True)
    raw = OUT / "my.adhd-lock-screen.shortcut"
    # Shortcuts names an import after the file, not WFWorkflowName.
    signed = OUT / f"{NAME}.shortcut"
    with raw.open("wb") as f:
        plistlib.dump(shortcut(team), f, fmt=plistlib.FMT_BINARY)
    print(f"built   {raw}")

    signed.unlink(missing_ok=True)
    subprocess.run(["shortcuts", "sign", "--mode", "anyone",
                    "--input", str(raw), "--output", str(signed)], check=True)
    print(f"signed  {signed}")

    if "--open" in sys.argv:
        subprocess.run(["open", str(signed)], check=True)
        print("opened  in Shortcuts: click Add Shortcut")


if __name__ == "__main__":
    main()
