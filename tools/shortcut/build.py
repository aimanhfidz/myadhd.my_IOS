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
V2" (re-decoded 2026-11-01 from the link the user shared): the app decides
the mode, the shortcut only branches on it. The automations ride inside
the shortcut too, but iOS does not install them; see README.

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
#   v3  2026-11-01  re-cut from Ink's V2 as it stood that day: same / pair /
#                   blur / redraw, and always switch to the wallpaper set
VERSION = 3
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


def otherwise(group):
    return {
        "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
        "WFWorkflowActionParameters": {
            "GroupingIdentifier": uid(group),
            "WFControlFlowMode": 1,
            "UUID": uid(group + ".else"),
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


LOCK = ["Lock Screen"]
HOME = ["Home Screen"]
BOTH = ["Lock Screen", "Home Screen"]


def set_wallpaper(label, poster=None, screens=LOCK, blur=False,
                  picture=("picture", "Update my.adhd wallpaper")):
    """Set Wallpaper Photo. No preview: an automation that stops to ask is
    not an automation. No smart crop: the picture is drawn to this phone's
    own size and a crop would cut the design's edges. Legibility blur only
    where the page asked for it ("blur"), and Ink only ever blurs a set
    that includes the Home Screen."""
    params = {
        "UUID": uid(label),
        "WFInput": attachment(*picture),
        "WFWallpaperLocation": list(screens),
        "WFWallpaperShowPreview": False,
        "WFWallpaperSmartCrop": False,
        "WFWallpaperLegibilityBlur": blur,
    }
    if poster:
        params["WFSelectedPoster"] = attachment(poster, "Wallpaper")
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.wallpaper.set",
            "WFWorkflowActionParameters": params}


def switch_to(label):
    """Switch Between Wallpapers, to the one just set. Ink does it on every
    run now, not only on a redraw: Set Wallpaper Photo may write to a
    wallpaper that is not the one showing, and this makes it the one."""
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.posters.switch",
            "WFWorkflowActionParameters": {"UUID": uid(label + ".switch"),
                                           "WFPoster": attachment(label, "Wallpaper")}}


def set_maybe_twice(mode, group, label, poster=None, **kw):
    """Set, and on "redraw" set again on the wallpaper that came back —
    Ink's repaint, for a lock screen that keeps showing the old picture.
    A Home Screen set already names the lock screen's wallpaper, and its
    second pass names the same one, as Ink's does."""
    return [
        set_wallpaper(label, poster=poster, **kw),
        if_contains(group, *mode, "redraw"),
        set_wallpaper(label + ".again", poster=poster or label, **kw),
        end_if(group),
    ]


def actions(team):
    mode = ("mode", "my.adhd wallpaper mode")
    home = ("home.picture", "my.adhd home screen")
    return [
        # 1. Ask the app. It answers "skip", or "set"/"redraw" followed by
        #    which screens: "same", or "pair" (WallpaperMode.answer). Ink's
        #    shortcut has no skip; ours keeps it, because its triggers fire
        #    many times a day and an identical wallpaper should not flash.
        app_intent(team, "WallpaperModeIntent", "mode"),
        if_contains("if.skip", *mode, "skip"),
        {"WFWorkflowActionIdentifier": "is.workflow.actions.exit",
         "WFWorkflowActionParameters": {}},
        end_if("if.skip"),

        # 2. Draw it. Throws on an unreadable store, which stops the run and
        #    leaves yesterday's picture where it is.
        app_intent(team, "WallpaperIntent", "picture"),

        # 3a. "same": one picture on both screens, blurred or not.
        if_contains("if.same", *mode, "same"),
          if_contains("if.same.blur", *mode, "blur"),
            *set_maybe_twice(mode, "if.same.blur.redraw", "same.blur", screens=BOTH, blur=True),
            switch_to("same.blur"),
          otherwise("if.same.blur"),
            *set_maybe_twice(mode, "if.same.redraw", "same", screens=BOTH),
            switch_to("same"),
          end_if("if.same.blur"),

        # 3b. Otherwise the Lock Screen alone, and with "pair" the plain
        #     ground on the Home Screen of that same wallpaper, so the
        #     design never sits behind the app icons.
        otherwise("if.same"),
          *set_maybe_twice(mode, "if.lock.redraw", "lock"),
          if_contains("if.pair", *mode, "pair"),
            app_intent(team, "WallpaperHomeIntent", "home.picture"),
            if_contains("if.pair.blur", *mode, "blur"),
              *set_maybe_twice(mode, "if.pair.blur.redraw", "home.blur", poster="lock",
                               screens=HOME, blur=True, picture=home),
            otherwise("if.pair.blur"),
              *set_maybe_twice(mode, "if.pair.redraw", "home", poster="lock",
                               screens=HOME, picture=home),
            end_if("if.pair.blur"),
          end_if("if.pair"),
          switch_to("lock"),
        end_if("if.same"),

        # 4. Only reached if every Set Wallpaper Photo succeeded, which is
        #    what lets the app say "working" and mean it (WallpaperHealth).
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
        # WallpaperPing's quiet notification, as Ink filters its own: by
        # what the body says. Change that body and this stops matching.
        {"WFTriggerIdentifier": "WFNotificationTrigger",
         "WFTriggerUUID": uid("trigger.notification"),
         "WFTriggerSerializedParameters": {
             "SelectedApps": [app],
             "Conditions": {
                 "Value": {
                     "WFActionParameterFilterPrefix": 1,
                     "WFContentPredicateBoundedDate": False,
                     "WFActionParameterFilterTemplates": [
                         {"Operator": 0, "Values": {"Body": "lock screen"},
                          "Removable": True, "Property": "Body"},
                     ],
                 },
                 "WFSerializationType": "WFContentPredicateTableTemplate",
             },
         }},
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


def check_app_name():
    """The Home library's Update button runs the shortcut by name
    (AppConfig.wallpaperShortcutName). Refuse to build one it cannot find."""
    conf = (ROOT / "MyADHD" / "AppConfig.swift").read_text()
    if f'"{NAME}"' not in conf:
        sys.exit(f'AppConfig.wallpaperShortcutName is not "{NAME}". Change both together.')


def main():
    check_app_name()
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
