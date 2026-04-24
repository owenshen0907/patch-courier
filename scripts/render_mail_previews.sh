#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/MailPreviewDerivedData}"

if [[ $# -gt 0 ]]; then
  case "$1" in
    /*) OUTPUT_DIR="$1" ;;
    *) OUTPUT_DIR="$ROOT_DIR/$1" ;;
  esac
else
  OUTPUT_DIR="$ROOT_DIR/.preview/mailroom-emails"
fi

xcodebuild \
  -project "$ROOT_DIR/PatchCourier.xcodeproj" \
  -scheme MailroomDaemon \
  -configuration Debug \
  -sdk macosx \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

"$DERIVED_DATA_PATH/Build/Products/Debug/mailroomd" \
  --render-mail-fixtures \
  --output-dir "$OUTPUT_DIR"

echo
echo "Rendered Mailroom email fixtures to:"
echo "  $OUTPUT_DIR"
echo "Open:"
echo "  $OUTPUT_DIR/index.html"
