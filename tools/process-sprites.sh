#!/usr/bin/env bash
# tools/process-sprites.sh <sprite-set>
# Normalize an exact, contiguous 1..N input set into numerically identical runtime
# sprites. Build in a sibling staging directory so a failed conversion never changes
# the current runtime set and stale outputs cannot survive a successful rebuild.
set -euo pipefail

sprite_set="${1:?usage: process-sprites.sh <sprite-set>}"
if [[ ! "$sprite_set" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "FAIL: sprite set must be a simple name" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="${SEASONS_REPOSITORY_ROOT:-$(cd "$script_dir/.." && pwd)}"
source_dir="$repository_root/tools/raw/$sprite_set"
output_parent="$repository_root/Resources/sprites"
output_dir="$output_parent/$sprite_set"

if [[ ! -d "$source_dir" ]]; then
  echo "FAIL: source directory does not exist: $source_dir" >&2
  exit 1
fi
if ! command -v magick >/dev/null 2>&1; then
  echo "FAIL: ImageMagick 'magick' is required" >&2
  exit 1
fi

shopt -s nullglob dotglob
input_paths=("$source_dir"/*)
if [[ ${#input_paths[@]} -eq 0 ]]; then
  echo "FAIL: $sprite_set has no inputs" >&2
  exit 1
fi

input_names=()
for input_path in "${input_paths[@]}"; do
  input_name="$(basename "$input_path")"
  if [[ ! -f "$input_path" || ! "$input_name" =~ ^[1-9][0-9]*\.png$ ]]; then
    echo "FAIL: every input must be a numeric PNG named 1.png..N.png; got $input_name" >&2
    exit 1
  fi
  input_names+=("$input_name")
done

sorted_names=()
while IFS= read -r input_name; do
  sorted_names+=("$input_name")
done < <(printf '%s\n' "${input_names[@]}" | sort -t. -k1,1n)

expected_index=1
for input_name in "${sorted_names[@]}"; do
  if [[ "$input_name" != "$expected_index.png" ]]; then
    echo "FAIL: inputs must be contiguous 1.png..N.png; expected $expected_index.png, got $input_name" >&2
    exit 1
  fi
  expected_index=$((expected_index + 1))
done

mkdir -p "$output_parent"
stage_dir="$(mktemp -d "$output_parent/.${sprite_set}.stage.XXXXXX")"
backup_holder=""
cleanup() {
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf -- "$stage_dir"
  fi
  if [[ -n "$backup_holder" && -d "$backup_holder" ]]; then
    if [[ -d "$backup_holder/previous" && ! -e "$output_dir" ]]; then
      mv "$backup_holder/previous" "$output_dir"
    fi
    rm -rf -- "$backup_holder"
  fi
}
trap cleanup EXIT

for input_name in "${sorted_names[@]}"; do
  alpha_maximum="$(magick identify -format '%[fx:maxima.a]' "$source_dir/$input_name")"
  if [[ "$alpha_maximum" == "0" || "$alpha_maximum" == "0.0" ]]; then
    echo "FAIL: $input_name must contain visible alpha" >&2
    exit 1
  fi
  magick "$source_dir/$input_name" -trim +repage \
    -resize 880x880 -background none -gravity center -extent 1024x1024 \
    -define png:color-type=6 "PNG32:$stage_dir/$input_name"
  output_description="$(magick identify -format '%wx%h|%[channels]' "$stage_dir/$input_name")"
  if [[ "$output_description" != 1024x1024\|*srgba* ]]; then
    echo "FAIL: $input_name did not produce 1024x1024 straight-alpha sRGBA output: $output_description" >&2
    exit 1
  fi
done

backup_holder="$(mktemp -d "$output_parent/.${sprite_set}.previous.XXXXXX")"
if [[ -e "$output_dir" ]]; then
  mv "$output_dir" "$backup_holder/previous"
fi
mv "$stage_dir" "$output_dir"
stage_dir=""
rm -rf -- "$backup_holder"
backup_holder=""

echo "$sprite_set: wrote $((${#sorted_names[@]})) sprites to Resources/sprites/$sprite_set"
