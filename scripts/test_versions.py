"""Checks for the release version scripts (run by the build before releasing).

python3 scripts/test_versions.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(script, *args, stdin=""):
    out = subprocess.run([sys.executable, os.path.join(HERE, script), *args],
                         input=stdin, capture_output=True, text=True, check=True)
    return out.stdout.strip()


def check(got, want, what):
    if got != want:
        sys.exit(f"FAIL {what}: got {got!r}, want {want!r}")
    print(f"ok   {what} -> {got}")


# Stable versions: single digits that roll over.
check(run("next_version.py", "1.0.0", "1.0.10"), "1.1.1", "after old tag 1.0.10")
check(run("next_version.py", "1.0.0", "1.0.9"), "1.1.0", "1.0.9 rolls over")
check(run("next_version.py", "1.0.0", "1.9.9"), "2.0.0", "1.9.9 rolls over")
check(run("next_version.py", "1.0.0", ""), "1.0.0", "first release")
check(run("next_version.py", "2.0.0", "1.1.4"), "2.0.0", "pubspec can jump ahead")

# Betas: rounds of the next stable version (vX.Y.Z-beta, -beta+1, ...).
check(run("next_beta.py", "1.1.2", stdin="v1.1.1\n"), "1.1.2-beta", "first beta")
check(run("next_beta.py", "1.1.2", stdin="v1.1.2-beta\n"), "1.1.2-beta+1", "second round")
check(run("next_beta.py", "1.1.2", stdin="v1.1.2-beta\nv1.1.2-beta+1\nv1.1.2-beta+3\nv1.1.21-beta\n"),
      "1.1.2-beta+4", "next after highest round")
check(run("next_beta.py", "1.1.1", stdin="v1.1.1-beta\nv1.1.1+1-beta\nv1.1.1+2-beta\n"),
      "1.1.1-beta+3", "continues after older-style tags")
print("all version checks passed")
