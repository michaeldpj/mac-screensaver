import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


MODULE_PATH = Path(__file__).parents[1] / "validate_sprites.py"
SPEC = importlib.util.spec_from_file_location("validate_sprites", MODULE_PATH)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


def write_rgba_png(path: Path, *, size=1024, box=(256, 256, 768, 768),
                   rgba=(240, 90, 30, 255), antialias=True):
    width = height = size
    left, top, right, bottom = box
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            alpha = 0
            if left <= x < right and top <= y < bottom:
                alpha = rgba[3]
                if antialias and (x in (left, right - 1) or y in (top, bottom - 1)):
                    alpha = min(alpha, 128)
            row.extend((rgba[0], rgba[1], rgba[2], alpha))
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)

    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class SpriteReferenceTests(unittest.TestCase):
    def test_discovers_top_level_species_and_hero_references(self):
        document = {
            "glyphType": "image", "spriteSet": "petals", "spriteCount": 4,
            "species": [{"spriteSet": "maple", "spriteCount": 2}],
            "heroSpecies": {"spriteSet": "blossom", "spriteCount": 1},
        }
        self.assertEqual(
            validator.discover_references(document, "spring.json"),
            {"petals": 4, "maple": 2, "blossom": 1},
        )

    def test_rejects_missing_count_and_conflicting_counts(self):
        with self.assertRaisesRegex(validator.ValidationError, "spriteCount"):
            validator.discover_references({"spriteSet": "snow"}, "winter.json")
        with self.assertRaisesRegex(validator.ValidationError, "conflicting"):
            validator.discover_references(
                {"spriteSet": "snow", "spriteCount": 2,
                 "heroSpecies": {"spriteSet": "snow", "spriteCount": 3}},
                "winter.json",
            )

    def test_rejects_sprite_set_path_traversal(self):
        with self.assertRaisesRegex(validator.ValidationError, "simple name"):
            validator.discover_references(
                {"spriteSet": "../outside", "spriteCount": 1}, "autumn.json"
            )

    def test_ignores_procedural_configs_with_empty_sprite_set(self):
        for empty_value in (None, ""):
            with self.subTest(empty_value=empty_value):
                self.assertEqual(
                    validator.discover_references(
                        {"glyphType": "procedural", "spriteSet": empty_value, "spriteCount": 0},
                        "rain.json",
                    ),
                    {},
                )


class SpriteAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.seasons = self.root / "seasons"
        self.sprites = self.root / "sprites"
        self.seasons.mkdir()
        self.sprites.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def write_season(self, payload):
        (self.seasons / "test.json").write_text(json.dumps(payload))

    def test_accepts_complete_centered_rgba_set(self):
        self.write_season({"glyphType": "image", "spriteSet": "petals", "spriteCount": 2})
        write_rgba_png(self.sprites / "petals" / "1.png")
        write_rgba_png(self.sprites / "petals" / "2.png", box=(300, 250, 724, 774))
        self.assertEqual(validator.validate_repository(self.seasons, self.sprites), [])

    def test_enforces_exact_contiguous_file_names(self):
        self.write_season({"glyphType": "image", "spriteSet": "snow", "spriteCount": 2})
        write_rgba_png(self.sprites / "snow" / "1.png")
        write_rgba_png(self.sprites / "snow" / "3.png")
        errors = validator.validate_repository(self.seasons, self.sprites)
        joined = "\n".join(errors)
        self.assertIn("missing: 2.png", joined)
        self.assertIn("unexpected: 3.png", joined)

    def test_rejects_non_png_extras_in_referenced_directory(self):
        self.write_season({"glyphType": "image", "spriteSet": "snow", "spriteCount": 1})
        write_rgba_png(self.sprites / "snow" / "1.png")
        (self.sprites / "snow" / "notes.txt").write_text("unexpected")
        errors = validator.validate_repository(self.seasons, self.sprites)
        self.assertTrue(any("unexpected: notes.txt" in error for error in errors), errors)

    def test_rejects_wrong_dimensions_and_color_type(self):
        self.write_season({"glyphType": "image", "spriteSet": "bad", "spriteCount": 1})
        write_rgba_png(self.sprites / "bad" / "1.png", size=64, box=(16, 16, 48, 48))
        errors = validator.validate_repository(self.seasons, self.sprites)
        self.assertTrue(any("1024x1024" in error for error in errors))

    def test_rejects_empty_alpha_opaque_corners_and_off_center_content(self):
        cases = [
            ("empty", (256, 256, 768, 768), (255, 255, 255, 0), "visible alpha"),
            ("corners", (0, 0, 1024, 1024), (255, 255, 255, 255), "transparent corner"),
            ("offcenter", (650, 256, 900, 768), (255, 255, 255, 255), "centered"),
        ]
        for name, box, rgba, expected in cases:
            with self.subTest(name=name):
                self.write_season({"glyphType": "image", "spriteSet": name, "spriteCount": 1})
                write_rgba_png(self.sprites / name / "1.png", box=box, rgba=rgba)
                errors = validator.validate_repository(self.seasons, self.sprites)
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_rejects_unpadded_or_unantialiased_edges_for_mip_safety(self):
        self.write_season({"glyphType": "image", "spriteSet": "hard", "spriteCount": 1})
        write_rgba_png(
            self.sprites / "hard" / "1.png",
            box=(8, 256, 768, 768),
            antialias=False,
        )
        errors = validator.validate_repository(self.seasons, self.sprites)
        joined = "\n".join(errors)
        self.assertIn("edge padding", joined)
        self.assertIn("antialiased alpha edge", joined)


if __name__ == "__main__":
    unittest.main()
