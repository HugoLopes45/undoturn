#!/bin/sh
# Regenerates docs/guide.html from docs/GUIDE.md. Needs pandoc 3.8 or later.
set -eu
cd "$(dirname "$0")/.."

pandoc docs/GUIDE.md \
  --from gfm \
  --to html5 \
  --standalone \
  --template scripts/docs-template.html \
  --lua-filter scripts/docs-guide.lua \
  --syntax-highlighting none \
  --wrap none \
  --metadata description-meta="Install UndoTurn, record agent turns, and recover files on macOS: setup, commands, recovery choices and limits." \
  --output docs/guide.html
echo docs/guide.html
