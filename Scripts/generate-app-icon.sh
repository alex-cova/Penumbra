#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iconset="$root/Example/Resources/AppIcon.iconset"
output="$root/Example/Resources/AppIcon.icns"
tmp_png="$(mktemp /tmp/penumbra-icon.XXXXXX.png)"

mkdir -p "$iconset"

# Simple dark editor icon: rounded rectangle with accent bar.
python3 - <<'PY' "$tmp_png"
import sys
from pathlib import Path
try:
    from PIL import Image, ImageDraw
except ImportError:
    raise SystemExit("Pillow is required: pip install pillow")

size = 1024
img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
margin = 96
draw.rounded_rectangle((margin, margin, size - margin, size - margin), radius=180, fill=(24, 26, 31, 255))
draw.rounded_rectangle((margin + 80, margin + 120, margin + 120, size - margin - 120), radius=24, fill=(96, 165, 250, 255))
draw.rounded_rectangle((margin + 180, margin + 180, size - margin - 80, margin + 260), radius=20, fill=(148, 163, 184, 255))
draw.rounded_rectangle((margin + 180, margin + 320, size - margin - 180, margin + 400), radius=20, fill=(100, 116, 139, 255))
draw.rounded_rectangle((margin + 180, margin + 460, size - margin - 120, margin + 540), radius=20, fill=(100, 116, 139, 255))
img.save(sys.argv[1])
PY

sizes=(16 32 128 256 512)
for size in "${sizes[@]}"; do
  sips -z "$size" "$size" "$tmp_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$tmp_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$output"
rm -rf "$iconset" "$tmp_png"
echo "Wrote $output"
