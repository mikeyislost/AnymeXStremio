#!/usr/bin/env python3
"""Turn this checkout into the AnymeX+ beta app before building.

The beta is a separate app ("AnymeX+ β") so it installs next to the stable
one, like AnymeX's own beta builds:
  - iOS: bundle ID com.mikeyislost.anymexstremio.beta, name "AnymeX+ β"
  - Windows: own installer ID and folder, own window title (so opening it
    doesn't just focus a running stable app) and own settings folder
  - orange icons with a BETA tag (made by scripts/make_beta_icons.py)

Only CI runs this, on beta builds. Usage: python3 scripts/beta_build.py ios|windows
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BETA = os.path.join(ROOT, "beta")

STABLE_ID = "com.mikeyislost.anymexstremio"
BETA_ID = STABLE_ID + ".beta"
BETA_NAME = "AnymeX+ β"  # AnymeX+ β
BETA_WINDOW_TITLE = "AnymeX+ Beta"
STABLE_INSTALLER_ID = "4bc2c476-2234-43cd-a41b-c76863664520"
BETA_INSTALLER_ID = "2cbdd350-22f0-44df-9146-68d9df9efc63"
BETA_INSTALLER_NAME = "AnymeXStremio Beta"


def edit(rel, pattern, repl, count_expected=None):
    path = os.path.join(ROOT, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    new, n = re.subn(pattern, repl, text)
    if n == 0 or (count_expected is not None and n != count_expected):
        sys.exit(f"beta_build: expected {count_expected or 'some'} match(es) of {pattern!r} in {rel}, found {n}")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    print(f"  {rel}: {n} change(s)")


def copy_tree(rel):
    src = os.path.join(BETA, rel)
    dst = os.path.join(ROOT, rel)
    if os.path.isdir(src):
        for name in os.listdir(src):
            shutil.copy(os.path.join(src, name), os.path.join(dst, name))
    else:
        shutil.copy(src, dst)
    print(f"  {rel}: beta icon(s) copied")


def ios():
    edit("ios/Runner.xcodeproj/project.pbxproj",
         r"PRODUCT_BUNDLE_IDENTIFIER = " + re.escape(STABLE_ID) + ";",
         f"PRODUCT_BUNDLE_IDENTIFIER = {BETA_ID};", 3)
    edit("ios/Runner/Info.plist",
         r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)",
         r"\g<1>" + BETA_NAME + r"\g<2>", 1)
    copy_tree("ios/Runner/Assets.xcassets/AppIcon.appiconset")


def windows():
    # Window title: also what a second launch looks for to focus the
    # running app, so the beta must not share the stable title.
    edit("windows/runner/main.cpp", r'L"AnymeX"', f'L"{BETA_WINDOW_TITLE}"', 2)
    # ProductName decides the app's settings folder in %APPDATA%.
    edit("windows/runner/Runner.rc", r'VALUE "ProductName", "anymex"',
         'VALUE "ProductName", "anymex_beta"', 1)
    edit("windows/runner/Runner.rc", r'VALUE "FileDescription", "anymex"',
         f'VALUE "FileDescription", "{BETA_WINDOW_TITLE}"', 1)
    # Installer: a different ID and name install it separately.
    edit("pubspec.yaml", re.escape(STABLE_INSTALLER_ID), BETA_INSTALLER_ID, 1)
    edit("pubspec.yaml", r"(\n[ \t]+name: )AnymeXStremio\n", r"\g<1>" + BETA_INSTALLER_NAME + "\n", 1)
    copy_tree("windows/runner/resources/app_icon.ico")
    copy_tree("anymex.ico")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else ""
    if target not in ("ios", "windows"):
        sys.exit("usage: beta_build.py ios|windows")
    print(f"Making the {target} beta app:")
    ios() if target == "ios" else windows()
