# Dual Scan: a film-scanning workflow for an old Minolta, built with Claude Code

*A workflow guide, a negative converter and a Mac app that turns a whole roll of scans into positives in one go.*

**Role:** [your role, e.g. design and direction] · **Built with:** Claude Code in the terminal · **Time:** March and November 2026 · **Stack:** HTML/JavaScript, Swift/SwiftUI, Node, GitHub Actions, Vercel

---

## The problem

I scan my 35mm film on a Minolta DiMAGE Scan Dual IV, a scanner from 2005. Minolta stopped making scanners long ago, so it runs through VueScan on a MacBook (M1).

Scanning is the easy part. What makes it hard:

- **Settings are easy to get wrong.** Bit depth, exposure lock, warm-up time, grain reduction: get one wrong and you only find out after scanning the whole roll.
- **Negatives need converting.** A colour negative is orange and inverted. The usual tools are paid plugins that depend on Lightroom.
- **A roll should look like one roll.** If each frame is corrected on its own, colours jump from frame to frame.

[One or two sentences of your own: why this mattered to you, what you shoot.]

## What I built

### 1. A workflow guide

A web page, in Dutch, with every step of a scan session: connecting and warming up the scanner, the settings for each VueScan tab, locking exposure on the film base, loading the film holder, and the export. It has separate tracks for colour and black and white, and an installation guide for the tools.

### 2. A negative converter in the browser

Drop in the raw DNG scans and they come out as positives. The converter measures the orange film base and balances the whole roll as one, or each frame on its own. It exports 16-bit TIFF for Lightroom or Capture One. Everything runs locally in the browser, so nothing gets uploaded.

### 3. Editable projects for Compositor

For frames I want to fine-tune, every scan can become a Compositor project. The project has its adjustment layers already set to the scan, including a project built on photographer Alex Burke's manual inversion method, layer by layer.

### 4. Roll Converter, a Mac app

The end point: a native Mac app. Point it at a roll's folder and every scan in it becomes a positive. While it works, the roll shows as a grid of frames that turn from negative to positive one by one.

- One colour balance for the whole roll, so the frames match
- The folder name sets the film: "HP5" or "Tri-X" means black and white, "Velvia" a slide, "Portra 400" colour
- Output as 16-bit TIFF, JPEG and, optionally, a Compositor project
- Updates itself: every change is built, tested and released automatically

[Screenshot: the start screen]
[Screenshot: a roll being converted]

## How it was made

I made all of it with Claude Code in the terminal. I described what I wanted and how it should feel, and Claude Code wrote the code, ran it and fixed what didn't work.

- **It started with a page.** The first version, in March 2026, was just the workflow guide, built in a single day.
- **It grew from real use.** In November I wanted to stop paying for conversion, so the browser converter came first. Next came the Compositor projects, then an automatic inbox for new scans, and finally the Mac app, which made the inbox unnecessary.
- **One engine, three tools.** The conversion maths lives in one place, so the browser, the command-line tools and the Mac app give the same result.
- **The cloud builds the app.** I never needed Xcode: every change is built on GitHub's Macs, which convert a test roll, check the files, take screenshots and publish a new version the app installs itself.
- **About 40 small steps,** each a change I could see and judge, from "the start screen as a centred file catcher" to "no dashed line round the drop area".

[Your reflection: what surprised you, what you decided yourself vs. what Claude Code did, what you'd do differently.]

## Result

A complete workflow from film holder to finished file, made for my own scanner and my own way of working. A whole roll now goes from raw scans to matching positives with one drag.

[Links: the workflow page · Roll Converter download · the code on GitHub]
