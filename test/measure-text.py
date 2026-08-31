#!/usr/bin/env python3
"""Sum glyph advances for a string in one of the bundled TTFs, at a given size.

⚠️ MEASURE THE STRING; DO NOT EYEBALL THE LAYOUT (Core §1.1, Session 252). A
column header rendered "PRIORI…" because its field was sized to its own string
with 0.7px to spare — the game's text metrics differ slightly from the font's
advance widths, so it tipped over. This gives a real number to budget against.

The answer is an ADVANCE SUM and the client's own metrics differ by a fraction,
so treat it as a floor and leave slack — never size a field to exactly this.

  python3 test/measure-text.py Manrope-Bold 12 RAIDER UPGRADE "ILVL GAIN"
"""
import sys
from fontTools.ttLib import TTFont

face, size, strings = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
font = TTFont(f"Media/fonts/{face}.ttf")
upem = font["head"].unitsPerEm
cmap = font.getBestCmap()
hmtx = font["hmtx"]

for s in strings:
    total = 0
    missing = []
    for ch in s:
        name = cmap.get(ord(ch))
        if name is None:
            missing.append(ch)
            continue
        total += hmtx[name][0]
    px = total * size / upem
    note = f"  ⚠️ NO GLYPH FOR {missing!r} — renders as NOTHING" if missing else ""
    print(f"{face} {size:g}px  {px:7.1f}px  {s!r}{note}")
