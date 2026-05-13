#!/usr/bin/env bash
# Bundle lives at $REPO/tests/validation_tests/ → go up 2 to reach repo root.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

echo "== regenerate secure-boot generated artifacts =="
echo "repo: $REPO"

# This uses the existing key and current kernel.bin.
# It rebuilds:
#   metadata/manifest.bin
#   metadata/signature.bin
#   flash_image/flash_image.bin
#   flash_image/flash_image.hex
(
  cd "$REPO/tools"
  python3 manifest_generators.py
  python3 sign_firmware.py
)
python3 "$REPO/tools/flash_image_to_hex.py" \
  --input "$REPO/flash_image/flash_image.bin" \
  --output "$REPO/flash_image/flash_image.hex"

if [ -f "$REPO/.env" ]; then
  # shellcheck disable=SC1090
  source "$REPO/.env"
fi
if [ -n "${CHIPYARD_HOME:-}" ]; then
  mkdir -p "$CHIPYARD_HOME/sims/verilator/flash_image"
  cp -p "$REPO/flash_image/flash_image.hex" "$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex"
  echo "staged flash_image.hex into $CHIPYARD_HOME/sims/verilator/flash_image/"
else
  echo "CHIPYARD_HOME not set; skipped Chipyard staging copy"
fi

echo
echo "running artifact check after regeneration"
python3 "$REPO/tests/validation_tests/tools/image_tool.py" --repo "$REPO" check-artifacts
