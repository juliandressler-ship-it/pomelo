"""Erzeugt die Logo-Entwürfe als SVG und eine Vorschauseite.

Idee: Querschnitt einer Mandarine = das Konvertierungsrad der App.
Sieben Segmente (wie die sieben Ziele im Bildrad), eines ist aktiv.
Nur Standardbibliothek. Aufruf: python3 make_logo.py
"""
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "svg"
OUT.mkdir(exist_ok=True)

C = 512  # Mitte der 1024er Fläche
ORANGE_TOP = "#FF8C42"
ORANGE_BOTTOM = "#F05A28"
GRAPHITE_TOP = "#2C2C2E"
GRAPHITE_BOTTOM = "#1C1C1E"


def squircle(x0=100, size=824, n=4.0, steps=240):
    """Superellipse wie das macOS-App-Raster (824 auf 1024)."""
    a = size / 2
    cx = cy = x0 + a
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(ct) ** (2 / n), ct)
        y = cy + a * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.1f},{y:.1f}")
    return "M" + " L".join(pts) + " Z"


def polar(r, deg):
    rad = math.radians(deg - 90)  # 0 Grad = oben
    return C + r * math.cos(rad), C + r * math.sin(rad)


def wedge(r_in, r_out, a0, a1):
    """Ringsegment zwischen zwei Winkeln."""
    x1, y1 = polar(r_out, a0)
    x2, y2 = polar(r_out, a1)
    x3, y3 = polar(r_in, a1)
    x4, y4 = polar(r_in, a0)
    large = 1 if (a1 - a0) > 180 else 0
    return (f"M{x1:.1f},{y1:.1f} A{r_out},{r_out} 0 {large} 1 {x2:.1f},{y2:.1f} "
            f"L{x3:.1f},{y3:.1f} A{r_in},{r_in} 0 {large} 0 {x4:.1f},{y4:.1f} Z")


def segments(count=7, r_in=40, r_out=222, gap_deg=4, round_px=30, active=0,
             ink="#fff", rest_opacity=0.42, rest_ink=None, lift=0):
    """Segmente mit runden Ecken: Geometrie schrumpfen, dann runde Kontur gleicher Farbe."""
    half = round_px / 2
    step = 360 / count
    parts = []
    for i in range(count):
        mid = i * step
        # Winkelabzug so, dass die Lücke am Innenradius noch sichtbar bleibt
        pad = gap_deg / 2 + math.degrees(half / ((r_in + r_out) / 2))
        d = wedge(r_in + half, r_out - half, mid - step / 2 + pad, mid + step / 2 - pad)
        on = i == active
        col = ink if on or rest_ink is None else rest_ink
        op = 1 if on or rest_ink else rest_opacity
        # aktives Segment hebt sich nach außen, wie im Rad der App
        dx, dy = (polar(lift, mid)[0] - C, polar(lift, mid)[1] - C) if on else (0, 0)
        parts.append(f'<path d="{d}" fill="{col}" stroke="{col}" stroke-width="{round_px}" '
                     f'stroke-linejoin="round" opacity="{op}" transform="translate({dx:.1f},{dy:.1f})"/>')
    return "\n".join(parts)


def leaf(ink="#fff"):
    """Kleines Blatt oben rechts am Ring, macht aus der Scheibe eine Mandarine."""
    return (f'<path d="M628,250 C650,186 718,150 792,154 C784,226 722,270 644,268 Z" fill="{ink}"/>')


def bg(top, bottom, gid):
    return (f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/>'
            f'</linearGradient></defs>'
            f'<path d="{squircle()}" fill="url(#{gid})"/>'
            # feine Lichtkante oben, wie bei den Systemsymbolen
            f'<path d="{squircle(102, 820)}" fill="none" stroke="#fff" stroke-opacity="0.18" stroke-width="3"/>')


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">{body}</svg>'


def ring(ink, r=264, w=30):
    return f'<circle cx="{C}" cy="{C}" r="{r}" fill="none" stroke="{ink}" stroke-width="{w}"/>'


variants = {
    # A: reine Scheibe, aktives Segment oben
    "A-scheibe": lambda ink, rest, t, b: bg(t, b, "g") + ring(ink) + segments(ink=ink, rest_ink=rest),
    # B: Scheibe mit Blatt
    "B-mandarine": lambda ink, rest, t, b: bg(t, b, "g") + ring(ink) + segments(ink=ink, rest_ink=rest) + leaf(ink),
    # C: wie B, aktives Segment hebt sich aus der Frucht (Bewegung des Rads)
    "C-gehoben": lambda ink, rest, t, b: bg(t, b, "g") + ring(ink) + segments(ink=ink, rest_ink=rest, lift=34) + leaf(ink),
}

for name, build in variants.items():
    (OUT / f"{name}-hell.svg").write_text(svg(build("#fff", None, ORANGE_TOP, ORANGE_BOTTOM)))
    # Dunkel: graue Segmente, ein oranges - genau wie das Rad
    (OUT / f"{name}-dunkel.svg").write_text(svg(build("#FF7A33", "#4A4A4E", GRAPHITE_TOP, GRAPHITE_BOTTOM)))

# Menüleisten-Symbol (Vorlage, einfarbig): Ring + aktives Segment + angedeutete Segmente
menubar = svg(ring("#000", r=380, w=72)
              + segments(r_in=90, r_out=316, round_px=40, gap_deg=12, ink="#000", rest_opacity=0.35))
(OUT / "menubar.svg").write_text(menubar)

# Vorschauseite
cells = []
for name in variants:
    for mode in ("hell", "dunkel"):
        f = f"svg/{name}-{mode}.svg"
        cells.append(f'''<figure><div class="row">
<img src="{f}" width="256"><img src="{f}" width="128"><img src="{f}" width="64"><img src="{f}" width="32"><img src="{f}" width="16">
</div><figcaption>{name} · {mode}</figcaption></figure>''')
(HERE / "vorschau.html").write_text(f'''<!doctype html><meta charset="utf-8"><title>Logo-Entwürfe</title>
<style>
body{{margin:0;padding:32px;font:14px/20px -apple-system,system-ui;background:#f5f5f7;color:#1d1d1f}}
.grid{{display:grid;grid-template-columns:1fr 1fr;gap:24px}}
figure{{margin:0;padding:24px;background:#fff;border-radius:16px;box-shadow:0 1px 2px rgba(0,0,0,.05)}}
figure:nth-child(even){{background:#1c1c1e;color:#a1a1a6}}
.row{{display:flex;align-items:flex-end;gap:20px}}
figcaption{{margin-top:12px;color:inherit}}
.bar{{margin-top:24px;display:flex;gap:16px;align-items:center;padding:6px 16px;border-radius:10px;background:rgba(255,255,255,.7);width:max-content}}
.bar img{{height:16px}}
</style>
<div class="grid">{"".join(cells)}</div>
<div class="bar"><span>Menüleiste</span><img src="svg/menubar.svg"><img src="svg/menubar.svg" style="height:18px"></div>
''')
print("SVGs und vorschau.html geschrieben in", HERE)
