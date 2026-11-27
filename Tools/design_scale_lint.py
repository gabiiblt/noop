#!/usr/bin/env python3
"""Fail on off-scale design literals in app-target Swift and Kotlin.

Radius scale: chip 8 / control 12 / compact 16 / card 22 (NoopMetrics.radius*,
Metrics.radius* on Android). Literals 1-6 (chart bars, ticks) and the pill value
are allowed. Odd font sizes are rejected too (even scale).
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT_DIRS = ["Strand", "StrandiOS", "StrandiOSShared"]
RADIUS = re.compile(r"cornerRadius: *(\d+(?:\.\d+)?)\b(?![.\d])")
KT_RADIUS = re.compile(r"RoundedCornerShape\((\d+(?:\.\d+)?)\.dp\)|cornerRadius = (\d+(?:\.\d+)?)\.dp")
FONT = re.compile(r"\.system\(size: *(\d+)\b(?![.\d])")
SMALL = {1, 1.5, 2, 2.5, 3, 4, 5, 6}


def main() -> int:
    bad = []
    for d in SWIFT_DIRS:
        for f in (ROOT / d).rglob("*.swift"):
            for n, line in enumerate(f.read_text().splitlines(), 1):
                for m in RADIUS.finditer(line):
                    if float(m.group(1)) not in SMALL:
                        bad.append(f"{f.relative_to(ROOT)}:{n}: cornerRadius {m.group(1)} - use NoopMetrics.radius*/cardRadius")
                for m in FONT.finditer(line):
                    v = int(m.group(1))
                    if v % 2 and v > 6:
                        bad.append(f"{f.relative_to(ROOT)}:{n}: odd font size {v} - use the even scale")
    for f in (ROOT / "android/app/src/main").rglob("*.kt"):
        if f.name == "Theme.kt":  # the token definitions live here
            continue
        for n, line in enumerate(f.read_text().splitlines(), 1):
            for m in KT_RADIUS.finditer(line):
                v = float(m.group(1) or m.group(2))
                if v not in SMALL and v < 100:
                    bad.append(f"{f.relative_to(ROOT)}:{n}: radius {v:g}.dp - use Metrics.radius*/cardRadius")
    print("\n".join(bad) if bad else "OK design scale")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
