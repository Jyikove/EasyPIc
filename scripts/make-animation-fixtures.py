"""Regenerate tiny animation regression fixtures (requires Pillow, not used by the app)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageSequence
import json

folder = Path(__file__).resolve().parents[1] / "Tests/EasyPicCoreTests/Fixtures"
folder.mkdir(parents=True, exist_ok=True)
frames = []
for index, color in enumerate(["#f45b69", "#38c9a9", "#f4bd50"]):
    image = Image.new("RGBA", (96, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((6 + index * 24, 8, 28 + index * 24, 30), fill=color)
    draw.rectangle((4, 48, 90, 57), fill=(255, 255, 255, 255))
    frames.append(image)

manifest = {}
for name, durations, options in [
    ("Animated.gif", [80, 180, 320], {"disposal": [1, 2, 3], "optimize": True}),
    ("Animated.png", [60, 130, 210], {"disposal": [0, 1, 2], "blend": [0, 1, 1]}),
    ("Animated.webp", [80, 150, 300], {"lossless": True}),
]:
    frames[0].save(folder / name, save_all=True, append_images=frames[1:], duration=durations, loop=0, **options)
    with Image.open(folder / name) as image:
        for index, frame in enumerate(ImageSequence.Iterator(image)):
            frame.convert("RGBA").save(folder / f"{name}-frame{index}.png")
    manifest[name] = durations

frames[0].save(folder / "Static.gif")
frames[0].save(folder / "Static.png")
rgb = [frame.convert("RGB") for frame in frames[:2]]
rgb[0].save(folder / "Pages.tiff", save_all=True, append_images=rgb[1:])
(folder / "Renamed.jpg").write_bytes((folder / "Animated.gif").read_bytes())
(folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(folder)
