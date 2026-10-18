#!/usr/bin/env python3
"""Builds the seat maps shown when a coach in the Wagenreihung is tapped (#365).

Source: DB's "Wagenreihungspläne" (© Deutsche Bahn AG), one PDF per ICE series as bahn.expert links
them (https://bahn.expert/WRSheets/<sheet>.pdf). Each PDF draws every coach from above with its seat
numbers as text, so the numbers' positions are read from the PDF (`pdftotext -bbox`) and taken out of the
drawing: the app draws them itself (upright also when a coach is shown turned round) and can highlight
a reserved seat.

Writes one image per coach layout to `BetterBahn/Assets.xcassets/SeatMaps/` and the seats to
BetterBahnKit's `Resources/SeatMaps.json`. Needs poppler (`pdftoppm`, `pdftotext`), Pillow and numpy:

    python3 scripts/make-seat-maps.py [--cache DIR] [--debug DIR]

Coaches are drawn with the lower coach numbers on the left (21 left, 29 right) on every sheet.
"""
import argparse
import hashlib
import html
import io
import json
import re
import shutil
import subprocess
import sys
from collections import deque
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT_JSON = ROOT / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources/SeatMaps.json"
OUT_ASSETS = ROOT / "BetterBahn/Assets.xcassets/SeatMaps"
BASE_URL = "https://bahn.expert/WRSheets/"
# The ICE sheets bahn.expert has (IC2.TRE left out: only ICEs get a seat map).
SHEETS = ["401", "401.LDV", "402", "403", "407", "408", "411.S1", "411.S2", "412", "412.7", "412.13"]
# Misprints on DB's sheets, fixed by the seat's place in the coach (fractions of its drawing, as in
# SeatMaps.json): (sheet, coach, x, y) → the right number. The neighbouring columns count on in fours.
CORRECTIONS = {
    # ICE 3neo Wagen 24: the column printed 77, 76, 75, 75 is 78, 77, 76, 75 (checked in the coach).
    ("408", "24", 0.3338, 0.1393): "78",
    ("408", "24", 0.3338, 0.2911): "77",
    ("408", "24", 0.3338, 0.6067): "76",
    # ICE 1 modernised Wagen 6: 44, 43, 43, 41 is 44, 43, 42, 41.
    ("401.LDV", "6", 0.3213, 0.6303): "42",
}
# Detection resolution and the height of a coach image in pixels.
DETECT_SCALE = 2.0
IMAGE_HEIGHT = 320

WORD = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)</word>')


def download(sheet, cache):
    path = cache / f"{sheet}.pdf"
    if not path.exists():
        request = urllib.request.Request(BASE_URL + f"{sheet}.pdf", headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15",
            "Referer": "https://bahn.expert/"})
        path.write_bytes(urllib.request.urlopen(request, timeout=60).read())
    return path


def pages(pdf):
    """Per page: (width, height, words), words as (x0, y0, x1, y1, text) in points."""
    out = subprocess.run(["pdftotext", "-bbox", str(pdf), "-"], capture_output=True, text=True, check=True).stdout
    result = []
    for chunk in out.split("<page ")[1:]:
        size = re.match(r'width="([\d.]+)" height="([\d.]+)"', chunk)
        words = joined_digits([(float(a), float(b), float(c), float(d), html.unescape(t)) for a, b, c, d, t in WORD.findall(chunk)])
        result.append((float(size.group(1)), float(size.group(2)), words))
    return result


def render(pdf, page, scale, box=None):
    """The page (or the box x0, y0, x1, y1 in points) as an RGB array at `scale` pixels per point."""
    args = ["pdftoppm", "-png", "-f", str(page), "-l", str(page), "-r", str(72 * scale)]
    if box:
        x0, y0, x1, y1 = (round(v * scale) for v in box)
        args += ["-x", str(x0), "-y", str(y0), "-W", str(x1 - x0), "-H", str(y1 - y0)]
    png = subprocess.run(args + [str(pdf)], capture_output=True, check=True).stdout
    return np.asarray(Image.open(io.BytesIO(png)).convert("RGB"))


