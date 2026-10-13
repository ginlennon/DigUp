"""Shared helpers for the Linux testbed generators: fonts (with per-character fallback, as macOS's text system does),
AppKit's colors, and AppKit's bottom-left coordinates turned into Pillow's top-left ones.

Fonts are the ones Ubuntu ships (fonts-noto-core, fonts-noto-color-emoji, fonts-dejavu-core); `font_path` says which
package is missing when one isn't there.
"""
import functools
import os

from fontTools.ttLib import TTCollection, TTFont
from PIL import Image, ImageDraw, ImageFont

FONT_DIRS = ["/usr/share/fonts/truetype/noto", "/usr/share/fonts/opentype/noto", "/usr/share/fonts/truetype/dejavu"]

# The macOS fonts' stand-ins: SF → Noto Sans, SF Mono → Noto Sans Mono, Kohinoor Bangla → Noto Sans Bengali,
# Geeza Pro → Noto Naskh Arabic.
FACES = {
    ("sans", "regular"): "NotoSans-Regular.ttf",
    ("sans", "semibold"): "NotoSans-SemiBold.ttf",
    ("sans", "bold"): "NotoSans-Bold.ttf",
    ("mono", "regular"): "NotoSansMono-Regular.ttf",
    ("mono", "bold"): "NotoSansMono-Bold.ttf",
    ("bn", "regular"): "NotoSansBengali-Regular.ttf",
    ("bn", "bold"): "NotoSansBengali-SemiBold.ttf",
    ("ar", "regular"): "NotoNaskhArabic-Regular.ttf",
    ("ar", "bold"): "NotoNaskhArabic-Bold.ttf",
}
FALLBACK = ["NotoSans-Regular.ttf", "NotoSansSymbols2-Regular.ttf", "NotoSansSymbols-Regular.ttf", "DejaVuSans.ttf"]
EMOJI = "NotoColorEmoji.ttf"
IGNORED = {"︎", "️"}  # variation selectors: text or emoji presentation; there's one glyph per font here


@functools.cache
def font_path(name):
    for folder in FONT_DIRS:
        path = os.path.join(folder, name)
        if os.path.exists(path):
            return path
    package = "fonts-noto-color-emoji" if name == EMOJI else (
        "fonts-dejavu-core" if name.startswith("DejaVu") else "fonts-noto-core")
    raise SystemExit(f"font {name} not found (sudo apt install {package})")


@functools.cache
def coverage(name):
    path = font_path(name)
    font = TTCollection(path).fonts[0] if path.endswith(".ttc") else TTFont(path, lazy=True)
    return frozenset(font.getBestCmap())


@functools.cache
def pil_font(name, size):
    if name == EMOJI:
        return ImageFont.truetype(font_path(name), 109)  # a bitmap font: one size, scaled afterwards
    return ImageFont.truetype(font_path(name), size, layout_engine=ImageFont.Layout.RAQM)


def face(kind="sans", weight="regular"):
    return FACES.get((kind, weight)) or FACES[(kind, "bold" if weight == "semibold" else "regular")]


def runs(text, primary):
    """Splits text into (font file, text) runs; spaces stay in the run they're in."""
    chain = [primary] + [f for f in FALLBACK if f != primary] + [EMOJI]
    out = []
    for i, ch in enumerate(text):
        if ch in IGNORED:
            continue
        if ch == " " and out:
            out[-1][1] += ch
            continue
        # Pictographs are color emoji, as on macOS, unless U+FE0E asks for the text style.
        as_text = text[i + 1:i + 2] == "︎"
        pictograph = (ord(ch) >= 0x1F000 or ch in "⛈") and not as_text and ord(ch) in coverage(EMOJI)
        name = EMOJI if pictograph else next((f for f in chain if ord(ch) in coverage(f)), FALLBACK[0])
        if out and out[-1][0] == name:
            out[-1][1] += ch
        else:
            out.append([name, ch])
    return out


def _emoji(text, size):
    font = pil_font(EMOJI, 109)
    w = int(font.getlength(text)) + 4
    im = Image.new("RGBA", (w, 128), (0, 0, 0, 0))
    ImageDraw.Draw(im).text((0, 0), text, font=font, embedded_color=True)
    scale = size * 1.15 / 128
    return im.resize((max(1, int(w * scale)), max(1, int(128 * scale))), Image.LANCZOS)


