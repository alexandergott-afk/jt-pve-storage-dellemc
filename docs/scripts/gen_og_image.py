#!/usr/bin/env python3
"""Regenerate docs/og-image.png for the jt-pve-storage-dellemc Pages site.
Output is a 1200x630 PNG suitable for og:image / twitter:image previews.

    python3 docs/scripts/gen_og_image.py [VERSION]

VERSION defaults to whatever is in Makefile (VERSION = X.Y.Z~betaN). Pass an
override on the command line if needed.

Brand, matching the related projects' layout so the three read as one series:
    background  near-black #12161c with a soft blue radial in the top-right
    accent      Dell blue #0076ce
    fonts       DejaVu Sans Mono (title) / DejaVu Sans (everything else)

The pill row measures itself and shrinks the font until it fits the margin,
because this project has four families to name and the widths are not known
in advance.

Kept in the repository rather than in /tmp: the related projects lost theirs
that way once already.
"""

import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
DOCS = HERE.parent
REPO = DOCS.parent
OUT = DOCS / "og-image.png"

W, H = 1200, 630
MARGIN = 70
BG = (18, 22, 28)
BLUE = (0, 118, 206)
WHITE = (255, 255, 255)
MUTED = (176, 184, 194)
DIVIDER = (56, 62, 70)

FONT_MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
FONT_SANS_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

TITLE = "jt-pve-storage-dellemc"
SUBTITLE = "Dell EMC Storage Plugins for Proxmox VE"
# The third line is deliberately not a feature: the pills below already name
# the families, and what a first visitor most needs to know about this project
# is how much of it has met an array. The site and the README open the same
# way.
DESC = [
    "One VM disk is one array volume, so the array's own snapshots, thin",
    "clones and replication act on the unit an operator thinks about.",
    "Beta: one array has run it, a PowerVault ME4024 over Fibre Channel.",
]
FEATURES = [
    "PowerStore", "PowerVault ME", "PowerFlex", "Unity XT",
    "Fibre Channel", "iSCSI", "NVMe/TCP",
]
REPO_URL = "github.com/jasoncheng7115/jt-pve-storage-dellemc"
AUTHOR = "Jason Cheng (Jason Tools)"


def read_version() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    text = (REPO / "Makefile").read_text()
    # The version carries a Debian tilde in a prerelease (0.8.2~beta1), and
    # that is what the badge should say — this is beta software and the image
    # is the first thing anyone sees of it.
    m = re.search(r"^VERSION\s*=\s*(\S+)", text, re.M)
    if not m:
        raise SystemExit("Cannot parse VERSION from Makefile")
    return m.group(1)


def radial_glow(img: Image.Image) -> None:
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = W - 60, 60
    for r in range(520, 0, -20):
        alpha = max(0, int(46 * (1 - r / 520)))
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*BLUE, alpha))
    img.alpha_composite(glow)


def pill(draw, x, y, text, font, padx=18, pady=10, fill=BLUE):
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    w, h = tw + 2 * padx, th + 2 * pady
    draw.rounded_rectangle([x, y, x + w, y + h], radius=h // 2, fill=fill)
    draw.text((x + padx, y + pady - bbox[1]), text, font=font, fill=WHITE)
    return w, h


def fit_features(draw):
    """Largest font size at which the whole pill row fits the margins."""
    budget = W - 2 * MARGIN
    for size in range(18, 11, -1):
        font = ImageFont.truetype(FONT_SANS_BOLD, size)
        padx, gap = 12, 10
        total = 0
        for feat in FEATURES:
            bbox = draw.textbbox((0, 0), feat, font=font)
            total += (bbox[2] - bbox[0]) + 2 * padx + gap
        if total - gap <= budget:
            return font, padx, gap
    raise SystemExit("the feature row does not fit even at the smallest size")


def main() -> None:
    version = read_version()

    img = Image.new("RGBA", (W, H), (*BG, 255))
    radial_glow(img)
    draw = ImageDraw.Draw(img)

    draw.rectangle([0, 0, W, 4], fill=BLUE)

    pill_font = ImageFont.truetype(FONT_SANS_BOLD, 22)
    pill(draw, MARGIN, 75, f"v{version}  |  MIT License  |  Open Source",
         pill_font)

    draw.text((MARGIN, 140), TITLE,
              font=ImageFont.truetype(FONT_MONO_BOLD, 64), fill=WHITE)

    draw.text((MARGIN, 230), SUBTITLE,
              font=ImageFont.truetype(FONT_SANS_BOLD, 32), fill=WHITE)

    desc_font = ImageFont.truetype(FONT_SANS, 24)
    y = 305
    for line in DESC:
        draw.text((MARGIN, y), line, font=desc_font, fill=MUTED)
        y += 34

    feat_font, padx, gap = fit_features(draw)
    x = MARGIN
    for feat in FEATURES:
        w, _ = pill(draw, x, 430, feat, feat_font, padx=padx, pady=7)
        x += w + gap

    draw.line([(MARGIN, 545), (W - MARGIN, 545)], fill=DIVIDER, width=1)
    foot_font = ImageFont.truetype(FONT_SANS, 22)
    draw.text((MARGIN, 575), REPO_URL, font=foot_font, fill=MUTED)
    bbox = draw.textbbox((0, 0), AUTHOR, font=foot_font)
    draw.text((W - MARGIN - (bbox[2] - bbox[0]), 575), AUTHOR,
              font=foot_font, fill=MUTED)

    img.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"Wrote {OUT} (v{version})")


if __name__ == "__main__":
    main()
