#!/usr/bin/env python3
"""Build NOOP's body-map geometry (Strand/Resources/BodyGeometry.json) from openGym's `body-paths.js`.

Input: openGym's `frontend/src/lib/body-paths.js` (path --paths), itself converted from MuscleMap by Melih Colpan
(MIT; see ATTRIBUTION.md). Only the path data is read; nothing under `catalogue/media` is touched.

What this does, and nothing else about the artwork:
  - splits the generic shoulder into its three heads and the upper back into the lats and the upper back, by path
    index, exactly as openGym's `body-geometry.js` does (the indices are its `SPLIT` table);
  - renames each region to NOOP's `LiftMuscle` raw value (chest, frontDelts, upperBack, traps, ...);
  - moves everything NOOP has no muscle for (head, hands, feet, serratus, hip flexors, shins, ...) into a
    `silhouette` list that is drawn but never shaded;
  - records, where a view has no path of its own for the side delts, that the front and rear heads take the side
    delts' level too (a lateral raise lights the shoulder from both sides).

Output shape: { "<body>": { "<side>": { "viewBox": [x, y, w, h], "regions": { "<muscle>": [d, ...] },
                                         "silhouette": [d, ...], "blend": { "<muscle>": ["<muscle>"] } } } }
"""
from __future__ import annotations

import argparse
import json
import re
import sys

# openGym's slug -> NOOP's LiftMuscle raw value.
SLUG = {
    "chest": "chest", "front-delts": "frontDelts", "side-delts": "sideDelts", "rear-delts": "rearDelts",
    "triceps": "triceps", "lats": "lats", "upper-back": "upperBack", "trapezius": "traps", "biceps": "biceps",
    "forearm": "forearms", "quadriceps": "quads", "hamstring": "hamstrings", "gluteal": "glutes",
    "adductors": "adductors", "calves": "calves", "abs": "abs", "obliques": "obliques", "lower-back": "lowerBack",
}

# Indices into body-paths.js's lists, from openGym's `body-geometry.js` (checked there against the paths' heights).
SPLIT = {
    "male": {
        "front": {"deltoids": {"front-delts": [0, 1]}},
        "back": {"deltoids": {"rear-delts": [0, 1]}, "upper-back": {"lats": [1, 5], "upper-back": [0, 2, 3, 4]}},
    },
    "female": {
        "front": {"deltoids": {"side-delts": [0, 2], "front-delts": [1, 3]}},
        "back": {"deltoids": {"rear-delts": [0, 1]}, "upper-back": {"lats": [1, 3], "upper-back": [0, 2]}},
    },
}


def load_paths(text: str) -> dict:
    """`export default {...}` -> the object. The module is plain JSON after its header comment."""
    match = re.search(r"export default (\{.*\})\s*$", text, re.S)
    if not match:
        raise SystemExit("body-paths.js: no `export default {...}` found")
    return json.loads(match.group(1))


def convert(paths: dict) -> dict:
    out: dict = {}
    for body, views in paths.items():
        out[body] = {}
        for side, view in views.items():
            parts = {k: list(v) for k, v in view["p"].items()}
            for source, targets in SPLIT.get(body, {}).get(side, {}).items():
                original = parts.pop(source, [])
                for slug, indices in targets.items():
                    missing = [i for i in indices if i >= len(original)]
                    if missing:
                        raise SystemExit(f"{body}/{side}/{source}: split index {missing} out of range ({len(original)} paths)")
                    parts.setdefault(slug, []).extend(original[i] for i in indices)
            regions = {SLUG[slug]: d for slug, d in parts.items() if slug in SLUG}
            silhouette = [p for slug, d in parts.items() if slug not in SLUG for p in d]
            vb = [float(x) for x in view["vb"].split()]
            blend = {}
            if "sideDelts" not in regions:
                for head in ("frontDelts", "rearDelts"):
                    if head in regions:
                        blend[head] = ["sideDelts"]
            out[body][side] = {"viewBox": vb, "regions": regions, "silhouette": silhouette, "blend": blend}
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--paths", required=True, help="openGym's frontend/src/lib/body-paths.js")
    ap.add_argument("--out", default="Strand/Resources/BodyGeometry.json")
    args = ap.parse_args(argv)
    with open(args.paths, encoding="utf-8") as f:
        result = convert(load_paths(f.read()))
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    n = sum(len(d) for b in result.values() for v in b.values() for d in v["regions"].values())
    print(f"wrote {args.out}: {n} muscle paths", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
