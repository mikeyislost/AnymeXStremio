#!/usr/bin/env python3
"""Make the Yumori app icons from assets/images/logo.png (the dreaming tree).

Writes every iOS AppIcon size, the Windows icons (window/taskbar/exe and the
installer) and the root logo.png (Feather source, Discord). Run after changing
the logo, then run scripts/make_beta_icons.py for the beta versions.
"""
import json
import os
import re
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets/images/logo.png")
ICO_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def main() -> None:
    logo = Image.open(SRC).convert("RGB")  # app icons must not be transparent

    rel = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    with open(os.path.join(ROOT, rel, "Contents.json")) as f:
        images = json.load(f)["images"]
    for img in images:
        name = img.get("filename")
        if not name:
            continue
        pt = float(img["size"].split("x")[0])
        px = round(pt * int(img["scale"].rstrip("x")))
        logo.resize((px, px), Image.LANCZOS).save(os.path.join(ROOT, rel, name), optimize=True)

    # Older files in the folder that the list doesn't name (Icon-App-WxH@Nx.png).
    named = {i.get("filename") for i in images}
    for name in os.listdir(os.path.join(ROOT, rel)):
        m = re.match(r"Icon-App-([\d.]+)x[\d.]+@(\d)x\.png$", name)
        if m and name not in named:
            px = round(float(m.group(1)) * int(m.group(2)))
            logo.resize((px, px), Image.LANCZOS).save(os.path.join(ROOT, rel, name), optimize=True)

    ico = logo.resize((256, 256), Image.LANCZOS)
    ico.save(os.path.join(ROOT, "windows/runner/resources/app_icon.ico"), sizes=ICO_SIZES)
    ico.save(os.path.join(ROOT, "anymex.ico"), sizes=ICO_SIZES)

    logo.resize((1024, 1024), Image.LANCZOS).save(os.path.join(ROOT, "logo.png"), optimize=True)

    # TV tiles: crop ~7% so the art's glassy rim and dark rounded corners go
    # (on the TV they looked like a white border and the icon didn't fill).
    w = logo.size[0]
    c = round(w * 0.07)
    tile = logo.crop((c, c, w - c, w - c))
    for name, n in (("tv_runner/yumori-icon-130.png", 130), ("tv_runner/yumori-icon-80.png", 80),
                    ("tv/largeIcon.png", 130), ("tv/icon.png", 80)):
        tile.resize((n, n), Image.LANCZOS).save(os.path.join(ROOT, name), optimize=True)
    print("Yumori icons written")


if __name__ == "__main__":
    main()
