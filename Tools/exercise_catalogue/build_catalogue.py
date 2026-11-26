#!/usr/bin/env python3
"""Build NOOP's bundled exercise catalogue: one read-only SQLite file plus one still image per exercise.

Inputs (both checked out locally, never fetched by this script):
  --opengym  a checkout of openGym. Only `catalogue/exercises/*.json` and `catalogue/i18n/fr.json` are read:
             exercise text, muscles, equipment and the French translation. Reused under the MIT
             authorization Duarte Santos granted Gabriel Bolatoglu (see ATTRIBUTION.md). Nothing under
             `catalogue/media` is read: those files belong to Gym visual and are not licensed to NOOP.
  --fedb     a checkout of yuhonas/free-exercise-db (Unlicense). Its stills are the only images used.

Outputs:
  <out>/ExerciseCatalogue.sqlite   table `exercise`, one row per openGym exercise (variant stubs skipped)
  <out>/ExerciseImages/<id>.webp   the matched still, downsampled, for exercises with a confident match
  --review CSV                     every image match with its score, for a human pass

Images are matched by name, conservatively: a wrong picture is worse than none, so a match needs the
same equipment family, an overlapping primary muscle and a high token overlap. Exercises without a
match show a muscle illustration in the app.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import sqlite3
import sys
import unicodedata

SCHEMA_VERSION = 1
IMAGE_MAX_PX = 360
WEBP_QUALITY = 72
MATCH_THRESHOLD = 1.0  # the cores must be the same words; see `core`

# openGym muscle words -> NOOP's stored `LiftMuscle` tokens (Packages/WhoopStore/.../LiftMuscle.swift).
# Unnamed shoulder heads ("delts", "shoulders") read as front delts: the head most compound presses
# and raises load. Words NOOP has no muscle for (hip flexors, shins, cardio) map to nothing rather than
# to a neighbour, so the muscle split never counts sets against a muscle that did not work.
MUSCLE_MAP = {
    "abs": "abs", "abdominals": "abs", "core": "abs", "lower abs": "abs",
    "pectorals": "chest", "chest": "chest", "upper chest": "chest",
    "biceps": "biceps", "brachialis": "biceps",
    "glutes": "glutes",
    "front delts": "frontDelts", "delts": "frontDelts", "shoulders": "frontDelts", "deltoids": "frontDelts",
    "side delts": "sideDelts",
    "rear delts": "rearDelts", "rear deltoids": "rearDelts", "rotator cuff": "rearDelts",
    "triceps": "triceps",
    "upper back": "upperBack", "back": "upperBack", "rhomboids": "upperBack",
    "lats": "lats", "latissimus dorsi": "lats",
    "calves": "calves", "soleus": "calves",
    "quads": "quads", "quadriceps": "quads",
    "forearms": "forearms", "wrists": "forearms", "wrist flexors": "forearms", "wrist extensors": "forearms",
    "grip muscles": "forearms", "hands": "forearms",
    "hamstrings": "hamstrings",
    "spine": "lowerBack", "lower back": "lowerBack",
    "traps": "traps", "trapezius": "traps", "levator scapulae": "traps",
    "adductors": "adductors", "inner thighs": "adductors", "groin": "adductors",
    "abductors": "abductors",
    "obliques": "obliques",
    "sternocleidomastoid": "neck",
}
MUSCLE_ORDER = ["chest", "frontDelts", "sideDelts", "rearDelts", "triceps", "lats", "upperBack", "traps",
                "biceps", "forearms", "quads", "hamstrings", "glutes", "adductors", "abductors", "calves",
                "abs", "obliques", "lowerBack", "neck"]

# free-exercise-db equipment -> the openGym equipment values it can stand for.
FEDB_EQUIPMENT = {
    "body only": {"body weight", "weighted", "assisted"},
    "": {"body weight"},  # free-exercise-db leaves equipment empty for some bodyweight moves
    "barbell": {"barbell", "olympic barbell", "trap bar"},
    "dumbbell": {"dumbbell"},
    "cable": {"cable", "rope"},
    "machine": {"leverage machine", "smith machine", "sled machine", "assisted"},
    "kettlebells": {"kettlebell"},
    "bands": {"band", "resistance band"},
    "e-z curl bar": {"ez barbell"},
    "medicine ball": {"medicine ball"},
    "exercise ball": {"stability ball", "bosu ball"},
    "foam roll": {"roller"},
}
# free-exercise-db muscle words -> NOOP tokens, for the primary-muscle agreement check.
FEDB_MUSCLE = {
    "abdominals": "abs", "abductors": "abductors", "adductors": "adductors", "biceps": "biceps",
    "calves": "calves", "chest": "chest", "forearms": "forearms", "glutes": "glutes",
    "hamstrings": "hamstrings", "lats": "lats", "lower back": "lowerBack", "middle back": "upperBack",
    "neck": "neck", "quadriceps": "quads", "shoulders": "frontDelts", "traps": "traps", "triceps": "triceps",
}
SHOULDER = {"frontDelts", "sideDelts", "rearDelts"}
STOP = {"the", "a", "with", "on", "to", "and", "of", "for", "in", "your", "s"}
SYNONYMS = {"db": "dumbbell", "bb": "barbell", "kb": "kettlebell", "ez": "ezbar", "e-z": "ezbar",
            "pulldown": "pulldown", "pull-down": "pulldown", "pushup": "pushup", "push-up": "pushup",
            "pullup": "pullup", "pull-up": "pullup", "chinup": "chinup", "chin-up": "chinup",
            "situp": "situp", "sit-up": "situp", "flye": "fly", "flyes": "fly", "flys": "fly",
            "raises": "raise", "curls": "curl", "presses": "press", "rows": "row", "extensions": "extension",
            "lunges": "lunge", "squats": "squat", "shrugs": "shrug", "dips": "dip", "crunches": "crunch"}


def fold(text: str) -> str:
    """Lower case, accents removed: the search key matches 'developpe' as well as 'développé'."""
    t = unicodedata.normalize("NFKD", text.lower())
    return "".join(ch for ch in t if not unicodedata.combining(ch))


def tokens(name: str) -> set[str]:
    t = fold(name).replace("e-z", "ez")
    out = set()
    for w in re.split(r"[^a-z0-9-]+", t):
        w = w.strip("-")
        if not w or w in STOP:
            continue
        w = SYNONYMS.get(w, w)
        # Plural to singular, so "Pullups" meets "pull-up" and "Raises" meets "raise" ("press" keeps its s).
        if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
            w = SYNONYMS.get(w[:-1], w[:-1])
        out.add(w)
    return out


# Words that name the equipment (already checked separately) or carry no movement information. Stripped
# from both names before comparing, so "barbell good morning" meets "Good Morning" and "barbell incline
# bench press" meets "Barbell Incline Bench Press - Medium Grip". Everything else must agree: a word on
# one side only (rear, hammer, zercher, jump, overhead, preacher...) names a different movement.
EQUIPMENT_WORDS = {"barbell", "dumbbell", "cable", "machine", "kettlebell", "band", "bands", "lever", "leverage",
                   "smith", "ezbar", "kettlebells", "dumbbells"}
FILLER = {"medium", "grip", "attachment", "version", "v", "2", "1", "rope"}


def core(name: str) -> frozenset[str]:
    return frozenset(t for t in tokens(name) if t not in EQUIPMENT_WORDS and t not in FILLER)


def muscles(words) -> list[str]:
    found = {MUSCLE_MAP[w] for w in (words or []) if w in MUSCLE_MAP}
    return [m for m in MUSCLE_ORDER if m in found]


def load_opengym(root: str) -> tuple[list[dict], dict]:
    ex = []
    for path in sorted(glob.glob(os.path.join(root, "catalogue", "exercises", "*.json"))):
        e = json.load(open(path, encoding="utf-8"))
        if e.get("variantOf") or not e.get("name"):
            continue  # female-figure variant stubs: same exercise, only the (unused) media differ
        ex.append(e)
    fr_path = os.path.join(root, "catalogue", "i18n", "fr.json")
    fr = json.load(open(fr_path, encoding="utf-8")) if os.path.exists(fr_path) else {}
    return ex, fr


def load_fedb(root: str) -> list[dict]:
    data = json.load(open(os.path.join(root, "dist", "exercises.json"), encoding="utf-8"))
    for d in data:
        d["_tokens"] = tokens(d["name"])
        d["_core"] = core(d["name"])
        d["_muscles"] = {FEDB_MUSCLE[m] for m in d.get("primaryMuscles", []) if m in FEDB_MUSCLE}
    return data


def same_equipment(og: dict, fd: dict) -> bool:
    return og.get("equipment") in FEDB_EQUIPMENT.get(fd.get("equipment") or "", set())


def compatible(og: dict, fd: dict, og_primary: str | None) -> bool:
    if not same_equipment(og, fd):
        return False
    if og_primary is None or not fd["_muscles"]:
        return False
    if og_primary in fd["_muscles"]:
        return True
    return og_primary in SHOULDER and bool(fd["_muscles"] & SHOULDER)


def best_match(og: dict, og_primary: str | None, fedb: list[dict]) -> tuple[dict | None, float]:
    """The free-exercise-db entry naming the same movement, scored 1.0, or the closest miss for the review
    file. Among several exact cores the one with the most similar full name wins."""
    oc, ot = core(og["name"]), tokens(og["name"])
    best, score = None, 0.0
    for fd in fedb:
        if not oc or not same_equipment(og, fd):
            continue
        full = len(ot & fd["_tokens"]) / len(ot | fd["_tokens"])
        if fd["_core"] == oc:
            # Same words once equipment and filler are gone: the same movement, whatever muscle each
            # dataset files it under (a deadlift is "glutes" in one and "lower back" in the other).
            s = 1.0 + full
        elif compatible(og, fd, og_primary):
            s = len(oc & fd["_core"]) / len(oc | fd["_core"])
        else:
            continue
        if s > score:
            best, score = fd, s
    return best, min(score, 1.0) if score >= 1.0 else score


def write_image(src: str, dst: str) -> int:
    from PIL import Image  # only the build needs Pillow; the tests import this module without it
    with Image.open(src) as im:
        im = im.convert("RGB")
        im.thumbnail((IMAGE_MAX_PX, IMAGE_MAX_PX), Image.LANCZOS)
        im.save(dst, "WEBP", quality=WEBP_QUALITY, method=6)
    return os.path.getsize(dst)


OVERRIDES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "image_overrides.json")


def load_overrides() -> dict[str, str]:
    with open(OVERRIDES_PATH, encoding="utf-8") as fh:
        data = json.load(fh)
    return {k: v for k, v in data.items() if not k.startswith("_")}


def build(opengym: str, fedb_root: str, out: str, review: str | None) -> dict:
    ex, fr = load_opengym(opengym)
    fedb = load_fedb(fedb_root)
    by_id = {d["id"]: d for d in fedb}
    overrides = load_overrides()
    unknown = sorted(v for v in overrides.values() if v not in by_id)
    if unknown:
        raise SystemExit(f"image_overrides.json names free-exercise-db ids that do not exist: {unknown}")
    os.makedirs(os.path.join(out, "ExerciseImages"), exist_ok=True)
    db_path = os.path.join(out, "ExerciseCatalogue.sqlite")
    if os.path.exists(db_path):
        os.remove(db_path)
    for old in glob.glob(os.path.join(out, "ExerciseImages", "*.webp")):
        os.remove(old)
    db = sqlite3.connect(db_path)
    db.executescript("""
        PRAGMA page_size = 4096;
        CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
        CREATE TABLE exercise (
          id TEXT PRIMARY KEY,           -- openGym's permanent id, never reused or renumbered
          nameEn TEXT NOT NULL,
          nameFr TEXT,
          bodyPart TEXT,
          equipment TEXT,
          category TEXT,
          primaryMuscle TEXT,            -- a LiftMuscle token, or NULL when NOOP has no such muscle
          secondaryMuscles TEXT NOT NULL, -- comma-separated LiftMuscle tokens, canonical order
          hold INTEGER NOT NULL,         -- 1: a timed hold (plank), logged as seconds
          trackDistance INTEGER NOT NULL, -- 1: done over a distance (carry, sled)
          descriptionEn TEXT,
          descriptionFr TEXT,
          instructionsEn TEXT NOT NULL,  -- JSON array of steps
          instructionsFr TEXT,           -- JSON array of steps, or NULL
          image TEXT,                    -- file name under ExerciseImages/, or NULL
          textSource TEXT NOT NULL,      -- exercisedb (MIT) or opengym (MIT grant), for attribution
          searchKey TEXT NOT NULL        -- folded English + French names and equipment
        ) WITHOUT ROWID;
        CREATE INDEX idx_exercise_primary ON exercise(primaryMuscle);
        CREATE INDEX idx_exercise_equipment ON exercise(equipment);
    """)
    rows, matches, image_bytes = [], [], 0
    used_images: dict[str, str] = {}
    for e in ex:
        prim = muscles([e.get("target")])
        primary = prim[0] if prim else ("neck" if e.get("bodyPart") == "neck" else None)
        secondary = [m for m in muscles(e.get("secondaryMuscles")) if m != primary]
        f = fr.get(e["id"], {})
        name_fr = f.get("name")
        image = None
        if e["id"] in overrides:
            cand, score = by_id[overrides[e["id"]]], 1.0
        else:
            cand, score = best_match(e, primary, fedb)
        if cand is not None:
            matches.append((e["id"], e["name"], cand["id"], cand["name"], round(score, 3),
                            "yes" if score >= MATCH_THRESHOLD else "no"))
        if cand is not None and score >= MATCH_THRESHOLD and cand.get("images"):
            src = os.path.join(fedb_root, "exercises", cand["images"][0])
            if os.path.exists(src):
                image = f"{e['id']}.webp"
                if cand["id"] in used_images:
                    # Same picture for two catalogue entries: link the file instead of re-encoding.
                    image = used_images[cand["id"]]
                else:
                    image_bytes += write_image(src, os.path.join(out, "ExerciseImages", image))
                    used_images[cand["id"]] = image
        search = " ".join(filter(None, [fold(e["name"]), fold(name_fr or ""), fold(e.get("equipment") or "")]))
        rows.append((
            e["id"], e["name"], name_fr, e.get("bodyPart"), e.get("equipment"), e.get("category"),
            primary, ",".join(secondary), 1 if e.get("hold") else 0, 1 if e.get("track") == "distance" else 0,
            e.get("description"), f.get("description"),
            json.dumps(e.get("instructions") or [], ensure_ascii=False),
            json.dumps(f["instructions"], ensure_ascii=False) if f.get("instructions") else None,
            image, e.get("textSource") or "opengym", search,
        ))
    db.executemany("INSERT INTO exercise VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("INSERT INTO meta VALUES (?,?)", [
        ("schemaVersion", str(SCHEMA_VERSION)), ("exercises", str(len(rows))),
        ("images", str(len(used_images))),
    ])
    db.commit()
    db.execute("VACUUM")
    db.close()
    if review:
        with open(review, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["openGymId", "openGymName", "fedbId", "fedbName", "score", "used"])
            # Accepted matches plus the near misses worth a look; the long tail of weak guesses is noise.
            w.writerows(sorted((m for m in matches if m[4] >= 0.5), key=lambda m: (-m[4], m[0])))
    return {"exercises": len(rows), "withImage": sum(1 for r in rows if r[14]), "distinctImages": len(used_images),
            "imageBytes": image_bytes, "dbBytes": os.path.getsize(db_path), "withFrench": sum(1 for r in rows if r[2])}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--opengym", required=True)
    ap.add_argument("--fedb", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--review")
    a = ap.parse_args(argv)
    stats = build(a.opengym, a.fedb, a.out, a.review)
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
