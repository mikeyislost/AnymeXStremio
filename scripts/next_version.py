"""Next AnymeX+ release version: single-digit X.Y.Z that rolls over.

Usage: next_version.py <pubspec version> [<latest release version>]
  1.0.9  -> 1.1.0      1.9.9 -> 2.0.0      1.0.10 (old tag) -> treated as 1.1.0
If the pubspec version is higher than the next one, it is used as-is.
"""
import sys


def norm(v):
    a, b, c = (int(x) for x in v.split("."))
    b += c // 10
    c %= 10
    a += b // 10
    b %= 10
    return (a, b, c)


def bump(v):
    a, b, c = v
    c += 1
    if c > 9:
        c, b = 0, b + 1
    if b > 9:
        b, a = 0, a + 1
    return (a, b, c)


base = norm(sys.argv[1])
last = sys.argv[2].strip() if len(sys.argv) > 2 else ""
nxt = bump(norm(last)) if last else base
print(".".join(str(x) for x in max(base, nxt)))
