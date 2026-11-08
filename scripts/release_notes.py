"""Turn `git log` into release-note bullets.

Each commit's subject is a bullet; lines in the commit body that start with
"- " become sub-bullets, so a commit can list everything it changed.
Merges, "[skip ci]" and attribution lines are left out.

Usage: git log RANGE --no-merges --format='%s%x1f%b%x1e' | python3 scripts/release_notes.py
"""
import sys

out = []
for record in sys.stdin.read().split("\x1e"):
    record = record.strip("\n")
    if not record.strip():
        continue
    subject, _, body = record.partition("\x1f")
    subject = subject.replace(" [skip ci]", "").strip()
    if not subject or subject.startswith("Merge"):
        continue
    out.append(f"- {subject}")
    in_bullet = False
    for line in body.splitlines():
        if line.startswith("- "):
            out.append(f"  {line.rstrip()}")
            in_bullet = True
        elif in_bullet and line.startswith("  ") and line.strip():
            # wrapped continuation of the bullet above
            out[-1] += " " + line.strip()
        else:
            in_bullet = False
print("\n".join(out))
