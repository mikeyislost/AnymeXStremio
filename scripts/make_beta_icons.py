#!/usr/bin/env python3
"""Make the AnymeX+ beta icons (orange logo + a BETA tag) into beta/.

Run once after changing the normal icons:  python3 scripts/make_beta_icons.py
CI copies beta/ over the normal icons for beta builds (scripts/beta_build.sh).
"""
import os
import shutil
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "beta")
ORANGE_TOP = (255, 140, 66)
ORANGE_BOTTOM = (255, 94, 40)
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def recolor(im: Image.Image) -> Image.Image:
    """White/grey artwork becomes an orange gradient; black stays black."""
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        top = [ORANGE_TOP[i] + (ORANGE_BOTTOM[i] - ORANGE_TOP[i]) * t for i in range(3)]
        for x in range(w):
            r, g, b, a = px[x, y]
            lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            px[x, y] = tuple(int(c * lum) for c in top) + (a,)
    return im


def badge(im: Image.Image) -> Image.Image:
    """A small BETA pill under the logo (skipped on tiny icons)."""
    w, h = im.size
    if w < 120:
        return im
    font_path = next((f for f in FONT_CANDIDATES if os.path.exists(f)), None)
    size = int(h * 0.085)
    font = ImageFont.truetype(font_path, size) if font_path else ImageFont.load_default()
    d = ImageDraw.Draw(im)
    text = "BETA"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    tw, th = r - l, b - t
    pad_x, pad_y = int(size * 0.55), int(size * 0.32)
    cx, cy = w / 2, h * 0.835
    box = (cx - tw / 2 - pad_x, cy - th / 2 - pad_y, cx + tw / 2 + pad_x, cy + th / 2 + pad_y)
    d.rounded_rectangle(box, radius=(box[3] - box[1]) / 2, fill=ORANGE_BOTTOM + (255,))
    d.text((cx - tw / 2 - l, cy - th / 2 - t), text, font=font, fill=(0, 0, 0, 255))
    return im


def beta_png(src: str, dst: str, keep_rgb: bool = False) -> None:
    im = badge(recolor(Image.open(src)))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if keep_rgb:
        im = im.convert("RGB")
    im.save(dst, optimize=True)


def main() -> None:
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)

    # iOS app icons (every size in the asset catalog).
    rel = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    src_dir = os.path.join(ROOT, rel)
    for name in sorted(os.listdir(src_dir)):
        src = os.path.join(src_dir, name)
        dst = os.path.join(OUT, rel, name)
        if name.endswith(".png"):
            # App icons must not have transparency.
            beta_png(src, dst, keep_rgb=True)
        else:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)

    # Windows app icon (window/taskbar/exe) and installer icon.
    big = badge(recolor(Image.open(os.path.join(ROOT, "windows/runner/resources/app_icon.ico"))))
    dst = os.path.join(OUT, "windows/runner/resources/app_icon.ico")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    big.save(dst, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    small = recolor(Image.open(os.path.join(ROOT, "anymex.ico")))
    small.save(os.path.join(OUT, "anymex.ico"), sizes=[(16, 16), (32, 32)])

    # Logo used by the beta Feather source.
    beta_png(os.path.join(ROOT, "logo.png"), os.path.join(OUT, "logo.png"), keep_rgb=True)
    print("Beta icons written to", OUT)


if __name__ == "__main__":
    main()
