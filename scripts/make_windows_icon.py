"""Build the Windows app icon from the macOS AppIcon PNGs.

An .ico can hold PNG images directly (Windows Vista and later), so this needs
no image library: it packs the existing 16..256px renders into one file.

    python scripts/make_windows_icon.py
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'apps/bridge/macos/Runner/Assets.xcassets/AppIcon.appiconset'
OUT = ROOT / 'apps/bridge/windows/runner/resources/app_icon.ico'
SIZES = [16, 32, 64, 128, 256]

images = [(s, (SRC / f'app_icon_{s}.png').read_bytes()) for s in SIZES]
header = struct.pack('<HHH', 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, data = b'', b''
for size, png in images:
    dim = 0 if size >= 256 else size   # 0 means 256 in an ICONDIRENTRY
    entries += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(png), offset + len(data))
    data += png
OUT.write_bytes(header + entries + data)
print(f'wrote {OUT.relative_to(ROOT)} ({len(images)} sizes)')