def measure(text, size, primary):
    width = 0
    for name, part in runs(text, primary):
        width += _emoji(part, size).width if name == EMOJI else pil_font(name, size).getlength(part)
    return width


def draw_text(image, xy, text, size, color, primary, rtl=False, direction=None):
    """Draws text with its top-left at xy, falling back per character. `rtl`: runs go right to left."""
    draw = ImageDraw.Draw(image)
    parts = runs(text, primary)
    if rtl:
        parts = parts[::-1]
    x, y = xy
    for name, part in parts:
        if name == EMOJI:
            im = _emoji(part, size)
            image.paste(im, (int(x), int(y + size * 0.05)), im)
            x += im.width
            continue
        font = pil_font(name, size)
        # Fallback fonts sit on the primary font's baseline.
        dy = pil_font(primary, size).getmetrics()[0] - font.getmetrics()[0] if name != primary else 0
        draw.text((x, y + dy), part, font=font, fill=color, direction=direction)
        x += font.getlength(part, direction=direction)
    return x


# AppKit's colors (light appearance).
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
SYSTEM = {"red": (255, 59, 48), "orange": (255, 149, 0), "yellow": (255, 204, 0), "green": (52, 199, 89),
          "blue": (0, 122, 255), "purple": (175, 82, 222), "pink": (255, 45, 85)}
SECONDARY_LABEL = (128, 128, 133)  # secondaryLabelColor (60, 60, 67 at 60%) over the light window chrome
DARK_GRAY = (85, 85, 85)          # NSColor.darkGray: white 1/3


def gray(white):
    v = round(white * 255)
    return (v, v, v)


def rgb(r, g, b):
    return (round(r * 255), round(g * 255), round(b * 255))


class Canvas:
    """A Pillow image addressed in AppKit's coordinates: origin bottom left, y up."""

    LINE = 1.19  # SF's line height over its point size: where `draw(at:)` puts a line's top above its origin

    def __init__(self, width, height, color=WHITE):
        self.w, self.h = width, height
        self.image = Image.new("RGB", (width, height), color)
        self.draw = ImageDraw.Draw(self.image)

    def box(self, x, y, w, h):
        return (x, self.h - (y + h), x + w, self.h - y)

    def fill(self, x, y, w, h, color, radius=0):
        if radius:
            self.draw.rounded_rectangle(self.box(x, y, w, h), radius=radius, fill=color)
        else:
            self.draw.rectangle(self.box(x, y, w, h), fill=color)

    def oval(self, x, y, w, h, color):
        self.draw.ellipse(self.box(x, y, w, h), fill=color)

    def text_at(self, s, x, y, size, color=BLACK, font="NotoSans-Regular.ttf"):
        """NSString.draw(at:): (x, y) is the bottom left of the line."""
        draw_text(self.image, (x, self.h - y - size * self.LINE), s, size, color, font)

    def text_in(self, s, x, y, w, h, size, color=BLACK, font="NotoSans-Regular.ttf", rtl=False):
        """NSString.draw(in:): one line from the top of the rect; right-aligned and right to left with `rtl`."""
        top = self.h - (y + h)
        if rtl:
            width = measure(s, size, font)
            draw_text(self.image, (x + w - width, top), s, size, color, font, rtl=True, direction="rtl")
        else:
            draw_text(self.image, (x, top), s, size, color, font)

    def save(self, path):
        self.image.save(path, optimize=True)


def window(width=1440, height=900, bg=WHITE, chrome=None, title="", title_xy=None, title_font="NotoSans-SemiBold.ttf"):
    """The desktop and an app window, as make_screenshots.swift draws them. Returns the canvas and the window rect."""
    c = Canvas(width, height, rgb(0.36, 0.45, 0.62))
    wx, wy, ww, wh = 80, 60, width - 160, height - 120
    c.fill(wx, wy, ww, wh, bg, radius=12)
    c.fill(wx, wy + wh - 44, ww, 44, chrome or gray(0.93))
    for i, name in enumerate(["red", "yellow", "green"]):
        c.oval(wx + 18 + i * 22, wy + wh - 29, 13, 13, SYSTEM[name])
    return c, (wx, wy, ww, wh)
