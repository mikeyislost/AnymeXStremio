"""Tag for the next AnymeX+ beta, in AnymeX's beta format.

Usage: next_beta.py <next stable version>   (existing tags on stdin, one per line)
  no betas of 1.1.2 yet       -> 1.1.2-beta
  v1.1.2-beta exists          -> 1.1.2+1-beta
  v1.1.2+1-beta exists        -> 1.1.2+2-beta
"""
import re
import sys

version = sys.argv[1].strip()
pattern = re.compile(r"^v" + re.escape(version) + r"(?:\+(\d+))?-beta$")
rounds = [int(m.group(1) or 0) for m in (pattern.match(t.strip()) for t in sys.stdin) if m]
if not rounds:
    print(f"{version}-beta")
else:
    print(f"{version}+{max(rounds) + 1}-beta")
