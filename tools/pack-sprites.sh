#!/usr/bin/env bash
# Validate every sprite set referenced anywhere in Resources/seasons/*.json.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repository_root="${SEASONS_REPOSITORY_ROOT:-$(cd "$script_dir/.." && pwd)}"

exec python3 "$script_dir/validate_sprites.py" \
  --seasons "$repository_root/Resources/seasons" \
  --sprites "$repository_root/Resources/sprites" \
  "$@"
