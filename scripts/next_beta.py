"""Tag for the next AnymeX+ beta: vX.Y.Z-beta, then vX.Y.Z-beta+1, +2, ...

Usage: next_beta.py <next stable version>   (existing tags on stdin, one per line)
  no betas of 1.1.2 yet        -> 1.1.2-beta
  v1.1.2-beta exists           -> 1.1.2-beta+1
  v1.1.2-beta+1 exists         -> 1.1.2-beta+2
Older tags in the AnymeX style (v1.1.2+1-beta) count as rounds too.
"""
import re
import sys

version = sys.argv[1].strip()
v = re.escape(version)
patterns = [
    re.compile(r"^v" + v + r"-beta(?:\+(\d+))?$"),   # v1.1.2-beta+1
    re.compile(r"^v" + v + r"(?:\+(\d+))?-beta$"),   # v1.1.2+1-beta (older)
]
rounds = []
for line in sys.stdin:
    tag = line.strip()
    for p in patterns:
        m = p.match(tag)
        if m:
            rounds.append(int(m.group(1) or 0))
            break
if not rounds:
    print(f"{version}-beta")
else:
    print(f"{version}-beta+{max(rounds) + 1}")