def joined_digits(words):
    """`words` with numbers the PDF splits into single digits ("7", "5" for seat 75 on the ICE T) joined."""
    result = []
    for word in words:
        last = result[-1] if result else None
        if (last and re.fullmatch(r"\d{1,2}", last[4]) and re.fullmatch(r"\d", word[4])
                and same_line(last, word) and 0 <= word[0] - last[2] < 0.5):
            result[-1] = (last[0], min(last[1], word[1]), word[2], max(last[3], word[3]), last[4] + word[4])
        else:
            result.append(word)
    return result


def same_line(a, b):
    return abs((a[1] + a[3]) / 2 - (b[1] + b[3]) / 2) < 2


def labels(words):
    """Coach labels: ("Nr." | "Wagen") followed by "29/39" or "14", with the class and type lines above."""
    found = []
    for i, word in enumerate(words):
        if word[4] not in ("Nr.", "Wagen") or i + 1 >= len(words):
            continue
        following = words[i + 1]
        if not re.fullmatch(r"\d{1,2}(/\d{1,2})?", following[4]) or not same_line(word, following):
            continue
        # The lines above it in the same column: "(Apmzf 403.0)" and "1. Kl.-Endwagen".
        above = [w for w in words if w[3] <= word[1] + 0.5 and word[1] - w[3] < 30 and abs(w[0] - word[0]) < 60]
        lines = []
        for w in sorted(above, key=lambda w: (round(w[1]), w[0])):
            if lines and same_line(lines[-1][-1], w):
                lines[-1].append(w)
            else:
                lines.append([w])
        texts = [" ".join(w[4] for w in line) for line in lines]
        kind = next((t.strip("()") for t in texts if t.startswith("(")), None)
        title = " ".join(t for t in texts if not t.startswith("(")) or None
        found.append({
            "numbers": following[4].split("/"),
            "title": title.replace("‒", "-") if title else None,
            "type": kind,
            "box": (min([word[0]] + [w[0] for w in above]), min([word[1]] + [w[1] for w in above]),
                    following[2], following[3]),
            "horizontal": word[4] == "Wagen",
        })
    return found


def runs(mask, gap):
    """(start, end) of the True runs in `mask`, joining runs less than `gap` apart."""
    result = []
    start = None
    last = None
    for i, on in enumerate(mask):
        if not on:
            continue
        if start is None or i - last > gap:
            if start is not None:
                result.append((start, last + 1))
            start = i
        last = i
    if start is not None:
        result.append((start, last + 1))
    return result


