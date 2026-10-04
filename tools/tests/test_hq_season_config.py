import json
import math
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class HQSeasonConfigTests(unittest.TestCase):
    def load(self, name):
        return json.loads((ROOT / "Resources" / "Seasons" / f"{name}.json").read_text())

    def test_image_seasons_use_approved_smaller_hq_size_ranges(self):
        winter = self.load("winter")
        spring = self.load("spring")
        autumn = self.load("autumn")

        self.assertEqual((winter["sizeMin"], winter["sizeMax"]), (15, 48))
        self.assertEqual(
            (winter["heroSpecies"]["sizeMin"], winter["heroSpecies"]["sizeMax"]),
            (48, 78),
        )
        self.assertEqual((spring["sizeMin"], spring["sizeMax"]), (20, 82))
        self.assertEqual(
            (spring["heroSpecies"]["sizeMin"], spring["heroSpecies"]["sizeMax"]),
            (54, 85),
        )
        self.assertEqual((autumn["sizeMin"], autumn["sizeMax"]), (28, 88))
        samara = next(species for species in autumn["species"] if species["spriteSet"] == "samara")
        self.assertEqual((samara["sizeMin"], samara["sizeMax"]), (22, 46))

    def test_hq_sizing_does_not_raise_particle_counts(self):
        self.assertEqual(self.load("winter")["count"], 460)
        self.assertEqual(self.load("spring")["count"], 240)
        self.assertEqual(self.load("autumn")["count"], 240)

    def test_stars_have_guaranteed_visible_translation(self):
        stars = self.load("stars")

        def minimum_absolute_value(low, high):
            return 0 if low <= 0 <= high else min(abs(low), abs(high))

        minimum_world_speed = math.hypot(
            minimum_absolute_value(stars["vxMin"], stars["vxMax"]),
            minimum_absolute_value(stars["vyMin"], stars["vyMax"]),
        )
        minimum_projected_speed = minimum_world_speed * stars["depthMin"]
        self.assertGreaterEqual(
            minimum_projected_speed,
            4.0,
            "every star must translate visibly; twinkling alone leaves fixed OLED pixels",
        )


if __name__ == "__main__":
    unittest.main()
