#!/usr/bin/env python3
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
APPICON = ROOT / "Targets/Mac/Assets.xcassets/AppIcon.appiconset"
DOC_ASSETS = ROOT / "docs/assets"

PALETTE = {
    "navy": (7, 24, 39, 255),
    "deep": (11, 34, 48, 255),
    "teal": (31, 183, 154, 255),
    "mint": (155, 231, 216, 255),
    "paper": (255, 249, 237, 255),
    "cream": (255, 235, 198, 255),
    "amber": (242, 165, 74, 255),
    "orange": (217, 121, 50, 255),
}


def rounded_rect_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    return mask


def linear_gradient(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size))
    px = img.load()
    c1 = PALETTE["navy"]
    c2 = PALETTE["deep"]
    c3 = PALETTE["amber"]
    for y in range(size):
        for x in range(size):
            t = (x * 0.72 + y * 0.42) / (size * 1.14)
            if t < 0.68:
                k = t / 0.68
                c = tuple(int(c1[i] * (1 - k) + c2[i] * k) for i in range(4))
            else:
                k = (t - 0.68) / 0.32
                c = tuple(int(c2[i] * (1 - k) + c3[i] * k) for i in range(4))
            px[x, y] = c
    return img


def draw_icon(size: int = 1024) -> Image.Image:
    scale = size / 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg = linear_gradient(size)
    mask = rounded_rect_mask(size, int(220 * scale))
    img.alpha_composite(Image.composite(bg, Image.new("RGBA", (size, size), (0, 0, 0, 0)), mask))
    draw = ImageDraw.Draw(img)

    # Ambient glows.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((int(520*scale), int(-80*scale), int(1120*scale), int(520*scale)), fill=(255, 231, 174, 36))
    gd.ellipse((int(-120*scale), int(620*scale), int(540*scale), int(1160*scale)), fill=(31, 183, 154, 42))
    glow = glow.filter(ImageFilter.GaussianBlur(int(34 * scale)))
    img.alpha_composite(glow)

    # Delivery route.
    route = [(238, 297), (346, 202), (503, 226), (650, 326), (786, 266)]
    route = [(int(x * scale), int(y * scale)) for x, y in route]
    draw.line(route, fill=PALETTE["mint"], width=max(1, int(22 * scale)), joint="curve")
    for x, y in route[:-1]:
        draw.ellipse((x-int(13*scale), y-int(13*scale), x+int(13*scale), y+int(13*scale)), fill=PALETTE["cream"])
    tip = route[-1]
    arrow = [(tip[0], tip[1]), (tip[0]-int(55*scale), tip[1]-int(26*scale)), (tip[0]-int(42*scale), tip[1]+int(38*scale))]
    draw.polygon(arrow, fill=PALETTE["mint"])

    # Mail / patch card shadow.
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    card = (int(210*scale), int(360*scale), int(814*scale), int(742*scale))
    sd.rounded_rectangle((card[0]+int(18*scale), card[1]+int(28*scale), card[2]+int(18*scale), card[3]+int(28*scale)), radius=int(58*scale), fill=(0, 0, 0, 80))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(20 * scale)))
    img.alpha_composite(shadow)

    # Mail / patch card.
    draw.rounded_rectangle(card, radius=int(58*scale), fill=PALETTE["paper"])
    draw.rounded_rectangle((card[0]+int(28*scale), card[1]+int(28*scale), card[2]-int(28*scale), card[3]-int(28*scale)), radius=int(38*scale), outline=(236, 218, 184, 255), width=max(1, int(7*scale)))

    # Envelope fold.
    left = (card[0]+int(64*scale), card[1]+int(91*scale))
    right = (card[2]-int(64*scale), card[1]+int(91*scale))
    center = ((card[0]+card[2])//2, card[1]+int(224*scale))
    draw.line([left, center, right], fill=PALETTE["deep"], width=max(1, int(24*scale)), joint="curve")
    draw.line([(card[0]+int(72*scale), card[3]-int(74*scale)), center, (card[2]-int(72*scale), card[3]-int(74*scale))], fill=(13, 54, 68, 120), width=max(1, int(14*scale)), joint="curve")

    # Patch lines.
    y = card[1] + int(255 * scale)
    x0 = card[0] + int(138 * scale)
    draw.rounded_rectangle((x0, y, x0+int(230*scale), y+int(28*scale)), radius=int(14*scale), fill=PALETTE["teal"])
    draw.rounded_rectangle((x0, y+int(62*scale), x0+int(310*scale), y+int(90*scale)), radius=int(14*scale), fill=PALETTE["orange"])
    draw.rounded_rectangle((x0, y+int(124*scale), x0+int(188*scale), y+int(152*scale)), radius=int(14*scale), fill=(96, 125, 128, 255))

    # Plus sign badge.
    bx, by = card[2]-int(122*scale), card[3]-int(94*scale)
    draw.ellipse((bx-int(62*scale), by-int(62*scale), bx+int(62*scale), by+int(62*scale)), fill=PALETTE["deep"])
    draw.line((bx-int(30*scale), by, bx+int(30*scale), by), fill=PALETTE["amber"], width=max(1, int(17*scale)))
    draw.line((bx, by-int(30*scale), bx, by+int(30*scale)), fill=PALETTE["amber"], width=max(1, int(17*scale)))

    # Subtle border.
    draw.rounded_rectangle((int(12*scale), int(12*scale), size-int(12*scale), size-int(12*scale)), radius=int(208*scale), outline=(255, 255, 255, 42), width=max(1, int(5*scale)))
    return img


def export_app_icons() -> None:
    DOC_ASSETS.mkdir(parents=True, exist_ok=True)
    APPICON.mkdir(parents=True, exist_ok=True)
    master = draw_icon(1024)
    master.save(DOC_ASSETS / "patch-courier-icon.png")

    contents = json.loads((APPICON / "Contents.json").read_text())
    for entry in contents["images"]:
        filename = entry.get("filename")
        if not filename:
            continue
        size = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].replace("x", ""))
        px = int(round(size * scale))
        icon = master.resize((px, px), Image.Resampling.LANCZOS)
        icon.save(APPICON / filename)


if __name__ == "__main__":
    export_app_icons()
