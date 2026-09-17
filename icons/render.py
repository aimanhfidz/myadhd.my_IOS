"""Draw the app icon at 1024, which is the only size the App Store wants.

A copy. The original lives in the web app's repo at icons/render.py, where
the same draw_icon() also makes the favicons, the apple-touch-icon and the
OAuth consent logo — none of which this project has any use for. It is
copied rather than imported because the two repos are separate now, and a
build step that needs somebody else's checkout is a build step that stops
working.

That makes the geometry below a third thing duplicated across the two
repos, alongside the two copies of Baloo2-Variable.ttf. README.md lists it
with the rest of the promises. If the mark ever changes, it changes in
both, and icon-source.svg beside this file stays the readable definition.

There is no SVG rasteriser on this machine, and the mark is four rotated
bars and a capsule — so this draws the shapes rather than interpreting the
file. Everything is drawn at 8x and downsampled, which is where the clean
edges come from: Pillow has no antialiased polygon fill.

    python3 icons/render.py

Needs Pillow.
"""

import math
import pathlib

from PIL import Image, ImageDraw

GROUND = (42, 45, 51)      # #2A2D33 — opaque edge to edge; iOS and Android
                           # both mask the corners themselves, and a
                           # transparent tile lands on black.
ORANGE = (247, 92, 3)      # #F75C03
PURPLE = (123, 63, 228)    # #7B3FE4

SS = 8                     # supersample factor

# The mark is defined in a 100-unit box centred on (50,50). Its arms run
# from 18 to 82, so it spans 64 of those units.
MARK_SPAN = 64.0

# How much of the tile the mark fills. The old value was 0.50, which left
# the mark looking lost inside its own ground at home-screen size. 0.66
# fills the tile the way the brand sheet does and still clears Android's
# maskable safe circle: the furthest corner sits at r=0.334*N against a
# safe radius of 0.40*N.
FILL = 0.66

# x0, y0, x1, y1, rotation in degrees about (50,50)
BARS = [
    (46.5, 18, 53.5, 82,   0),    # vertical
    (46.5, 18, 53.5, 82,  90),    # horizontal
    (46.5, 18, 53.5, 82,  45),    # one diagonal, full length
    (46.5, 18, 53.5, 50, -45),    # the other, cut short — the asymmetry
                                  # that stops it reading as a snowflake
]

PILL = (64.5, 64.5, 71.5, 71.5)   # a capsule, stroke width 7, round caps
PILL_W = 7.0


def rotate(x, y, deg, cx=50.0, cy=50.0):
    """SVG's rotate(deg cx cy). y grows downward here as it does there, so
       a positive angle turns clockwise on screen in both."""
    a = math.radians(deg)
    dx, dy = x - cx, y - cy
    return (cx + dx * math.cos(a) - dy * math.sin(a),
            cy + dx * math.sin(a) + dy * math.cos(a))


def draw_icon(size):
    n = size * SS
    img = Image.new('RGB', (n, n), GROUND)
    d = ImageDraw.Draw(img)

    scale = (n * FILL) / MARK_SPAN
    off = n / 2.0 - 50.0 * scale          # puts local (50,50) at the centre
    to_px = lambda x, y: (off + x * scale, off + y * scale)

    for x0, y0, x1, y1, deg in BARS:
        corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        d.polygon([to_px(*rotate(x, y, deg)) for x, y in corners], fill=ORANGE)

    # The capsule: a thick segment plus a disc at each end, which is what
    # stroke-linecap="round" means.
    ax, ay = to_px(PILL[0], PILL[1])
    bx, by = to_px(PILL[2], PILL[3])
    r = PILL_W * scale / 2.0
    d.line([(ax, ay), (bx, by)], fill=PURPLE, width=int(round(r * 2)))
    for cx, cy in ((ax, ay), (bx, by)):
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=PURPLE)

    return img.resize((size, size), Image.LANCZOS)


OUT = pathlib.Path(__file__).parent.parent / (
    'MyADHD/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')

if __name__ == '__main__':
    OUT.parent.mkdir(parents=True, exist_ok=True)
    draw_icon(1024).save(OUT, optimize=True)
    print(f'  {OUT.name:24} 1024x1024  ->  {OUT.parent.relative_to(OUT.parents[3])}')
