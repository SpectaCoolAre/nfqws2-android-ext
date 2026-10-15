#!/usr/bin/env python3
"""Склейка скриншотов с телефона в docs/screenshots/main.jpg: три экрана в
скруглённых карточках с тенью на тёмном фоне.

Кадры — docs/screenshots/raw/1.png, 2.png, 3.png (1080×2400, как снимает
Android). Строка состояния сверху и полоса жестов снизу обрезаются, кадр
приводится к 800×1680. Снимки — с телефона, а не из браузера: на них есть
размытие под нижней панелью, которого нет в рендере без GPU."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter

raw = sys.argv[1] if len(sys.argv) > 1 else 'docs/screenshots/raw'
out = sys.argv[2] if len(sys.argv) > 2 else 'docs/screenshots/main.jpg'
BG = (24, 23, 28)
M, GAP, R = 60, 48, 56
FW, FH = 800, 1680
# доли высоты: строка состояния и полоса жестов
TOP, BOTTOM = 0.042, 0.025


def frame(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    top, bottom = round(h * TOP), h - round(h * BOTTOM)
    ch = bottom - top
    cw = round(ch * FW / FH)
    if cw > w:                       # кадр уже нужного — режем по высоте
        cw = w
        ch = round(cw * FH / FW)
        bottom = top + ch
    left = (w - cw) // 2
    return im.crop((left, top, left + cw, bottom)).resize((FW, FH), Image.LANCZOS)


shots = [frame(os.path.join(raw, f'{i}.png')) for i in (1, 2, 3)]
W, H = 2 * M + 3 * FW + 2 * GAP, 2 * M + FH
canvas = Image.new('RGB', (W, H), BG)
shadow = Image.new('L', (W, H), 0)
d = ImageDraw.Draw(shadow)
for i in range(3):
    x = M + i * (FW + GAP)
    d.rounded_rectangle((x, M + 12, x + FW, M + FH + 12), R, fill=200)
shadow = shadow.filter(ImageFilter.GaussianBlur(24))
canvas.paste(Image.new('RGB', (W, H), (0, 0, 0)), (0, 0), shadow.point(lambda v: v * 0.45))
for i, im in enumerate(shots):
    mask = Image.new('L', (FW, FH), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, FW - 1, FH - 1), R, fill=255)
    canvas.paste(im, (M + i * (FW + GAP), M), mask)
canvas.save(out, quality=88, optimize=True)
