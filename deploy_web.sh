#!/usr/bin/env bash
# Rebuilds the Godot Web export and force-pushes it to the gh-pages branch.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
BUILD_DIR="$PROJECT_DIR/web"

if [ ! -x "$GODOT_BIN" ]; then
  echo "Godot not found at $GODOT_BIN (set GODOT_BIN to override)" >&2
  exit 1
fi

REMOTE_URL="$(git -C "$PROJECT_DIR" remote get-url origin)"
GIT_NAME="$(git -C "$PROJECT_DIR" config user.name)"
GIT_EMAIL="$(git -C "$PROJECT_DIR" config user.email)"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> Exporting Web build with Godot..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
"$GODOT_BIN" --headless --path "$PROJECT_DIR" --export-release "Web" "$BUILD_DIR/index.html"

echo "==> Publishing to gh-pages..."
cp -r "$BUILD_DIR"/* "$STAGE_DIR"/
git -C "$STAGE_DIR" init -q
git -C "$STAGE_DIR" checkout -b gh-pages -q
git -C "$STAGE_DIR" add -A
git -C "$STAGE_DIR" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
  commit -q -m "Deploy web build: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git -C "$STAGE_DIR" remote add origin "$REMOTE_URL"
git -C "$STAGE_DIR" push -f origin gh-pages

echo "==> Done. GitHub Pages will update within a minute or two."
