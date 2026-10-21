#!/usr/bin/env python3
"""Writes the logo's source SVGs from one set of measurements.

Every shape is defined here once, so the app icon layers, the flat logo and
the menu bar template stay in proportion. Run `./build.sh` afterwards to
render the assets; see README.md.
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "svg")

# Palettes: flat, solid fills only. macOS 26 adds the glass, specular highlights,
# shadows and the dark/clear/tinted looks, so the art itself carries no depth.
# `background` is the solid fill in AppIcon.icon/icon.json; the rest are layers.
PALETTES = {
    "a": dict(background="#1C1C1E", body="#E5E5EA", screen="#2C2C2E", gear="#5AA2F0", hole="#2C2C2E"),
    "b": dict(background="#0B6E66", body="#FFFFFF", screen="#08564F", gear="#FFFFFF", hole="#08564F"),
    "c": dict(background="#18181B", body="#F4F4F5", screen="#F4F4F5", gear="#FF5A4E", hole="#F4F4F5"),
}
VARIANT = os.environ.get("LOGO_VARIANT", "a")
P = PALETTES[VARIANT]


def fmt(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def rrect(x, y, w, h, r):
    """Closed rounded-rectangle path."""
    return (f"M{fmt(x + r)} {fmt(y)}H{fmt(x + w - r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w)} {fmt(y + r)}"
            f"V{fmt(y + h - r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w - r)} {fmt(y + h)}"
            f"H{fmt(x + r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x)} {fmt(y + h - r)}"
            f"V{fmt(y + r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + r)} {fmt(y)}Z")


def circle(cx, cy, r):
    return (f"M{fmt(cx - r)} {fmt(cy)}A{fmt(r)} {fmt(r)} 0 1 0 {fmt(cx + r)} {fmt(cy)}"
            f"A{fmt(r)} {fmt(r)} 0 1 0 {fmt(cx - r)} {fmt(cy)}Z")


def gear(cx, cy, tip, root, teeth=6, root_half=17.0, tip_half=11.0, phase=0.0):
    """Six trapezoidal teeth on a root circle, as in Klaus Zhu's original."""
    def pt(r, deg):
        a = math.radians(deg)
        return cx + r * math.cos(a), cy + r * math.sin(a)
    step = 360.0 / teeth
    d = []
    for i in range(teeth):
        c = phase + i * step
        p = [pt(root, c - root_half), pt(tip, c - tip_half), pt(tip, c + tip_half), pt(root, c + root_half)]
        d.append(("M" if i == 0 else "L") + f"{fmt(p[0][0])} {fmt(p[0][1])}")
        d.append(f"L{fmt(p[1][0])} {fmt(p[1][1])}")
        d.append(f"A{fmt(tip)} {fmt(tip)} 0 0 1 {fmt(p[2][0])} {fmt(p[2][1])}")
        d.append(f"L{fmt(p[3][0])} {fmt(p[3][1])}")
        n = pt(root, c + step - root_half)
        d.append(f"A{fmt(root)} {fmt(root)} 0 0 1 {fmt(n[0])} {fmt(n[1])}")
    return "".join(d) + "Z"


