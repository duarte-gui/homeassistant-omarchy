#!/usr/bin/env python3
"""Regenerate Icons.js from @mdi/svg's meta.json.

    curl -sSLO https://cdn.jsdelivr.net/npm/@mdi/svg@7.4.47/meta.json
    python3 tools/gen-icons.py meta.json Icons.js
"""

import json
import sys

meta = json.load(open(sys.argv[1]))
pairs = {}
for icon in meta:
    cp = int(icon["codepoint"], 16)
    # Nerd Fonts 3 carries Material Design Icons at their own codepoints, up to
    # F1AF0. Anything newer would render as a box.
    if cp > 0xF1AF0:
        continue
    pairs[icon["name"]] = cp
out = [".pragma library", "",
       "// Material Design Icons name -> codepoint, for the mdi:* icons Home Assistant",
       "// uses. Nerd Fonts 3 ships MDI at MDI's own codepoints (U+F0001-U+F1AF0), so",
       "// the bar's Nerd Font draws them directly. Generated from @mdi/svg 7.4.47",
       "// meta.json; icons newer than the font's copy are left out on purpose.", "",
       "var codepoints = {"]
items = sorted(pairs.items())
lines = []
for i in range(0, len(items), 6):
    lines.append("  " + ", ".join('"%s":0x%X' % kv for kv in items[i:i+6]))
out.append(",\n".join(lines))
out.append("}")
out.append("")
out.append("function glyph(name) {")
out.append("  var key = String(name || \"\").replace(/^mdi:/, \"\")")
out.append("  var cp = codepoints[key]")
out.append("  return cp ? String.fromCodePoint(cp) : \"\"")
out.append("}")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
print(len(pairs))
