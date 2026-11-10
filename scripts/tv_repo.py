#!/usr/bin/env python3
"""Writes a Homebrew Channel repository file for the AnymeX+ TV app.

    tv_repo.py <ipk file> <ipk download url> <tv version> <icon url> <output json>

Adding that file's link in Homebrew Channel (Settings -> Add repository) lets
the TV install and update AnymeX+ TV by itself.
"""
import hashlib
import json
import os
import sys


def build(ipk_path, ipk_url, version, icon_url):
    data = open(ipk_path, "rb").read()
    desc = ("AnymeX+ on the TV: pairs with AnymeX+ on your phone, which works as its "
            "remote. Test build.")
    manifest = {
        "id": "com.mikeyislost.anymexplus.tv",
        "version": version,
        "type": "web",
        "title": "AnymeX+ TV",
        "appDescription": desc,
        "iconUri": icon_url,
        "sourceUrl": "https://github.com/mikeyislost/AnymeXStremio",
        "rootRequired": False,
        "ipkUrl": ipk_url,
        "ipkHash": {"sha256": hashlib.sha256(data).hexdigest()},
        "ipkSize": len(data),
    }
    return {
        "paging": {"page": 1, "count": 1, "maxPage": 1, "itemsTotal": 1},
        "packages": [{
            "id": manifest["id"],
            "title": manifest["title"],
            "iconUri": icon_url,
            "manifest": manifest,
            "pool": "main",
            "shortDescription": desc,
        }],
    }


if __name__ == "__main__":
    ipk, url, version, icon, out = sys.argv[1:6]
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    json.dump(build(ipk, url, version, icon), open(out, "w"), indent=2)
    print(open(out).read())
