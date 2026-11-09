#!/bin/bash
# Builds "Roll Converter.app" (and the rollconvert tool) into mac/build/.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is missing. Install it from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen is missing. Install it with:  brew install xcodegen"; exit 1; }

xcodegen generate --quiet
for scheme in RollConverter rollconvert; do
  xcodebuild -project RollConverter.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/DerivedData -quiet build
done

PRODUCTS="build/DerivedData/Build/Products/Release"
rm -rf "build/Roll Converter.app" build/rollconvert
cp -R "$PRODUCTS/Roll Converter.app" build/
cp "$PRODUCTS/rollconvert" build/
# The tool finds the converter's scripts next to itself
cp ../vendor/pako_inflate.min.js ../vendor/utif.js ../converter-core.js ../compositor/burke-core.js Engine/engine.js build/
echo
echo "Done: mac/build/Roll Converter.app"
echo "Drag it to Applications, or start it with:  open \"mac/build/Roll Converter.app\""
