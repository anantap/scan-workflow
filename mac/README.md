# Negatief Converter voor de Mac

Dezelfde converter als op de website, als eigen Mac-app:

- **⌘O** opent losse scans of een hele map (DNG, TIFF, JPEG, PNG).
- Exports gaan direct in een exportmap. Die kies je één keer en de app onthoudt hem.
  Wijzigen kan via **Archief → Exportmap kiezen…** (⇧⌘E).
- Werkt zonder internet.

De app laadt `converter.html`, `converter-core.js`, `vendor/` en `fonts/` uit de
hoofdmap van deze repo. Een verbetering aan de converter komt dus vanzelf in de
app bij de volgende build.

## Bouwen

Eenmalig:

1. Installeer **Xcode** uit de App Store, open het één keer en accepteer de licentie.
2. Installeer XcodeGen: `brew install xcodegen`

Daarna, in de map van deze repo:

```
./mac/build.sh
```

De app staat dan in `mac/build/Negatief Converter.app`. Sleep hem naar Programma's.

Hij is ad-hoc ondertekend: hij draait op je eigen Mac zonder Apple-ontwikkelaarsaccount.
Om hem aan anderen te geven is een account ($99 per jaar) nodig voor notarisatie.

## Werken in Xcode

```
cd mac
xcodegen generate
open NegConverter.xcodeproj
```

Druk op Run (⌘R). Het Xcode-project wordt gegenereerd uit `project.yml` en staat
niet in git; pas `project.yml` aan, niet het project.

De pagina in de app is te inspecteren met Safari: Ontwikkel → [je Mac] → Negatief Converter
(zet in Safari eerst Instellingen → Geavanceerd → "Toon functies voor webontwikkelaars" aan).

## Bestanden

- `project.yml`: projectbeschrijving voor XcodeGen
- `Sources/NegConverterApp.swift`: app, venster en menu
- `Sources/WebController.swift`: laadt de pagina, opent bestanden, bewaart exports
- `Sources/AppSchemeHandler.swift`: levert de pagina en de geopende scans aan de webview
