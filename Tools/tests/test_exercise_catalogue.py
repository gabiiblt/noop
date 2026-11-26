"""The exercise catalogue builder (Tools/exercise_catalogue) and the catalogue it committed.

Pure stdlib: the matching rules are tested on synthetic entries, and the committed SQLite file is
checked against the app's own muscle vocabulary so a token the app cannot decode never ships."""
import json
import os
import re
import sqlite3
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "Tools", "exercise_catalogue"))
import build_catalogue as b  # noqa: E402

CATALOGUE = os.path.join(ROOT, "StrandiOS", "Resources", "ExerciseCatalogue")
LIFT_MUSCLE = os.path.join(ROOT, "Packages", "WhoopStore", "Sources", "WhoopStore", "LiftMuscle.swift")


def fedb(name, equipment, muscles, fid=None):
    d = {"id": fid or name.replace(" ", "_"), "name": name, "equipment": equipment,
         "primaryMuscles": muscles, "images": ["x/0.jpg"]}
    d["_tokens"] = b.tokens(name)
    d["_core"] = b.core(name)
    d["_muscles"] = {b.FEDB_MUSCLE[m] for m in muscles if m in b.FEDB_MUSCLE}
    return d


class Tokens(unittest.TestCase):
    def test_plurals_and_synonyms_fold_together(self):
        self.assertEqual(b.tokens("Pullups"), b.tokens("pull-up"))
        self.assertEqual(b.tokens("Lateral Raises"), b.tokens("lateral raise"))
        self.assertIn("press", b.tokens("Bench Press"))  # "press" keeps its s

    def test_core_drops_equipment_and_filler_but_keeps_modifiers(self):
        self.assertEqual(b.core("Barbell Incline Bench Press - Medium Grip"), b.core("barbell incline bench press"))
        self.assertEqual(b.core("Good Morning"), b.core("barbell good morning"))
        self.assertNotEqual(b.core("Cable Seated Lateral Raise"), b.core("cable seated rear lateral raise"))

    def test_fold_removes_accents_for_search(self):
        self.assertEqual(b.fold("Développé Incliné"), "developpe incline")


class Muscles(unittest.TestCase):
    def test_maps_to_noop_tokens_in_canonical_order_and_drops_unknowns(self):
        self.assertEqual(b.muscles(["triceps", "pectorals", "hip flexors", "shoulders"]),
                         ["chest", "frontDelts", "triceps"])


class Matching(unittest.TestCase):
    def test_exact_core_wins_even_when_datasets_disagree_on_the_muscle(self):
        og = {"name": "barbell deadlift", "equipment": "barbell"}
        cand, score = b.best_match(og, "glutes", [fedb("Barbell Deadlift", "barbell", ["lower back"])])
        self.assertEqual((cand["name"], score), ("Barbell Deadlift", 1.0))

    def test_a_modifier_on_one_side_only_is_never_accepted(self):
        og = {"name": "dumbbell one arm hammer preacher curl", "equipment": "dumbbell"}
        _, score = b.best_match(og, "biceps", [fedb("One Arm Dumbbell Preacher Curl", "dumbbell", ["biceps"])])
        self.assertLess(score, b.MATCH_THRESHOLD)

    def test_equipment_must_agree(self):
        og = {"name": "cable curl", "equipment": "cable"}
        cand, _ = b.best_match(og, "biceps", [fedb("Barbell Curl", "barbell", ["biceps"])])
        self.assertIsNone(cand)

    def test_overrides_are_well_formed(self):
        o = b.load_overrides()
        self.assertGreater(len(o), 0)
        for k, v in o.items():
            self.assertRegex(k, r"^\d{4,5}$")
            self.assertRegex(v, r"^[A-Za-z0-9_\-()]+$")


@unittest.skipUnless(os.path.exists(os.path.join(CATALOGUE, "ExerciseCatalogue.sqlite")), "catalogue not built")
class CommittedCatalogue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = sqlite3.connect(os.path.join(CATALOGUE, "ExerciseCatalogue.sqlite"))
        src = open(LIFT_MUSCLE, encoding="utf-8").read()
        body = src[src.index("enum LiftMuscle"):src.index("enum Region")]
        cls.tokens = set(re.findall(r"^\s*case (\w+)\s*$", body, re.M))

    @classmethod
    def tearDownClass(cls):
        cls.db.close()

    def test_schema_version_and_size(self):
        meta = dict(self.db.execute("SELECT k, v FROM meta"))
        self.assertEqual(meta["schemaVersion"], str(b.SCHEMA_VERSION))
        n = self.db.execute("SELECT COUNT(*) FROM exercise").fetchone()[0]
        self.assertEqual(str(n), meta["exercises"])
        self.assertGreater(n, 5000)

    def test_every_muscle_token_is_one_the_app_decodes(self):
        self.assertIn("frontDelts", self.tokens)
        for primary, secondary in self.db.execute("SELECT primaryMuscle, secondaryMuscles FROM exercise"):
            for t in ([primary] if primary else []) + [s for s in secondary.split(",") if s]:
                self.assertIn(t, self.tokens)

    def test_every_image_exists_and_ids_are_unique(self):
        for (image,) in self.db.execute("SELECT image FROM exercise WHERE image IS NOT NULL"):
            self.assertTrue(os.path.exists(os.path.join(CATALOGUE, "ExerciseImages", image)), image)
        ids = [r[0] for r in self.db.execute("SELECT id FROM exercise")]
        self.assertEqual(len(ids), len(set(ids)))

    def test_instructions_are_json_arrays_and_french_is_present(self):
        for en, fr in self.db.execute("SELECT instructionsEn, instructionsFr FROM exercise LIMIT 500"):
            self.assertIsInstance(json.loads(en), list)
            if fr is not None:
                self.assertIsInstance(json.loads(fr), list)
        row = self.db.execute("SELECT nameFr, image FROM exercise WHERE id='0314'").fetchone()
        self.assertEqual(row, ("développé couché incliné aux haltères", "0314.webp"))

    def test_search_key_matches_without_accents(self):
        hit = self.db.execute("SELECT id FROM exercise WHERE searchKey LIKE '%developpe couche incline aux halteres%'").fetchall()
        self.assertIn(("0314",), hit)


if __name__ == "__main__":
    unittest.main()
