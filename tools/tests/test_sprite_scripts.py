import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
PROCESS_SCRIPT = REPOSITORY / "tools/process-sprites.sh"
PACK_SCRIPT = REPOSITORY / "tools/pack-sprites.sh"


def make_sprite(path: Path, color: str, *, canvas="100x80", shape="rectangle 20,20 79,59"):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "magick", "-size", canvas, "xc:none", "-fill", color,
            "-draw", shape, "-define", "png:color-type=6", f"PNG32:{path}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )


class ProcessSpritesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def run_process(self, season="petals"):
        return subprocess.run(
            ["bash", str(PROCESS_SCRIPT), season],
            env={"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                 "SEASONS_REPOSITORY_ROOT": str(self.root)},
            capture_output=True,
            text=True,
        )

    def test_preserves_numeric_identity_through_ten(self):
        colors = {1: "#ff0000", 2: "#0000ff", 10: "#00ff00"}
        for index in range(1, 11):
            make_sprite(
                self.root / "tools/raw/petals" / f"{index}.png",
                colors.get(index, "#808080"),
            )
        result = self.run_process()
        self.assertEqual(result.returncode, 0, result.stderr)
        output_names = {path.name for path in (self.root / "Resources/sprites/petals").iterdir()}
        self.assertEqual(output_names, {f"{index}.png" for index in range(1, 11)})
        for index, expected in ((2, "srgba(0,0,255,1)"), (10, "srgba(0,255,0,1)")):
            pixel = subprocess.run(
                ["magick", str(self.root / f"Resources/sprites/petals/{index}.png"),
                 "-format", "%[pixel:p{512,512}]", "info:"],
                check=True, capture_output=True, text=True,
            ).stdout.lower()
            self.assertIn(expected, pixel)

    def test_rejects_gaps_without_changing_runtime(self):
        make_sprite(self.root / "tools/raw/petals/1.png", "red")
        make_sprite(self.root / "tools/raw/petals/3.png", "blue")
        existing = self.root / "Resources/sprites/petals/keep.txt"
        existing.parent.mkdir(parents=True)
        existing.write_text("unchanged")
        result = self.run_process()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contiguous", result.stderr)
        self.assertEqual(existing.read_text(), "unchanged")

    def test_rejects_non_numeric_or_extra_inputs(self):
        make_sprite(self.root / "tools/raw/petals/1.png", "red")
        make_sprite(self.root / "tools/raw/petals/bonus.png", "blue")
        result = self.run_process()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric", result.stderr)

    def test_rejects_hidden_extra_input(self):
        make_sprite(self.root / "tools/raw/petals/1.png", "red")
        (self.root / "tools/raw/petals/.unexpected").write_text("not an asset")
        result = self.run_process()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("numeric", result.stderr)

    def test_rejects_empty_alpha_without_replacing_runtime(self):
        make_sprite(self.root / "tools/raw/petals/1.png", "none")
        existing = self.root / "Resources/sprites/petals/keep.txt"
        existing.parent.mkdir(parents=True)
        existing.write_text("unchanged")
        result = self.run_process()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("visible alpha", result.stderr)
        self.assertEqual(existing.read_text(), "unchanged")

    def test_rebuild_removes_stale_outputs_and_normalizes_geometry(self):
        make_sprite(self.root / "tools/raw/petals/1.png", "rgba(255,64,128,0.5)")
        stale_dir = self.root / "Resources/sprites/petals"
        stale_dir.mkdir(parents=True)
        make_sprite(stale_dir / "2.png", "blue")
        (stale_dir / "stale.txt").write_text("stale")

        result = self.run_process()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({path.name for path in stale_dir.iterdir()}, {"1.png"})
        identify = subprocess.run(
            ["magick", "identify", "-format", "%wx%h|%[channels]|%@",
             str(stale_dir / "1.png")],
            check=True, capture_output=True, text=True,
        ).stdout
        dimensions, channels, geometry = identify.split("|")
        self.assertEqual(dimensions, "1024x1024")
        self.assertIn("srgba", channels.lower())
        match = re.fullmatch(r"(\d+)x(\d+)\+(\d+)\+(\d+)", geometry)
        self.assertIsNotNone(match, geometry)
        width, height, offset_x, offset_y = map(int, match.groups())
        self.assertEqual(max(width, height), 880)
        self.assertLessEqual(abs(offset_x - (1024 - width) // 2), 1)
        self.assertLessEqual(abs(offset_y - (1024 - height) // 2), 1)
        center_pixel = subprocess.run(
            ["magick", str(stale_dir / "1.png"), "-format",
             "%[pixel:p{512,512}]", "info:"],
            check=True, capture_output=True, text=True,
        ).stdout.lower()
        self.assertIn("srgba(255,64,128,0.5", center_pixel)


class PackSpritesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "Resources/seasons").mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def run_pack(self):
        return subprocess.run(
            ["bash", str(PACK_SCRIPT)],
            env={"PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                 "SEASONS_REPOSITORY_ROOT": str(self.root)},
            capture_output=True,
            text=True,
        )

    def test_delegates_all_nested_json_references_to_validator(self):
        document = {
            "glyphType": "image", "spriteSet": "petals", "spriteCount": 1,
            "species": [{"spriteSet": "maple", "spriteCount": 1}],
            "heroSpecies": {"spriteSet": "blossom", "spriteCount": 1},
        }
        (self.root / "Resources/seasons/spring.json").write_text(json.dumps(document))
        for sprite_set, color in (("petals", "#ff4080"), ("maple", "#ff8000"),
                                  ("blossom", "#fff0f8")):
            make_sprite(
                self.root / f"Resources/sprites/{sprite_set}/1.png", color,
                canvas="1024x1024", shape="circle 512,512 512,220",
            )
        result = self.run_pack()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 sprites across 3 referenced sets", result.stdout)


if __name__ == "__main__":
    unittest.main()
