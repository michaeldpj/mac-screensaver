#!/usr/bin/env python3
"""Validate every PNG sprite set referenced by Resources/seasons JSON.

This intentionally uses only Python's standard library so the quality gate runs in
CI and on a clean macOS installation without ImageMagick, Pillow, or a GUI session.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import sys
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
EXPECTED_SIZE = 1024
CORNER_SIZE = 8
MIN_EDGE_PADDING = 16
MAX_CENTER_OFFSET = 82  # Eight percent of the 1024px canvas.
MIP_TEST_SIZE = 32


class ValidationError(ValueError):
    pass


def discover_references(document: object, source: str) -> dict[str, int]:
    """Find paired spriteSet/spriteCount fields at any JSON nesting depth."""
    references: dict[str, int] = {}

    def visit(value: object, location: str) -> None:
        if isinstance(value, dict):
            if "spriteSet" in value:
                sprite_set = value["spriteSet"]
                count = value.get("spriteCount")
                if sprite_set in (None, "") and count == 0:
                    sprite_set = None
                elif not isinstance(sprite_set, str) or not sprite_set:
                    raise ValidationError(f"{source}:{location} has an invalid spriteSet")
                elif re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", sprite_set) is None:
                    raise ValidationError(
                        f"{source}:{location} spriteSet must be a simple name: {sprite_set!r}"
                    )
                if sprite_set is not None and (
                    not isinstance(count, int) or isinstance(count, bool) or count < 1
                ):
                    raise ValidationError(
                        f"{source}:{location}.{sprite_set} requires a positive spriteCount"
                    )
                if sprite_set is not None:
                    prior = references.get(sprite_set)
                    if prior is not None and prior != count:
                        raise ValidationError(
                            f"{source} has conflicting spriteCount values for {sprite_set}: "
                            f"{prior} and {count}"
                        )
                    references[sprite_set] = count
            for key, child in value.items():
                visit(child, f"{location}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                visit(child, f"{location}[{index}]")

    visit(document, "$")
    return references


def load_references(seasons_dir: Path) -> tuple[dict[str, int], list[str]]:
    references: dict[str, int] = {}
    errors: list[str] = []
    json_paths = sorted(seasons_dir.glob("*.json"))
    if not json_paths:
        return {}, [f"{seasons_dir}: no season JSON files found"]

    for path in json_paths:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
            found = discover_references(document, path.name)
            for sprite_set, count in found.items():
                prior = references.get(sprite_set)
                if prior is not None and prior != count:
                    raise ValidationError(
                        f"conflicting spriteCount values for {sprite_set}: {prior} and {count}"
                    )
                references[sprite_set] = count
        except (OSError, json.JSONDecodeError, ValidationError) as error:
            errors.append(f"{path}: {error}")
    return references, errors


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    distance_left = abs(estimate - left)
    distance_above = abs(estimate - above)
    distance_upper_left = abs(estimate - upper_left)
    if distance_left <= distance_above and distance_left <= distance_upper_left:
        return left
    if distance_above <= distance_upper_left:
        return above
    return upper_left


def decode_rgba_png(path: Path) -> tuple[int, int, bytearray]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValidationError("not a PNG file")

    offset = len(PNG_SIGNATURE)
    header = None
    compressed = bytearray()
    saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        start = offset + 8
        end = start + length
        if end + 4 > len(data):
            raise ValidationError("truncated PNG chunk")
        payload = data[start:end]
        expected_crc = struct.unpack_from(">I", data, end)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise ValidationError(f"invalid {kind.decode('ascii', 'replace')} CRC")
        if kind == b"IHDR":
            if len(payload) != 13:
                raise ValidationError("invalid IHDR")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            saw_end = True
            break
        offset = end + 4

    if header is None or not compressed or not saw_end:
        raise ValidationError("incomplete PNG")
    width, height, depth, color_type, compression, filtering, interlace = header
    if depth != 8 or color_type != 6:
        raise ValidationError(
            f"must be 8-bit RGBA PNG (depth 8, color type 6); got depth {depth}, "
            f"color type {color_type}"
        )
    if compression != 0 or filtering != 0 or interlace != 0:
        raise ValidationError("must use standard compression/filtering and be non-interlaced")

    try:
        raw = zlib.decompress(compressed)
    except zlib.error as error:
        raise ValidationError(f"invalid compressed pixels: {error}") from error
    stride = width * 4
    expected_length = height * (stride + 1)
    if len(raw) != expected_length:
        raise ValidationError(
            f"decoded pixel length is {len(raw)}, expected {expected_length}"
        )

    pixels = bytearray(width * height * 4)
    previous = bytearray(stride)
    raw_offset = 0
    for y in range(height):
        filter_type = raw[raw_offset]
        raw_offset += 1
        encoded = raw[raw_offset:raw_offset + stride]
        raw_offset += stride
        decoded = bytearray(stride)
        if filter_type > 4:
            raise ValidationError(f"invalid PNG filter {filter_type} on row {y}")
        for index, value in enumerate(encoded):
            left = decoded[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            else:
                predictor = _paeth(left, above, upper_left)
            decoded[index] = (value + predictor) & 0xFF
        row_start = y * stride
        pixels[row_start:row_start + stride] = decoded
        previous = decoded
    return width, height, pixels


def _alpha_plane(pixels: bytearray) -> bytearray:
    return bytearray(pixels[3::4])


def _alpha_bbox(alpha: bytearray, width: int, height: int) -> tuple[int, int, int, int] | None:
    left, top, right, bottom = width, height, -1, -1
    for y in range(height):
        row_start = y * width
        for x in range(width):
            if alpha[row_start + x]:
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
    if right < 0:
        return None
    return left, top, right + 1, bottom + 1


def _corners_are_transparent(alpha: bytearray, width: int, height: int) -> bool:
    for start_x, start_y in (
        (0, 0), (width - CORNER_SIZE, 0),
        (0, height - CORNER_SIZE), (width - CORNER_SIZE, height - CORNER_SIZE),
    ):
        for y in range(start_y, start_y + CORNER_SIZE):
            row = y * width
            if any(alpha[row + start_x:row + start_x + CORNER_SIZE]):
                return False
    return True


def _mip_survives(alpha: bytearray, width: int, height: int) -> bool:
    current = alpha
    current_width, current_height = width, height
    while current_width > MIP_TEST_SIZE and current_height > MIP_TEST_SIZE:
        next_width, next_height = current_width // 2, current_height // 2
        reduced = bytearray(next_width * next_height)
        for y in range(next_height):
            source_top = (y * 2) * current_width
            source_bottom = source_top + current_width
            target_row = y * next_width
            for x in range(next_width):
                source_x = x * 2
                total = (
                    current[source_top + source_x]
                    + current[source_top + source_x + 1]
                    + current[source_bottom + source_x]
                    + current[source_bottom + source_x + 1]
                )
                reduced[target_row + x] = (total + 2) // 4
        current = reduced
        current_width, current_height = next_width, next_height
    return any(current)


def validate_png(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        width, height, pixels = decode_rgba_png(path)
    except (OSError, ValidationError) as error:
        return [f"{path}: {error}"]

    if (width, height) != (EXPECTED_SIZE, EXPECTED_SIZE):
        return [
            f"{path}: must be {EXPECTED_SIZE}x{EXPECTED_SIZE}; got {width}x{height}"
        ]

    alpha = _alpha_plane(pixels)
    bbox = _alpha_bbox(alpha, width, height)
    if bbox is None:
        return [f"{path}: must contain nonempty visible alpha"]

    if not _corners_are_transparent(alpha, width, height):
        errors.append(f"{path}: each {CORNER_SIZE}px transparent corner must be clear")

    left, top, right, bottom = bbox
    padding = (left, top, width - right, height - bottom)
    if min(padding) < MIN_EDGE_PADDING:
        errors.append(
            f"{path}: needs at least {MIN_EDGE_PADDING}px edge padding for safe mip sampling; "
            f"got L{padding[0]} T{padding[1]} R{padding[2]} B{padding[3]}"
        )

    center_x = (left + right) / 2
    center_y = (top + bottom) / 2
    canvas_center_x = width / 2
    canvas_center_y = height / 2
    if abs(center_x - canvas_center_x) > MAX_CENTER_OFFSET or abs(center_y - canvas_center_y) > MAX_CENTER_OFFSET:
        errors.append(
            f"{path}: visible bounding box must be centered within {MAX_CENTER_OFFSET}px; "
            f"center is ({center_x:.1f}, {center_y:.1f})"
        )

    if not any(0 < value < 255 for value in alpha):
        errors.append(f"{path}: needs an antialiased alpha edge for smooth minification")
    if not _mip_survives(alpha, width, height):
        errors.append(
            f"{path}: visible alpha disappears before the {MIP_TEST_SIZE}px acceptance mip"
        )
    return errors


def validate_repository(seasons_dir: Path, sprites_dir: Path) -> list[str]:
    references, errors = load_references(seasons_dir)
    if not references and not errors:
        errors.append(f"{seasons_dir}: no referenced sprite sets found")

    for sprite_set, count in sorted(references.items()):
        directory = sprites_dir / sprite_set
        if not directory.is_dir():
            errors.append(f"{directory}: referenced sprite directory is missing")
            continue
        expected = {f"{index}.png" for index in range(1, count + 1)}
        actual = {path.name for path in directory.iterdir()}
        missing = sorted(expected - actual, key=lambda name: int(Path(name).stem))
        unexpected = sorted(actual - expected)
        details = []
        if missing:
            details.append("missing: " + ", ".join(missing))
        if unexpected:
            details.append("unexpected: " + ", ".join(unexpected))
        if details:
            errors.append(f"{directory}: " + "; ".join(details))
        for name in sorted(expected & actual, key=lambda item: int(Path(item).stem)):
            errors.extend(validate_png(directory / name))
    return errors


def main(argv: list[str] | None = None) -> int:
    repository = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seasons", type=Path, default=repository / "Resources/seasons")
    parser.add_argument("--sprites", type=Path, default=repository / "Resources/sprites")
    parser.add_argument("--json", action="store_true", help="emit machine-readable results")
    arguments = parser.parse_args(argv)

    references, reference_errors = load_references(arguments.seasons)
    errors = validate_repository(arguments.seasons, arguments.sprites)
    asset_count = sum(references.values())
    result = {
        "ok": not errors,
        "spriteSets": len(references),
        "assets": asset_count,
        "errors": errors,
    }
    if arguments.json:
        print(json.dumps(result, indent=2))
    elif errors:
        print(f"FAIL: {len(errors)} sprite validation error(s)", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
    else:
        print(f"OK: {asset_count} sprites across {len(references)} referenced sets")
    return 1 if errors or reference_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
