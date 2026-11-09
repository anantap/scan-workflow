# Roll Converter

A Mac app that converts a scanned roll in one go: point it at the roll's folder and every scan in it
(DNG, TIFF, JPEG or PNG) becomes a positive.

While it works, the roll shows as a grid of frames: negatives until they're converted, then
positives.

Or drop just a few scans on it (a rescan, a test frame): only those are converted, into `Positief`
next to them, with one balance for them together.

- **16-bit TIFF** with an sRGB profile, for Compositor, Photoshop, Lightroom, Affinity and the like
- **JPEG**, to view and share
- optionally a **Compositor project** with Alex Burke's layers, to fine-tune by hand
- one colour balance for the whole roll, or each frame on its own
- `(zw)` or `(positief)` in the folder name sets black and white or already-positive scans;
  so does a film stock in the name: "HP5", "Tri-X" or "Delta" is black and white, "Velvia" or "Ektachrome" a slide,
  "Portra 400" colour. The stock only picks the kind of film: the colours come from measuring the roll itself

It runs the same maths as the web converter (`converter-core.js`,
`compositor/burke-core.js`), in macOS's own JavaScriptCore: nothing else to install.

## Getting the app

**Without Xcode:** every push builds the app on GitHub and publishes it as the latest release.
Download it here:

https://github.com/anantap/scan-workflow/releases/latest/download/Roll-Converter.zip

Unzip it and drag `Roll Converter.app` to Applications. The first time, right-click it and choose
**Open**: it's signed for your own use, not by an Apple developer account.

**Updates come by themselves.** Each time it starts, the app looks for a newer release,
downloads it in the background and says so at the top of the window: **Restart** puts it in place
right away, otherwise it goes in place when you quit. *Roll Converter › Check for Updates…* looks now.
For this, keep the app in Applications (or another folder you can write to).

**With Xcode** (and `brew install xcodegen`):

```
./mac/build.sh
```

The app lands in `mac/build/Roll Converter.app`, with the command-line tool `mac/build/rollconvert`
next to it.

## Command line

```
mac/build/rollconvert "/Volumes/SSD/Scans/2026-11 Portra 400 roll 12" --compositor
mac/build/rollconvert "/Volumes/SSD/Scans/2026-11 Portra 400 roll 12/scan0007.dng"
```

Options: `--out <folder>`, `--film color|bw|positive`, `--no-roll`, `--no-tiff`, `--no-jpeg`,
`--compositor`. See `rollconvert --help`.

## Files

| | |
|---|---|
| `App/` | the window (SwiftUI), in the look of cpc2027.vercel.app (`Theme.swift`), and the updater |
| `App/Fonts/` | Geist and Geist Pixel (SIL Open Font License), from cpc2027 |
| `Icon/` | `make_icon.py` draws the app icon |
| `Core/Engine.swift` | runs the converter's scripts in JavaScriptCore |
| `Core/RollJob.swift` | finds a roll's scans and converts them: measure all, then convert each |
| `Core/ImageFiles.swift` | writes TIFF, JPEG and Compositor projects with ImageIO |
| `CLI/main.swift` | `rollconvert` |
| `Engine/engine.js` | the bridge between Swift and the converter's scripts |
| `Fixtures/` | a test negative and the checks the GitHub build runs |
| `project.yml` | the Xcode project, for XcodeGen |
