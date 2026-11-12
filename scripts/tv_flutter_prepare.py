#!/usr/bin/env python3
"""Readies a copy of AnymeX+ for LG's flutter-webOS SDK (CI only).

flutter-webOS is Flutter 3.38 / Dart 3.10, a step behind the app's Flutter.
Each hosted package is held to the version the app uses now or an older one
of the same major version, so pub can step back only where a package needs
the newer Dart, without API changes. Never run on the real build: it
rewrites pubspec.yaml in place.
"""
import os
import re

locked = {}
name, cur = None, {}
for line in open("pubspec.lock"):
    m = re.match(r"^  ([a-z0-9_]+):\s*$", line)
    if m:
        name = m.group(1)
        cur = locked.setdefault(name, {})
        continue
    m = re.match(r'^    (dependency|source|version): "?([^"\n]+)"?', line)
    if m and name:
        cur[m.group(1)] = m.group(2).strip()


def floor(v):
    parts = re.match(r"(\d+)\.(\d+)", v)
    major, minor = int(parts.group(1)), int(parts.group(2))
    return "%d.0.0" % major if major > 0 else "0.%d.0" % minor


lines = open("pubspec.yaml").read().split("\n")
out, section, changed = [], "", []
for line in lines:
    m = re.match(r"^(\w[\w_]*):\s*$", line)
    if m:
        section = m.group(1)
    if section in ("dependencies", "dev_dependencies"):
        m = re.match(r"^(\s+)([a-z0-9_]+):\s*([\^0-9][^\s#]*)", line)
        if m and m.group(2) in locked and locked[m.group(2)].get("source") == "hosted":
            v = locked[m.group(2)]["version"]
            line = '%s%s: ">=%s <=%s"' % (m.group(1), m.group(2), floor(v), v)
            changed.append("%s <= %s" % (m.group(2), v))
    out.append(line)
# LG's webOS parts of the plugins the app uses (path_provider etc.).
LG = "https://github.com/lg-flutter-webos/plugins.git"
lg = ["path_provider", "shared_preferences", "url_launcher", "package_info_plus",
      "device_info_plus", "connectivity_plus", "video_player"]
extra = []
for name in lg:
    extra += ["    %s_webos:" % name, "        git:", "            url: %s" % LG,
              "            path: packages/%s" % name, "            ref: main"]
extra += ['    video_player: ">=2.9.3 <3.0.0"']
i = out.index("dependencies:")
out[i + 1:i + 1] = extra
open("pubspec.yaml", "w").write("\n".join(out))
os.remove("pubspec.lock")
print("held to the app's versions or older (same major):")
print("\n".join(changed))