def svg(size, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">{body}</svg>\n'


def write(name, text):
    with open(os.path.join(SVG, name), "w") as f:
        f.write(text)


# ---- App icon geometry (1024 pt Icon Composer canvas; the system masks it) ----
C = 1024
BODY = (150, 196, 724, 510, 84)          # x, y, w, h, corner
BEZEL = 34
SCREEN = (BODY[0] + BEZEL, BODY[1] + BEZEL, BODY[2] - 2 * BEZEL, BODY[3] - 2 * BEZEL, BODY[4] - BEZEL)
NECK = (448, 690, 128, 104)
BASE = (318, 784, 388, 54, 27)
GX, GY = 512, SCREEN[1] + SCREEN[3] / 2
G_TIP, G_ROOT, G_HOLE = 170, 128, 58


def stand_path():
    return rrect(NECK[0], NECK[1], NECK[2], NECK[3], 0.01) + rrect(*BASE)


def solid(name, d, color, evenodd=False):
    rule = ' fill-rule="evenodd"' if evenodd else ""
    write(name, svg(C, f'<path fill="{color}"{rule} d="{d}"/>'))


def icon_layers():
    solid("monitor.svg", rrect(*BODY) + stand_path(), P["body"])
    solid("screen.svg", rrect(*SCREEN), P["screen"])
    solid("gear.svg", gear(GX, GY, G_TIP, G_ROOT) + circle(GX, GY, G_HOLE), P["gear"], evenodd=True)
    solid("hole.svg", circle(GX, GY, G_HOLE), P["hole"])


def flat_logo():
    """Transparent, un-glassed logo for the in-app placeholder and the docs."""
    body = (f'<path fill="{P["body"]}" d="{rrect(*BODY)}{stand_path()}"/>'
            f'<path fill="{P["screen"]}" d="{rrect(*SCREEN)}"/>'
            f'<path fill="{P["gear"]}" fill-opacity="0.6" fill-rule="evenodd" d="{gear(GX, GY, G_TIP, G_ROOT)}{circle(GX, GY, G_HOLE)}"/>')
    # Centre the artwork vertically on the square canvas.
    shift = (C - (BASE[1] + BASE[3] + BODY[1])) / 2
    write("logo-flat.svg", svg(C, f'<g transform="translate(0 {fmt(shift)})">{body}</g>'))


def menubar():
    """18x18 pt template: monitor outline, solid gear, stand. Black on clear;
    macOS tints it white or black with the menu bar."""
    s = 18
    ox, oy, ow, oh, orad = 0.75, 1.5, 16.5, 11.75, 2.5
    t = 1.5  # bezel stroke, 3 px at 2x
    frame = rrect(ox, oy, ow, oh, orad) + rrect(ox + t, oy + t, ow - 2 * t, oh - 2 * t, orad - t)
    cx, cy = s / 2, oy + oh / 2
    g = gear(cx, cy, 3.7, 2.8, root_half=18.0, tip_half=12.0) + circle(cx, cy, 1.15)
    neck = rrect(7.75, oy + oh - 0.25, 2.5, 2.25, 0.01)
    base = rrect(4.75, 15.0, 8.5, 1.5, 0.75)
    body = f'<path fill="#000" fill-rule="evenodd" d="{frame}{g}"/><path fill="#000" d="{neck}{base}"/>'
    write("menubar-template.svg", svg(s, body))


def set_icon_fill(path):
    """Sets AppIcon.icon's solid background fill; the rest of icon.json is Icon Composer's.

    The light look (white background, black frame, white screen) lives in icon.json's
    fill-specializations and is left alone here."""
    import json
    with open(path) as f:
        icon = json.load(f)
    r, g, b = (int(P["background"][i:i + 2], 16) / 255 for i in (1, 3, 5))
    solid = {"solid": f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"}
    # With light/dark fill-specializations (set in Icon Composer), the palette is the dark look.
    specs = icon.get("fill-specializations")
    if specs:
        for s in specs:
            if s.get("appearance") == "dark":
                s["value"] = solid
    else:
        icon["fill"] = solid
    with open(path, "w") as f:
        f.write(json.dumps(icon, indent=2, separators=(",", " : ")) + "\n")


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == "--background":
        print(P["background"])
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--icon-fill":
        set_icon_fill(sys.argv[2])
        sys.exit(0)
    SVG = os.environ.get("LOGO_OUT", SVG)
    os.makedirs(SVG, exist_ok=True)
    for f in os.listdir(SVG):
        if f.endswith(".svg"):
            os.remove(os.path.join(SVG, f))
    icon_layers()
    flat_logo()
    menubar()
    print("wrote", sorted(os.listdir(SVG)))
