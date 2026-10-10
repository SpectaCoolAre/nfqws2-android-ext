#!/usr/bin/env python3
"""Склейка кадров docs/screenshots/make.js в docs/screenshots/{light,dark}.jpg:
три экрана в скруглённых карточках с тенью на фоне в цвет темы."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

raw = sys.argv[1] if len(sys.argv) > 1 else 'docs/screenshots/raw'
out = sys.argv[2] if len(sys.argv) > 2 else 'docs/screenshots'
BG = {'light': (233, 229, 242), 'dark': (24, 23, 28)}
M, GAP, R = 60, 48, 56

for mode, bg in BG.items():
    shots = [Image.open(os.path.join(raw, f'{mode}-{i}.png')).convert('RGB') for i in (1, 2, 3)]
    w, h = shots[0].size
    W, H = 2 * M + 3 * w + 2 * GAP, 2 * M + h
    canvas = Image.new('RGB', (W, H), bg)
    shadow = Image.new('L', (W, H), 0)
    d = ImageDraw.Draw(shadow)
    for i in range(3):
        x = M + i * (w + GAP)
        d.rounded_rectangle((x, M + 12, x + w, M + h + 12), R, fill=110 if mode == 'light' else 200)
    shadow = shadow.filter(ImageFilter.GaussianBlur(24))
    canvas.paste(Image.new('RGB', (W, H), (0, 0, 0)), (0, 0), shadow.point(lambda v: v * 0.45))
    for i, im in enumerate(shots):
        mask = Image.new('L', (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), R, fill=255)
        canvas.paste(im, (M + i * (w + GAP), M), mask)
    canvas.save(os.path.join(out, f'{mode}.jpg'), quality=88, optimize=True)
