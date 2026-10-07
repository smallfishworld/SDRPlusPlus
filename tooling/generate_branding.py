#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "flutter_ui" / "assets" / "branding"
ASSETS.mkdir(parents=True, exist_ok=True)

SIZE = 1024
img = Image.new("RGBA", (SIZE, SIZE), (5, 10, 18, 255))
draw = ImageDraw.Draw(img)

# Subtle radial glow.
glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse((120, 120, 904, 904), fill=(27, 99, 255, 90))
glow = glow.filter(ImageFilter.GaussianBlur(120))
img = Image.alpha_composite(img, glow)

# Rounded outer frame with cyan -> purple segmented gradient feel.
draw = ImageDraw.Draw(img)
pad = 86
radius = 220
draw.rounded_rectangle(
    (pad, pad, SIZE - pad, SIZE - pad),
    radius=radius,
    fill=(7, 17, 31, 255),
    outline=(29, 180, 255, 255),
    width=28,
)
# Purple highlight on upper-right/bottom-right edges.
draw.arc((pad, pad, SIZE - pad, SIZE - pad), 282, 82, fill=(139, 92, 246, 255), width=30)
draw.arc((pad, pad, SIZE - pad, SIZE - pad), 50, 125, fill=(186, 104, 255, 255), width=24)

# Waveform bars.
bars = [0.32, 0.48, 0.66, 0.86, 1.00, 0.78, 0.60, 0.45, 0.28]
center_x = SIZE // 2
base_h = 500
gap = 28
bar_w = 54
start_x = center_x - ((len(bars) * bar_w + (len(bars) - 1) * gap) // 2)

for i, ratio in enumerate(bars):
    x0 = start_x + i * (bar_w + gap)
    h = int(base_h * ratio)
    y0 = SIZE // 2 - h // 2
    y1 = SIZE // 2 + h // 2

    # Color interpolate cyan -> blue -> purple.
    t = i / (len(bars) - 1)
    if t < 0.55:
        q = t / 0.55
        color = (
            int(28 + (59 - 28) * q),
            int(221 + (130 - 221) * q),
            255,
            255,
        )
    else:
        q = (t - 0.55) / 0.45
        color = (
            int(59 + (185 - 59) * q),
            int(130 + (88 - 130) * q),
            int(255 + (255 - 255) * q),
            255,
        )

    # Glow under each bar.
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    gdraw.rounded_rectangle((x0, y0, x0 + bar_w, y1), radius=bar_w // 2, fill=color[:-1] + (150,))
    glow = glow.filter(ImageFilter.GaussianBlur(24))
    img = Image.alpha_composite(img, glow)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle((x0, y0, x0 + bar_w, y1), radius=bar_w // 2, fill=color)

master = ASSETS / "sdrpp_receiver_icon.png"
img.save(master)

# Android launcher icon densities.
android_res = ROOT / "flutter_ui" / "android" / "app" / "src" / "main" / "res"
sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
for folder, px in sizes.items():
    dest = android_res / folder
    dest.mkdir(parents=True, exist_ok=True)
    img.resize((px, px), Image.Resampling.LANCZOS).save(dest / "ic_launcher.png")

print(f"Generated branding: {master}")


# Dark launch background for Android startup.
drawable_xml = """<?xml version="1.0" encoding="utf-8"?>
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="#080B10" />
    <item>
        <bitmap
            android:gravity="center"
            android:src="@mipmap/ic_launcher" />
    </item>
</layer-list>
"""
for folder in ("drawable", "drawable-v21"):
    dest = android_res / folder
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "launch_background.xml").write_text(drawable_xml)

values = android_res / "values"
values.mkdir(parents=True, exist_ok=True)
colors_path = values / "colors.xml"
colors_path.write_text("""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="sdrpp_splash_background">#080B10</color>
</resources>
""")


# Windows icon, when a Windows runner has already been generated.
windows_icon = ROOT / "flutter_ui" / "windows" / "runner" / "resources" / "app_icon.ico"
if windows_icon.parent.exists():
    img.save(
        windows_icon,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

# macOS AppIcon asset set.
mac_icon_dir = ROOT / "flutter_ui" / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
if mac_icon_dir.exists():
    for px in (16, 32, 64, 128, 256, 512, 1024):
        img.resize((px, px), Image.Resampling.LANCZOS).save(
            mac_icon_dir / f"app_icon_{px}.png"
        )

# iOS AppIcon asset set. Flutter's default Contents.json references these names.
ios_icon_dir = ROOT / "flutter_ui" / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
if ios_icon_dir.exists():
    ios_icons = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    for name, px in ios_icons.items():
        img.resize((px, px), Image.Resampling.LANCZOS).save(ios_icon_dir / name)
