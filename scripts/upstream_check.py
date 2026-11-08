"""Lists AnymeX commits that AnymeX+ hasn't merged yet (for the weekly check).

Reads the "Based on" commit from ANYMEXPLUS.md, asks GitHub what changed in
RyanYuuki/AnymeX since then, and writes a Markdown report to stdout. Files
that AnymeX+ also changes (from ANYMEXPLUS.md's tables) are flagged, since
those need a careful merge. Prints nothing when there's nothing new.

Needs the `gh` CLI (GH_TOKEN set).
"""
import json
import re
import subprocess
import sys

UPSTREAM = "RyanYuuki/AnymeX"

doc = open("ANYMEXPLUS.md", encoding="utf-8").read()
m = re.search(r"\*\*Based on:\*\* RyanYuuki/AnymeX commit `([0-9a-f]{7,40})`", doc)
if not m:
    sys.exit("Couldn't find the 'Based on' commit in ANYMEXPLUS.md")
base = m.group(1)

hooked = set()
for path in re.findall(r"^\| `([^`]+)`", doc, re.M):
    for p in path.split("`, `"):
        hooked.add(p.strip())


def touched_by_plus(f):
    rel = f[4:] if f.startswith("lib/") else f
    return any(rel == h or rel.startswith(h.rstrip("*").rstrip("/") + "/") for h in hooked)


out = subprocess.run(
    ["gh", "api", f"repos/{UPSTREAM}/compare/{base}...HEAD"],
    capture_output=True, text=True, check=True).stdout
data = json.loads(out)
commits = data.get("commits", [])
if not commits:
    sys.exit(0)

files = data.get("files", [])
lines = [
    f"AnymeX has **{len(commits)} new commit(s)** since `{base}`, the version AnymeX+ is based on.",
    "",
    "### Commits",
]
for c in reversed(commits[-30:]):
    msg = c["commit"]["message"].splitlines()[0]
    date = c["commit"]["author"]["date"][:10]
    lines.append(f"- {date} [`{c['sha'][:7]}`]({c['html_url']}) {msg}")
lines += ["", "### Files changed", "", "| File | Lines | AnymeX+ changes it too |", "| --- | --- | --- |"]
for f in files:
    lines.append(f"| `{f['filename']}` | +{f.get('additions', 0)} −{f.get('deletions', 0)} | "
                 f"{'⚠️ yes, merge carefully' if touched_by_plus(f['filename']) else 'no'} |")
lines += ["", f"[Compare on GitHub](https://github.com/{UPSTREAM}/compare/{base}...HEAD) · "
              "Merging steps are in ANYMEXPLUS.md."]
print("\n".join(lines))
