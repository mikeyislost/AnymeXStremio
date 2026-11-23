#!/usr/bin/env python3
"""Adds or replaces one app in the Flutter TV Homebrew repository file, and
drops retired test apps (the separate Yumori test and the Back test).

    tv_flutter_repo.py <repo json> <ipk> <ipk url> <app id> <title> <version> <icon url> <description>
"""
import hashlib
import json
import os
import sys

repo_path, ipk, url, app_id, title, version, icon, desc = sys.argv[1:9]
RETIRED = {"com.mikeyislost.yumori.tv", "com.mikeyislost.anymexplus.fluttertv.back"}
SOURCE = "https://github.com/" + os.environ.get("GITHUB_REPOSITORY", "mikeyislost/Yumori")
repo = {"packages": []}
if os.path.exists(repo_path) and os.path.getsize(repo_path) > 0:
    repo = json.load(open(repo_path))
data = open(ipk, "rb").read()
entry = {
    "id": app_id, "title": title, "iconUri": icon, "pool": "main", "shortDescription": desc,
    "manifest": {
        "id": app_id, "version": version, "type": "native", "title": title, "appDescription": desc,
        "iconUri": icon, "sourceUrl": SOURCE, "rootRequired": False,
        "ipkUrl": url, "ipkHash": {"sha256": hashlib.sha256(data).hexdigest()}, "ipkSize": len(data),
    },
}
pkgs = [p for p in repo.get("packages", []) if p.get("id") != app_id and p.get("id") not in RETIRED]
pkgs.insert(0, entry)
n = len(pkgs)
json.dump({"paging": {"page": 1, "count": n, "maxPage": 1, "itemsTotal": n}, "packages": pkgs},
          open(repo_path, "w"), indent=2)
print(open(repo_path).read())
