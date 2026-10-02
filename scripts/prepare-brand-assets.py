#!/usr/bin/env python3
"""Package the generated artwork for the website and macOS. Requires Pillow."""
import json
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design/brand"
WEB = ROOT / "assets/brand"
CATALOG = ROOT / "HeyVedu/Assets.xcassets"


def artwork(name):
    image = Image.open(SOURCE / f"{name}-source.png").convert("RGBA")
    # Ignore near-transparent generator noise when measuring canvas padding.
    bounds = image.getchannel("A").point(lambda a: 255 if a >= 16 else 0).getbbox()
    return image.crop((bounds[0] - 2, bounds[1] - 2, bounds[2] + 2, bounds[3] + 2))


def square(image, size, inset=0):
    tile = ImageOps.contain(image, (size - 2 * inset, size - 2 * inset), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size))
    canvas.alpha_composite(tile, ((size - tile.width) // 2, (size - tile.height) // 2))
    return canvas


def metadata(path, images):
    path.mkdir(parents=True, exist_ok=True)
    (path / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


WEB.mkdir(parents=True, exist_ok=True)
wordmark, mark, icon = (artwork(name) for name in ("wordmark", "mark", "app-icon"))
wordmark.save(WEB / "heyvedu-wordmark.png", optimize=True)
square(mark, 1024, 48).save(WEB / "heyvedu-mark.png", optimize=True)
square(icon, 1024, 100).save(WEB / "heyvedu-app-icon.png", optimize=True)
for size in (16, 32, 192, 512):
    square(icon, size).save(WEB / f"favicon-{size}.png", optimize=True)
square(icon, 180).save(WEB / "apple-touch-icon.png", optimize=True)
square(icon, 256).save(WEB / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

CATALOG.mkdir(parents=True, exist_ok=True)
(CATALOG / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}\n')
app_set = CATALOG / "AppIcon.appiconset"
entries = [{"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": f"icon-{size}@{scale}x.png"}
           for size in (16, 32, 128, 256, 512) for scale in (1, 2)]
metadata(app_set, entries)
desktop = square(icon, 1024, 100)
for entry in entries:
    pixels = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
    desktop.resize((pixels, pixels), Image.Resampling.LANCZOS).save(app_set / entry["filename"], optimize=True)

menu_set = CATALOG / "BrandMark.imageset"
metadata(menu_set, [{"idiom": "universal", "filename": "brand-mark.png"}])
square(mark, 128, 2).save(menu_set / "brand-mark.png", optimize=True)
print("Prepared website assets and macOS asset catalog.")
