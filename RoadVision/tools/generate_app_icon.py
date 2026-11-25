#!/usr/bin/env python3
"""Generates the RoadVision app icon (1024×1024, opaque PNG) with Pillow.

Artwork: navy→teal gradient, a camera-lens ring that frames a road in perspective with lane markings,
and a recognition bounding box around a car seen from behind. No text, no transparency (App Store rule).

Writes three files into ``RoadVision/Assets.xcassets/AppIcon.appiconset``:
``AppIcon-1024.png`` (any appearance), ``AppIcon-1024-dark.png`` and ``AppIcon-1024-tinted.png`` (grayscale).

Usage:  python3 tools/generate_app_icon.py  (needs: pip install pillow)
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

SIZE = 1024
SS = 2  # supersampling factor for smooth edges
W = SIZE * SS
OUT_DIR = Path(__file__).resolve().parent.parent / "RoadVision" / "Assets.xcassets" / "AppIcon.appiconset"

CX, CY = W // 2, int(W * 0.5)          # lens centre
LENS_R = int(W * 0.355)                # inner radius of the lens opening
RING_W = int(W * 0.042)                # ring stroke width
HORIZON_Y = int(CY - LENS_R * 0.18)    # horizon / vanishing point height
BOTTOM_Y = CY + LENS_R + RING_W        # road leaves the lens at the bottom


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_rgb(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(lerp(x, y, t))) for x, y in zip(c1, c2))


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    w, h = size
    column = Image.new("RGB", (1, h))
    for y in range(h):
        column.putpixel((0, y), lerp_rgb(top, bottom, y / max(1, h - 1)))
    return column.resize((w, h))


def radial_glow(radius: int, color: tuple[int, int, int], strength: float) -> Image.Image:
    """RGBA image with a soft circular glow."""
    img = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(img)
    d.ellipse((CX - radius, CY - radius, CX + radius, CY + radius), fill=int(255 * strength))
    img = img.filter(ImageFilter.GaussianBlur(radius * 0.45))
    rgba = Image.new("RGBA", (W, W), color + (0,))
    rgba.putalpha(img)
    return rgba


def circle_mask(radius: int) -> Image.Image:
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse((CX - radius, CY - radius, CX + radius, CY + radius), fill=255)
    return m


def road_x(y: float, offset: float) -> float:
    """x of a road line at screen height y; offset in [-1, 1] across the road width at the bottom."""
    t = (y - HORIZON_Y) / (BOTTOM_Y - HORIZON_Y)
    half_bottom = W * 0.43
    return CX + offset * half_bottom * t


def depth_to_y(z: float) -> float:
    """Perspective: screen y for ground distance z (z = 1 at the bottom edge)."""
    return HORIZON_Y + (BOTTOM_Y - HORIZON_Y) / z


def draw_scene() -> Image.Image:
    """Everything visible through the lens (sky, road, markings, car, bounding box)."""
    scene = vertical_gradient((W, W), (6, 20, 44), (8, 40, 60))
    d = ImageDraw.Draw(scene, "RGBA")

    # Sky glow near the horizon.
    sky = vertical_gradient((W, HORIZON_Y), (7, 18, 40), (18, 92, 112))
    scene.paste(sky, (0, 0))
    glow = Image.new("L", (W, W), 0)
    ImageDraw.Draw(glow).ellipse((CX - W * 0.32, HORIZON_Y - W * 0.06, CX + W * 0.32, HORIZON_Y + W * 0.06),
                                 fill=170)
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.035))
    scene.paste(Image.new("RGB", (W, W), (64, 230, 220)), (0, 0), glow)

    # Ground (dark, slightly teal) below the horizon.
    ground = vertical_gradient((W, W - HORIZON_Y), (16, 52, 64), (6, 16, 26))
    scene.paste(ground, (0, HORIZON_Y))

    # Asphalt road surface.
    road = [(road_x(HORIZON_Y, -1), HORIZON_Y), (road_x(HORIZON_Y, 1), HORIZON_Y),
            (road_x(BOTTOM_Y, 1), BOTTOM_Y), (road_x(BOTTOM_Y, -1), BOTTOM_Y)]
    road_layer = vertical_gradient((W, W), (40, 52, 66), (22, 28, 38))
    road_mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(road_mask).polygon(road, fill=255)
    scene.paste(road_layer, (0, 0), road_mask)

    # Solid edge lines.
    for off in (-0.97, 0.97):
        pts = []
        for side in (-1, 1):
            w_off = side * 0.012
            pts.append((road_x(HORIZON_Y, off + w_off), HORIZON_Y))
        for side in (1, -1):
            w_off = side * 0.012
            pts.append((road_x(BOTTOM_Y, off + w_off), BOTTOM_Y))
        d.polygon(pts, fill=(235, 242, 245, 235))

    # Dashed lane dividers (3 lanes) in perspective.
    for off in (-0.33, 0.33):
        z = 1.0
        while z < 14:
            z_end = z * 1.28
            y1, y2 = depth_to_y(z), depth_to_y(z_end)
            if y2 - HORIZON_Y < 4:
                break
            half = 0.016
            quad = [(road_x(y1, off - half), y1), (road_x(y1, off + half), y1),
                    (road_x(y2, off + half), y2), (road_x(y2, off - half), y2)]
            d.polygon(quad, fill=(245, 250, 252, 230))
            z = z_end * 1.32

    # Car seen from behind, middle lane, mid distance.
    car_y = depth_to_y(1.95)
    car_w = (road_x(car_y, 0.33) - road_x(car_y, -0.33)) * 0.78
    car_h = car_w * 0.62
    x0, x1 = CX - car_w / 2, CX + car_w / 2
    y_bottom = car_y + car_h * 0.12
    y_top = y_bottom - car_h
    # Shadow.
    shadow = Image.new("L", (W, W), 0)
    ImageDraw.Draw(shadow).ellipse((x0 - car_w * 0.06, y_bottom - car_h * 0.10, x1 + car_w * 0.06,
                                    y_bottom + car_h * 0.12), fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(car_w * 0.04))
    scene.paste(Image.new("RGB", (W, W), (0, 0, 0)), (0, 0), shadow)
    # Cabin (roof + rear window).
    cabin = [(x0 + car_w * 0.17, y_top + car_h * 0.42), (x0 + car_w * 0.27, y_top),
             (x1 - car_w * 0.27, y_top), (x1 - car_w * 0.17, y_top + car_h * 0.42)]
    d.polygon(cabin, fill=(196, 214, 224, 255))
    window = [(x0 + car_w * 0.23, y_top + car_h * 0.38), (x0 + car_w * 0.30, y_top + car_h * 0.08),
              (x1 - car_w * 0.30, y_top + car_h * 0.08), (x1 - car_w * 0.23, y_top + car_h * 0.38)]
    d.polygon(window, fill=(26, 52, 72, 255))
    # Body.
    body_top = y_top + car_h * 0.40
    d.rounded_rectangle((x0, body_top, x1, y_bottom - car_h * 0.12), radius=car_h * 0.14, fill=(226, 236, 242, 255))
    # Wheels.
    wheel_w = car_w * 0.16
    for wx in (x0 + car_w * 0.06, x1 - car_w * 0.06 - wheel_w):
        d.rounded_rectangle((wx, y_bottom - car_h * 0.20, wx + wheel_w, y_bottom), radius=car_h * 0.05,
                            fill=(14, 20, 28, 255))
    # Tail lights + plate.
    light_h = car_h * 0.11
    ly = body_top + car_h * 0.10
    d.rounded_rectangle((x0 + car_w * 0.05, ly, x0 + car_w * 0.27, ly + light_h), radius=light_h / 2,
                        fill=(255, 64, 84, 255))
    d.rounded_rectangle((x1 - car_w * 0.27, ly, x1 - car_w * 0.05, ly + light_h), radius=light_h / 2,
                        fill=(255, 64, 84, 255))
    d.rounded_rectangle((CX - car_w * 0.13, ly + light_h * 1.5, CX + car_w * 0.13, ly + light_h * 2.6),
                        radius=light_h * 0.2, fill=(250, 250, 250, 255))
    # Tail-light glow.
    tl = Image.new("L", (W, W), 0)
    tld = ImageDraw.Draw(tl)
    tld.ellipse((x0 - car_w * 0.02, ly - light_h, x0 + car_w * 0.33, ly + light_h * 2), fill=120)
    tld.ellipse((x1 - car_w * 0.33, ly - light_h, x1 + car_w * 0.02, ly + light_h * 2), fill=120)
    tl = tl.filter(ImageFilter.GaussianBlur(car_w * 0.05))
    scene.paste(Image.new("RGB", (W, W), (255, 70, 90)), (0, 0), tl)

    # Recognition bounding box: corner brackets with glow.
    pad = car_w * 0.12
    bx0, by0, bx1, by1 = x0 - pad, y_top - pad, x1 + pad, y_bottom + pad * 0.7
    arm = (bx1 - bx0) * 0.24
    thick = int(W * 0.014)
    cyan = (40, 240, 214)
    bracket = Image.new("L", (W, W), 0)
    bd = ImageDraw.Draw(bracket)
    corners = [((bx0, by0), (1, 1)), ((bx1, by0), (-1, 1)), ((bx0, by1), (1, -1)), ((bx1, by1), (-1, -1))]
    for (px, py), (sx, sy) in corners:
        bd.line([(px, py + sy * arm), (px, py), (px + sx * arm, py)], fill=255, width=thick, joint="curve")
        bd.ellipse((px - thick / 2, py - thick / 2, px + thick / 2, py + thick / 2), fill=255)
    halo = bracket.filter(ImageFilter.GaussianBlur(W * 0.012))
    scene.paste(Image.new("RGB", (W, W), cyan), (0, 0), halo)
    scene.paste(Image.new("RGB", (W, W), (190, 255, 246)), (0, 0), bracket)
    # Small confidence bar above the box (no text).
    bar_y = by0 - thick * 2.6
    d.rounded_rectangle((bx0, bar_y, bx0 + (bx1 - bx0) * 0.46, bar_y + thick * 1.4), radius=thick * 0.7,
                        fill=cyan + (255,))
    return scene


def angular_gradient_ring(r_inner: int, r_outer: int) -> Image.Image:
    """RGBA ring with a cyan→blue→cyan angular gradient."""
    ring = Image.new("RGB", (W, W))
    px = ring.load()
    c1, c2, c3 = (56, 248, 222), (40, 140, 255), (120, 255, 236)
    step = 4
    for y in range(CY - r_outer, CY + r_outer + 1, step):
        for x in range(CX - r_outer, CX + r_outer + 1, step):
            a = (math.atan2(y - CY, x - CX) + math.pi) / (2 * math.pi)  # 0..1
            t = (a + 0.15) % 1.0
            col = lerp_rgb(c1, c2, t * 2) if t < 0.5 else lerp_rgb(c2, c3, (t - 0.5) * 2)
            for yy in range(y, min(y + step, W)):
                for xx in range(x, min(x + step, W)):
                    px[xx, yy] = col
    ring = ring.filter(ImageFilter.GaussianBlur(3))
    mask = Image.new("L", (W, W), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse((CX - r_outer, CY - r_outer, CX + r_outer, CY + r_outer), fill=255)
    md.ellipse((CX - r_inner, CY - r_inner, CX + r_inner, CY + r_inner), fill=0)
    out = ring.convert("RGBA")
    out.putalpha(mask)
    return out


def compose() -> Image.Image:
    base = vertical_gradient((W, W), (3, 9, 28), (5, 84, 98)).convert("RGBA")
    # Diagonal sheen for depth.
    sheen = Image.new("L", (W, W), 0)
    ImageDraw.Draw(sheen).polygon([(0, 0), (W * 0.7, 0), (0, W * 0.7)], fill=60)
    sheen = sheen.filter(ImageFilter.GaussianBlur(W * 0.12))
    base.paste(Image.new("RGBA", (W, W), (30, 70, 140, 255)), (0, 0), sheen)
    base.alpha_composite(radial_glow(int(LENS_R * 1.35), (30, 220, 210), 0.55))

    # Outer dark bezel behind the ring.
    bezel = Image.new("L", (W, W), 0)
    r_bezel = LENS_R + RING_W + int(W * 0.03)
    ImageDraw.Draw(bezel).ellipse((CX - r_bezel, CY - r_bezel, CX + r_bezel, CY + r_bezel), fill=255)
    base.paste(Image.new("RGBA", (W, W), (4, 12, 26, 255)), (0, 0), bezel)

    # Scene inside the lens.
    scene = draw_scene().convert("RGBA")
    base.paste(scene, (0, 0), circle_mask(LENS_R))

    # Lens vignette.
    vig = Image.new("L", (W, W), 0)
    ImageDraw.Draw(vig).ellipse((CX - LENS_R, CY - LENS_R, CX + LENS_R, CY + LENS_R), fill=255)
    inner = Image.new("L", (W, W), 0)
    ImageDraw.Draw(inner).ellipse((CX - LENS_R * 0.86, CY - LENS_R * 0.86, CX + LENS_R * 0.86, CY + LENS_R * 0.86),
                                  fill=255)
    inner = inner.filter(ImageFilter.GaussianBlur(LENS_R * 0.12))
    vig = ImageChops.subtract(vig, inner)
    vig = vig.point(lambda v: int(v * 0.55))
    base.paste(Image.new("RGBA", (W, W), (0, 6, 16, 255)), (0, 0), vig)

    # Glowing ring.
    ring = angular_gradient_ring(LENS_R, LENS_R + RING_W)
    ring_glow = ring.copy()
    ring_glow.putalpha(ring.getchannel("A").filter(ImageFilter.GaussianBlur(W * 0.02)).point(lambda v: int(v * 0.8)))
    base.alpha_composite(ring_glow)
    base.alpha_composite(ring)

    # Thin inner ring and tick marks (camera focus scale).
    d = ImageDraw.Draw(base, "RGBA")
    r_thin = LENS_R + RING_W + int(W * 0.018)
    d.ellipse((CX - r_thin, CY - r_thin, CX + r_thin, CY + r_thin), outline=(120, 255, 236, 150),
              width=int(W * 0.004))
    for k in range(48):
        ang = 2 * math.pi * k / 48
        long_tick = k % 4 == 0
        r1 = r_thin + int(W * 0.010)
        r2 = r1 + int(W * (0.022 if long_tick else 0.012))
        d.line([(CX + r1 * math.cos(ang), CY + r1 * math.sin(ang)), (CX + r2 * math.cos(ang), CY + r2 * math.sin(ang))],
               fill=(150, 255, 240, 170 if long_tick else 110), width=int(W * 0.004))

    # Glass highlight (top-left arc).
    hl = Image.new("L", (W, W), 0)
    ImageDraw.Draw(hl).arc((CX - LENS_R * 0.9, CY - LENS_R * 0.9, CX + LENS_R * 0.9, CY + LENS_R * 0.9),
                           start=200, end=250, fill=150, width=int(W * 0.018))
    hl = hl.filter(ImageFilter.GaussianBlur(W * 0.006))
    base.paste(Image.new("RGBA", (W, W), (255, 255, 255, 255)), (0, 0), hl)

    return base.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    icon = compose()
    icon.save(OUT_DIR / "AppIcon-1024.png", optimize=True)
    # Dark appearance: slightly deeper background, same artwork (opaque is allowed).
    dark = Image.blend(icon, Image.new("RGB", icon.size, (0, 0, 0)), 0.18)
    dark.save(OUT_DIR / "AppIcon-1024-dark.png", optimize=True)
    # Tinted appearance: grayscale luminance, the system applies the user's tint colour.
    tinted = ImageOps.autocontrast(ImageOps.grayscale(icon), cutoff=1).convert("RGB")
    tinted.save(OUT_DIR / "AppIcon-1024-tinted.png", optimize=True)
    for name in ("AppIcon-1024.png", "AppIcon-1024-dark.png", "AppIcon-1024-tinted.png"):
        im = Image.open(OUT_DIR / name)
        print(f"{name}: {im.size} {im.mode}")


if __name__ == "__main__":
    main()
