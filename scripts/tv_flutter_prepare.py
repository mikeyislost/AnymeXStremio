#!/usr/bin/env python3
"""Readies a copy of AnymeX+ for LG's flutter-webOS SDK (CI only).

flutter-webOS is Flutter 3.38 / Dart 3.10, a step behind the app's Flutter.
Caret versions become "any" so pub picks the newest versions that still
work with that Dart; the lock file is dropped for the same reason.
Never run on the real build: it rewrites pubspec.yaml in place.
"""
import os
import re

lines = open("pubspec.yaml").read().split("\n")
out, section = [], ""
for line in lines:
    m = re.match(r"^(\w[\w_]*):\s*$", line)
    if m:
        section = m.group(1)
    if section in ("dependencies", "dev_dependencies"):
        line = re.sub(r"^(\s+[a-z0-9_]+):\s*\^[0-9][^\s#]*", r"\1: any", line)
    out.append(line)
open("pubspec.yaml", "w").write("\n".join(out))
if os.path.exists("pubspec.lock"):
    os.remove("pubspec.lock")
print("pubspec.yaml: caret versions → any")
