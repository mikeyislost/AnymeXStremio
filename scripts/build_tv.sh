#!/usr/bin/env bash
# Packages the AnymeX+ TV app (tv/) into an .ipk for LG webOS.
#
#   scripts/build_tv.sh <tv version x.y.z> <label shown in the app> <output folder> <file name>
#
# Needs LG's packaging tool: npm install -g @webos-tools/cli
set -euo pipefail

TV_VERSION="$1"; LABEL="$2"; OUT="$3"; NAME="$4"
WORK="$(mktemp -d)"
mkdir -p "$OUT" "$WORK/app" "$WORK/ipk"
cp -R tv/. "$WORK/app/"

# The version goes into the app's manifest and onto its first screen.
python3 - "$WORK/app" "$TV_VERSION" "$LABEL" <<'PY'
import json, sys, pathlib
root, version, label = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
info = json.loads((root / "appinfo.json").read_text())
info["version"] = version
(root / "appinfo.json").write_text(json.dumps(info, indent=2) + "\n")
js = (root / "app.js").read_text()
assert "var APP_VERSION = '0.0.1';" in js, "APP_VERSION line not found in tv/app.js"
(root / "app.js").write_text(js.replace("var APP_VERSION = '0.0.1';", "var APP_VERSION = %s;" % json.dumps(label)))
PY

ares-package --no-minify "$WORK/app" -o "$WORK/ipk"
IPK="$(ls "$WORK/ipk"/*.ipk | head -n 1)"
FINAL="$OUT/$NAME"
cp "$IPK" "$FINAL"
echo "Packaged $(basename "$IPK") -> $FINAL ($(stat -c %s "$FINAL") bytes)"
ar t "$FINAL"