def coach_boxes(image, page_labels, width, height):
    """The drawing of each labelled coach, in points: x0, y0, x1, y1."""
    # Anything but white paper: the coaches' cream floors count too.
    ink = image.min(axis=2) < 245
    s = DETECT_SCALE
    boxes = []
    horizontal = [l for l in page_labels if l["horizontal"]]
    for label in page_labels:
        if label["horizontal"]:
            continue
        x0 = int((label["box"][2] + 8) * s)
        x1 = int((width - 25) * s)
        y0 = int(max(0, label["box"][1] - 30) * s)
        y1 = int(min(height, label["box"][1] + 120) * s)
        rows = ink[y0:y1, x0:x1].mean(axis=1) > 0.08
        band = max(runs(rows, int(3 * s)), key=lambda r: r[1] - r[0], default=None)
        if band is None:
            boxes.append(None)
            continue
        top, bottom = y0 + band[0], y0 + band[1]
        # Door steps and the noses reach a bit further than the body.
        low = ink[:, x0:x1].mean(axis=1) > 0.01
        for _ in range(int(12 * s)):
            if top > 0 and low[top - 1]:
                top -= 1
        for _ in range(int(12 * s)):
            if bottom < len(low) and low[bottom]:
                bottom += 1
        columns = ink[top:bottom, x0:x1].mean(axis=0) > 0.12
        span = max(runs(columns, int(8 * s)), key=lambda r: r[1] - r[0])
        boxes.append(((x0 + span[0]) / s - 2, top / s - 2, (x0 + span[1]) / s + 2, bottom / s + 2))
    if horizontal:
        # BR 408: all coaches side by side below their labels.
        y0 = int(max(l["box"][3] for l in horizontal) * s)
        y1 = int(min(height, y0 / s + 140) * s)
        rows = ink[y0:y1].mean(axis=1) > 0.15
        band = max(runs(rows, int(3 * s)), key=lambda r: r[1] - r[0])
        top, bottom = y0 + band[0], y0 + band[1]
        strip = ink[top:bottom]
        columns = strip.mean(axis=0)
        span = max(runs(columns > 0.12, int(8 * s)), key=lambda r: r[1] - r[0])
        ordered = sorted(horizontal, key=lambda l: l["box"][0])
        centers = [((l["box"][0] + l["box"][2]) / 2) * s for l in ordered]
        cuts = [span[0]]
        for a, b in zip(centers, centers[1:]):
            lo, hi = int(a + (b - a) * 0.3), int(a + (b - a) * 0.7)
            cuts.append(lo + int(np.argmin(columns[lo:hi])))
        cuts.append(span[1])
        by_label = {id(l): (cuts[i] / s, top / s - 2, cuts[i + 1] / s, bottom / s + 2) for i, l in enumerate(ordered)}
        boxes += [by_label[id(l)] for l in page_labels if l["horizontal"]]
    return boxes


