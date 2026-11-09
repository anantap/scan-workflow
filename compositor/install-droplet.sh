#!/bin/bash
# Maakt de app "Negatieven naar Compositor" in je Programma's-map (in je thuismap).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v node >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/node ] && [ ! -x /usr/local/bin/node ]; then
  echo "Node ontbreekt. Installeer het eerst met:  brew install node"
  exit 1
fi

SCRIPT="$(pwd)/neg2comp.mjs"
APP="$HOME/Applications/Negatieven naar Compositor.app"
TMPDIR_D="$(mktemp -d)"
TMP="$TMPDIR_D/droplet.applescript"

# Pad invullen: eerst ontsnappen voor AppleScript (\ en "), dan voor sed (\, & en |)
AS=$(printf '%s' "$SCRIPT" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
ESCAPED=$(printf '%s' "$AS" | sed -e 's/\\/\\\\/g' -e 's/[|&]/\\&/g')
sed "s|__SCRIPT__|$ESCAPED|" droplet.applescript > "$TMP"

mkdir -p "$HOME/Applications"
rm -rf "$APP"
osacompile -o "$APP" "$TMP"
rm -rf "$TMPDIR_D"

echo "Klaar: $APP"
echo "Sleep hem uit het Finder-venster naar je Dock."
open -R "$APP"
