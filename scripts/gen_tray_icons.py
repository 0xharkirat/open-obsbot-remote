#!/usr/bin/env python3
"""Generate the v1.3 multi-state tray icon set procedurally.

Three variants, each as 22x22 (@1x) and 44x44 (@2x):
  - cameraTemplate.png        — idle/running with camera (already shipped in v1.2.1, regenerated for parity)
  - cameraTemplateWarn.png    — running but no camera (camera iris with a diagonal slash)
  - cameraTemplateError.png   — bridge stopped or error (X mark)

All glyphs are black-opaque on transparent. macOS auto-tints
template images to the menubar foreground colour at runtime.

We avoid Pillow + ImageMagick (system doesn't have them) and emit
PNGs by hand using struct + zlib from the stdlib. Same shape as
the v1.2.1 PR N script.
"""

import struct
import zlib
import math
import os
import sys


def write_png(path, pixels, w, h):
    """pixels: list of (r,g,b,a) tuples, length w*h, row-major."""
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type none
        for x in range(w):
            r, g, b, a = pixels[y * w + x]
            raw.extend((r, g, b, a))
    sig = b'\x89PNG\r\n\x1a\n'
    def chunk(tag, data):
        out = struct.pack('>I', len(data)) + tag + data
        out += struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
        return out
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    with open(path, 'wb') as f:
        f.write(sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b''))


def alpha_in_disc(cx, cy, r, x, y):
    """1-pixel anti-aliased disc: fully opaque inside r-0.5, fully transparent outside r+0.5."""
    d = math.hypot(x - cx, y - cy)
    if d <= r - 0.5:
        return 255
    if d >= r + 0.5:
        return 0
    return int(255 * (r + 0.5 - d))


def alpha_in_annulus(cx, cy, r_outer, r_inner, x, y):
    a_out = alpha_in_disc(cx, cy, r_outer, x, y)
    a_in = alpha_in_disc(cx, cy, r_inner, x, y)
    a = a_out - a_in
    return max(0, min(255, a))


def line_alpha(x0, y0, x1, y1, half_w, x, y):
    """Anti-aliased line of total width 2*half_w from (x0,y0) to (x1,y1)."""
    dx, dy = x1 - x0, y1 - y0
    L2 = dx * dx + dy * dy
    if L2 == 0:
        d = math.hypot(x - x0, y - y0)
    else:
        t = ((x - x0) * dx + (y - y0) * dy) / L2
        t = max(0, min(1, t))
        px = x0 + t * dx
        py = y0 + t * dy
        d = math.hypot(x - px, y - py)
    if d <= half_w - 0.5:
        return 255
    if d >= half_w + 0.5:
        return 0
    return int(255 * (half_w + 0.5 - d))


def gen_iris(size, slash=False):
    """Camera-iris glyph: outer ring + centre dot. Optional diagonal slash."""
    cx = cy = (size - 1) / 2
    r_outer = 0.46 * size
    r_outer_inner = 0.32 * size
    r_dot = 0.13 * size
    pixels = []
    for y in range(size):
        for x in range(size):
            a = alpha_in_annulus(cx, cy, r_outer, r_outer_inner, x, y)
            a = max(a, alpha_in_disc(cx, cy, r_dot, x, y))
            if slash:
                # Diagonal slash from top-right to bottom-left, 1.5 px half-width.
                pad = 0.18 * size
                a_slash = line_alpha(size - pad, pad, pad, size - pad,
                                     max(1.0, size / 18.0), x, y)
                a = max(a, a_slash)
            pixels.append((0, 0, 0, a))
    return pixels


def gen_error(size):
    """An X mark in the same visual bounds as the iris."""
    cx = cy = (size - 1) / 2
    pad = 0.22 * size
    half_w = max(1.2, size / 14.0)
    pixels = []
    for y in range(size):
        for x in range(size):
            a1 = line_alpha(pad, pad, size - pad, size - pad, half_w, x, y)
            a2 = line_alpha(size - pad, pad, pad, size - pad, half_w, x, y)
            a = max(a1, a2)
            pixels.append((0, 0, 0, a))
    return pixels


OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../apps/bridge/assets/tray'))
os.makedirs(OUT, exist_ok=True)

variants = [
    ('cameraTemplate.png',        22, gen_iris(22, slash=False)),
    ('cameraTemplate@2x.png',     44, gen_iris(44, slash=False)),
    ('cameraTemplateWarn.png',    22, gen_iris(22, slash=True)),
    ('cameraTemplateWarn@2x.png', 44, gen_iris(44, slash=True)),
    ('cameraTemplateError.png',   22, gen_error(22)),
    ('cameraTemplateError@2x.png',44, gen_error(44)),
]

for name, size, px in variants:
    path = os.path.join(OUT, name)
    write_png(path, px, size, size)
    print(f'wrote {path}  ({size}x{size}, {os.path.getsize(path)} bytes)')
