#!/bin/bash
# Bouwt "Negatief Converter.app" in mac/build/.
set -euo pipefail
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode ontbreekt. Installeer Xcode uit de App Store, open het één keer en voer dan uit:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen ontbreekt. Installeer het met:  brew install xcodegen"
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project NegConverter.xcodeproj -scheme NegConverter -configuration Release \
  -derivedDataPath build/DerivedData -quiet build

APP="build/DerivedData/Build/Products/Release/Negatief Converter.app"
rm -rf "build/Negatief Converter.app"
cp -R "$APP" build/
echo
echo "Klaar: mac/build/Negatief Converter.app"
echo "Sleep hem naar je Programma's-map, of start hem met:  open \"mac/build/Negatief Converter.app\""