def strip_numbers(image, seats, scale, box):
    """Paints the seat numbers out of the coach image."""
    for seat in seats:
        x0 = max(0, int((seat[0] - box[0]) * scale))
        x1 = min(image.shape[1], int(np.ceil((seat[2] - box[0]) * scale)))
        y0 = max(0, int((seat[1] - box[1]) * scale))
        y1 = min(image.shape[0], int(np.ceil((seat[3] - box[1]) * scale)))
        region = image[y0:y1, x0:x1].reshape(-1, 3).astype(int)
        if len(region) == 0:
            continue
        quantized = [tuple(p // 24) for p in region]
        counts = {}
        for q in quantized:
            counts[q] = counts.get(q, 0) + 1
        background_key = max(counts, key=counts.get)
        background = region[[q == background_key for q in quantized]].mean(axis=0)
        # DB prints seat numbers light on the seats and dark on the floor or the bike spaces' grey circles: the
        # number is whichever side has more pixels, so a seat's darker outline stays.
        brightness = region.sum(axis=1)
        lighter = (brightness > background.sum() + 120).sum()
        darker = (brightness < background.sum() - 120).sum()
        if background.sum() > 690 and darker > 0.3 * len(region):
            # A white number filling a dark badge (some ICE 4 seats): the badge is the background.
            background = region[brightness < background.sum() - 120].mean(axis=0)
            glyph = region[np.argmax(brightness)]
        else:
            glyph = region[np.argmax(brightness)] if lighter >= darker else region[np.argmin(brightness)]
        direction = glyph - background
        length = max(1, (direction ** 2).sum())
        t = ((region - background) * direction).sum(axis=1) / length
        mask = (t > 0.12).reshape(y1 - y0, x1 - x0)
        patch = image[y0:y1, x0:x1]
        patch[mask] = background.astype(np.uint8)


def corrected(sheet, coach, seat, box):
    """`seat` with the number from CORRECTIONS where DB misprinted it."""
    x = (seat[0] - box[0]) / (box[2] - box[0])
    y = (seat[1] - box[1]) / (box[3] - box[1])
    for (fix_sheet, fix_coach, fix_x, fix_y), number in CORRECTIONS.items():
        if (fix_sheet, fix_coach) == (sheet, coach) and abs(x - fix_x) < 0.003 and abs(y - fix_y) < 0.003:
            return seat[:4] + (number,)
    return seat


def components(mask):
    """Bounding boxes (x, y, width, height) and pixel counts of the 4-connected True areas of `mask`."""
    seen = np.zeros_like(mask, dtype=bool)
    height, width = mask.shape
    found = []
    for y, x in zip(*np.nonzero(mask)):
        if seen[y, x]:
            continue
        seen[y, x] = True
        queue = deque([(y, x)])
        x0 = x1 = x
        y0 = y1 = y
        count = 0
        while queue:
            cy, cx = queue.popleft()
            count += 1
            x0, x1, y0, y1 = min(x0, cx), max(x1, cx), min(y0, cy), max(y1, cy)
            for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        found.append((int(x0), int(y0), int(x1 - x0 + 1), int(y1 - y0 + 1), count))
    return found


def icons(image):
    """The pictograms (WC, luggage, wheelchair …: dark blue or black boxes) as (x, y, width, height) fractions
    of the image, so the app can turn them upright again in a coach shown turned round."""
    height, width = image.shape[:2]
    dark = image.astype(int).sum(axis=2) < 260
    # Only what stays dark across a 7×7 square: the boxes' fill, not the lines touching them (BR 408's black
    # pictograms sit on black walls and racks).
    r = 3
    sums = np.pad(dark.astype(int), ((r + 1, r), (r + 1, r))).cumsum(axis=0).cumsum(axis=1)
    k = 2 * r + 1
    solid = (sums[k:, k:] - sums[:-k, k:] - sums[k:, :-k] + sums[:-k, :-k]) == k * k
    lo, hi = IMAGE_HEIGHT * 0.07, IMAGE_HEIGHT * 0.22
    # A pictogram's white symbol splits its box into pieces: join pieces that nearly touch (pictograms side by
    # side become one box, which turns upright just as well).
    boxes = [[x - r, y - r, x + w + r, y + h + r] for x, y, w, h, _ in components(solid) if w < hi and h < hi]
    gap = 2 * r + 4
    merged = True
    while merged:
        merged = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                if a[0] - gap <= b[2] and b[0] - gap <= a[2] and a[1] - gap <= b[3] and b[1] - gap <= a[3]:
                    boxes[i] = [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
                    del boxes[j]
                    merged = True
                    break
            if merged:
                break
    # Grow each box over the box's rest below or beside a label ("Recycling") while the next row or column is
    # still mostly dark.
    for box in boxes:
        for _ in range(12):
            grown = False
            if box[1] > 0 and dark[box[1] - 1, box[0]:box[2]].mean() > 0.3:
                box[1] -= 1
                grown = True
            if box[3] < height and dark[box[3], box[0]:box[2]].mean() > 0.3:
                box[3] += 1
                grown = True
            if box[0] > 0 and dark[box[1]:box[3], box[0] - 1].mean() > 0.3:
                box[0] -= 1
                grown = True
            if box[2] < width and dark[box[1]:box[3], box[2]].mean() > 0.3:
                box[2] += 1
                grown = True
            if not grown:
                break
    boxes = [(x0, y0, x1 - x0, y1 - y0) for x0, y0, x1, y1 in boxes]
    boxes = [(x, y, w, h) for x, y, w, h in boxes if lo <= h <= hi and lo <= w <= hi * 3.5 and w / h >= 0.55]
    pad = 3
    return [[round(max(0, x - pad) / width, 4), round(max(0, y - pad) / height, 4),
             round((min(width, x + w + pad) - max(0, x - pad)) / width, 4),
             round((min(height, y + h + pad) - max(0, y - pad)) / height, 4)] for x, y, w, h in boxes]


def coach_image(pdf, page, box, seats):
    scale = IMAGE_HEIGHT / (box[3] - box[1])
    image = render(pdf, page, scale, box).copy()
    strip_numbers(image, seats, scale, box)
    return Image.fromarray(image)


def png_bytes(image):
    quantized = image.quantize(colors=96, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    buffer = io.BytesIO()
    quantized.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def write_asset(name, data):
    folder = OUT_ASSETS / f"{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.png").write_bytes(data)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{name}.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(tempfile.gettempdir()) / "seat-map-pdfs")
    parser.add_argument("--debug", type=Path)
    parser.add_argument("--only", help="one sheet, for checking the output")
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    if args.debug:
        args.debug.mkdir(parents=True, exist_ok=True)

    if OUT_ASSETS.exists():
        shutil.rmtree(OUT_ASSETS)
    OUT_ASSETS.mkdir(parents=True)
    (OUT_ASSETS / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False},
    }, indent=2) + "\n")

    images = {}  # image hash → asset name, so identical coaches share one image
    result = {}
    for sheet in [args.only] if args.only else SHEETS:
        pdf = download(sheet, args.cache)
        coaches = []
        title = None
        for number, (width, height, words) in enumerate(pages(pdf), start=1):
            if title is None:
                head = [w[4] for w in words if w[1] < 130 and w[4] not in ("Daten", "und", "Fakten")]
                title = " ".join(head).strip() or None
            page_labels = labels(words)
            if not page_labels:
                continue
            page_image = render(pdf, number, DETECT_SCALE)
            debug = Image.fromarray(page_image.copy()) if args.debug else None
            for label, box in zip(page_labels, coach_boxes(page_image, page_labels, width, height)):
                if box is None:
                    print(f"{sheet}: no drawing for Wagen {label['numbers']}", file=sys.stderr)
                    continue
                seats = [w for w in words if re.fullmatch(r"\d{1,3}", w[4])
                         and box[0] <= (w[0] + w[2]) / 2 <= box[2] and box[1] <= (w[1] + w[3]) / 2 <= box[3]]
                image = coach_image(pdf, number, box, seats)
                pictograms = icons(np.asarray(image))
                data = png_bytes(image)
                digest = hashlib.sha1(data).hexdigest()
                name = images.get(digest)
                if name is None:
                    name = f"Seats-{sheet.replace('.', '-')}-{label['numbers'][0]}"
                    images[digest] = name
                    write_asset(name, data)
                w, h = box[2] - box[0], box[3] - box[1]
                seats = [corrected(sheet, label["numbers"][0], seat, box) for seat in seats]
                coaches.append({
                    "numbers": label["numbers"],
                    "title": label["title"],
                    "type": label["type"],
                    "image": name,
                    "aspect": round(w / h, 4),
                    "seats": [[s[4], round((s[0] - box[0]) / w, 4), round((s[1] - box[1]) / h, 4),
                               round((s[2] - s[0]) / w, 4), round((s[3] - s[1]) / h, 4)]
                              for s in seats],
                    "icons": pictograms,
                })
                if debug:
                    draw = ImageDraw.Draw(debug)
                    draw.rectangle([v * DETECT_SCALE for v in box], outline=(255, 0, 0), width=2)
                    for s in seats:
                        draw.rectangle([v * DETECT_SCALE for v in s[:4]], outline=(0, 200, 0))
            if debug:
                debug.save(args.debug / f"{sheet}-{number}.png")
        result[sheet] = {"title": title, "coaches": coaches}
        print(f"{sheet}: {len(coaches)} coaches, {sum(len(c['seats']) for c in coaches)} seats", file=sys.stderr)
        if args.debug:
            for coach in coaches:
                src = OUT_ASSETS / f"{coach['image']}.imageset" / f"{coach['image']}.png"
                shutil.copy(src, args.debug / f"{sheet}-coach-{coach['numbers'][0]}.png")

    OUT_JSON.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
