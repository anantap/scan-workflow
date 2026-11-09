#!/usr/bin/env node
/*
 * burke2comp — Alex Burke's handmatige inversie van kleurnegatieven, als Compositor-project.
 * (alexburkephoto.com/blog/2019/10/16/manual-inversion-of-color-negative-film)
 *
 * Per scan een .comp met zijn lagen, al ingesteld maar allemaal bij te stellen:
 *   Scan                 de scan zoals hij is (oranje-bruin negatief), 16-bit
 *   Inversie             Curven: zwart en wit omgedraaid
 *   Filmbasis            de kleur van de filmrand, Aftrekken (Subtract) op 80%
 *   Witpunt & kleur      Curven: per kanaal het witpunt net voor het clippen, de kanalen
 *                        in de middentonen gelijkgetrokken (blauw flink omlaag, groen wat),
 *                        RGB omlaag zodat het niet te licht is
 *   Hue/Saturation       neutraal: cyaan naar blauw als de lucht te cyaan is
 *   Contrast             een zachte S-curve
 *
 * Werkt in de officiële Compositor (projectversie 12).
 *
 * Gebruik:  node compositor/burke2comp.mjs [opties] <scans of mappen...>
 */
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { NC, fail, expandInputs, encodePNG16, uuid, adjustmentLayer, imageLayer, freePath, writeProject, decode,
         IDENTITY_CURVE } from './comp-lib.mjs';

const HELP = `burke2comp — Alex Burke's inversie als Compositor-project

Gebruik:
  node compositor/burke2comp.mjs [opties] <scans of mappen...>

Leest DNG en TIFF: een scan van het negatief zoals het is, met wat filmrand in beeld.
Per scan komt er een <naam>.comp naast de scan, of in de map van --uit.

Opties:
  --rol             één witpunt en kleurbalans voor alle scans samen
  --basis <0-100>   dekking van de filmbasis-laag in procent (standaard 80, zoals Burke)
  --neutraal <0-100> hoe ver de kanalen in de middentonen gelijk worden getrokken
                    (standaard 75; lager houdt meer sfeer bij zonsopkomst en schemer)
  --rand <procent>  rand die het witpunt negeert (standaard 8)
  --vervang         bestaande projecten overschrijven in plaats van "naam 2.comp"
  --uit <map>       map voor de projecten
  -h, --help        deze uitleg
`;

function parseArgs(argv) {
  const o = { rol: false, basis: 80, neutraal: 75, rand: 8, vervang: false, uit: null, inputs: [] };
  const num = (v, name, lo, hi) => {
    const n = Number(v);
    if (!Number.isFinite(n) || n < lo || n > hi) fail(`${name} moet een getal tussen ${lo} en ${hi} zijn`);
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--rol') o.rol = true;
    else if (a === '--vervang') o.vervang = true;
    else if (a === '--basis') o.basis = num(argv[++i], '--basis', 0, 100);
    else if (a === '--neutraal') o.neutraal = num(argv[++i], '--neutraal', 0, 100);
    else if (a === '--rand') o.rand = num(argv[++i], '--rand', 0, 25);
    else if (a === '--uit') o.uit = argv[++i] || fail('--uit heeft een map nodig');
    else if (a.startsWith('-')) fail(`onbekende optie ${a} (zie --help)`);
    else o.inputs.push(a);
  }
  if (!o.inputs.length) { process.stdout.write(HELP); process.exit(1); }
  return o;
}

// ---------- Wat Compositor met de lagen doet ----------

/** Lineair → sRGB, 0–1: zo staan pixels in een Compositor-laag. */
const encode = (l) => (l <= 0.0031308 ? l * 12.92 : 1.055 * Math.pow(l, 1 / 2.4) - 0.055);
const SRGB16 = new Uint16Array(65536).map((_, i) => Math.round(encode(i / 65535) * 65535));

/** Compositor's Curven (Curves.swift): vormbehoudende kubische Hermite tussen de punten, 0–255. */
export function curveValue(points, x) {
  const p = points;
  let i = 0;
  for (let k = 0; k < p.length; k++) if (p[k].x <= x) i = k;
  i = Math.min(p.length - 2, Math.max(0, i));
  const d = [];
  for (let k = 0; k < p.length - 1; k++) d.push((p[k + 1].y - p[k].y) / (p[k + 1].x - p[k].x));
  const slope = (j) => {
    if (j === 0) return d[0];
    if (j === p.length - 1) return d[d.length - 1];
    if (d[j - 1] * d[j] <= 0) return 0;
    return 2 / (1 / d[j - 1] + 1 / d[j]);
  };
  const h = p[i + 1].x - p[i].x, t = Math.min(1, Math.max(0, (x - p[i].x) / h));
  const y = (2 * t ** 3 - 3 * t ** 2 + 1) * p[i].y + (t ** 3 - 2 * t ** 2 + t) * h * slope(i)
    + (-2 * t ** 3 + 3 * t ** 2) * p[i + 1].y + (t ** 3 - t ** 2) * h * slope(i + 1);
  return Math.min(255, Math.max(0, y));
}

/** Een Curven-laag op één kanaal (0 rood, 1 groen, 2 blauw), 0–1: eerst het kanaal, dan RGB. */
function applyCurves(channels, c, v) {
  return curveValue(channels[0], curveValue(channels[c + 1], v * 255)) / 255;
}

/** Aftrekken met dekking: (1 − a)·onder + a·max(0, onder − boven). */
const subtract = (below, top, opacity) => below - opacity * Math.min(below, top);

// ---------- Instellingen uit de scan ----------

const INVERT = [{ x: 0, y: 255 }, { x: 255, y: 0 }];
const CONTRAST = [{ x: 0, y: 0 }, { x: 64, y: 54 }, { x: 192, y: 204 }, { x: 255, y: 255 }];
/** Waar de middentonen na Witpunt & kleur uitkomen: wat donkerder dan half, zoals Burke de RGB-curve omlaag trekt. */
const MID_TARGET = 105;

/** De filmrand: het dunste deel van de hele scan (de onbelichte film), in sRGB 0–1 per kanaal. */
function filmBase(preview) {
  const base = NC.estimateBase(preview); // dichtheden
  return base ? base.map((d) => encode(Math.pow(10, -d))) : null;
}

/**
 * Na Inversie en Filmbasis: per kanaal een histogram (256 vakjes) van het binnenste van het beeld,
 * zonder de rand (houder, filmrand) en zonder doorzon.
 */
function histogramAfterBase(preview, baseInverted, opacity, border) {
  const hist = [new Float64Array(256), new Float64Array(256), new Float64Array(256)];
  const x0 = Math.floor(preview.w * border), x1 = preview.w - x0;
  const y0 = Math.floor(preview.h * border), y1 = preview.h - y0;
  const d = preview.data, clip = 65535 * 0.985;
  let total = 0;
  for (let y = y0; y < y1; y++) {
    for (let x = x0; x < x1; x++) {
      const i = (y * preview.w + x) * 3;
      if (d[i] >= clip && d[i + 1] >= clip && d[i + 2] >= clip) continue;
      for (let c = 0; c < 3; c++) {
        const v = subtract(1 - SRGB16[d[i + c]] / 65535, baseInverted[c], opacity);
        hist[c][Math.min(255, Math.round(v * 255))]++;
      }
      total++;
    }
  }
  return { hist, total };
}

export function mergeHist(list) {
  const hist = [new Float64Array(256), new Float64Array(256), new Float64Array(256)];
  let total = 0;
  for (const h of list) {
    for (let c = 0; c < 3; c++) for (let i = 0; i < 256; i++) hist[c][i] += h.hist[c][i];
    total += h.total;
  }
  return { hist, total };
}

function percentile(bins, total, p) {
  let sum = 0;
  for (let i = 0; i < 256; i++) {
    sum += bins[i];
    if (sum >= total * p) return i;
  }
  return 255;
}

/**
 * Witpunt & kleur, wat Burke met de hand in één Curven-laag doet:
 *  - per kanaal het witpunt net voor het clippen (Burke: met Alt slepen tot het clipt, dan iets terug),
 *    en een zwartpunt net boven de diepste schaduw;
 *  - de kanalen in de schaduwen en middentonen naar elkaar toe (`neutral`, 0–1): daar zit het blauw
 *    dat Burke flink omlaag haalt, en het groen dat wat omlaag moet;
 *  - de RGB-curve zo dat de middentonen op MID_TARGET komen, want na het witpunt is het te licht.
 * Compositor wil dat elke curve bij x 0 begint en bij x 255 eindigt.
 */
function whiteAndColor(H, neutral) {
  const at = (c, p) => percentile(H.hist[c], H.total, p);
  const white = [0, 1, 2].map((c) => Math.max(40, at(c, 0.999)));
  // Niet verder dan 60: een donker beeld (nacht) houdt zijn schaduwtekening
  const black = [0, 1, 2].map((c) => Math.min(60, at(c, 0.001), white[c] - 30));
  // Twee tonen waarop de kanalen naar elkaar toe gaan: schaduw en midden
  const tones = [0.15, 0.5].map((p) => [0, 1, 2].map((c) => at(c, p)));
  // Waar elke toon uitkomt na alleen zwart- en witpunt, en het gemiddelde over de kanalen
  const level = (c, x) => (255 * (x - black[c])) / (white[c] - black[c]);
  const common = (xs) => (level(0, xs[0]) + level(1, xs[1]) + level(2, xs[2])) / 3;
  const targets = tones.map(common);
  const round = (v) => Math.round(v * 10) / 10;
  const channels = [0, 1, 2].map((c) => {
    const points = [{ x: 0, y: 0 }];
    if (black[c] > 0) points.push({ x: black[c], y: 0 });
    for (const [k, tone] of tones.entries()) {
      const x = tone[c], target = targets[k];
      const last = points[points.length - 1];
      if (x <= last.x + 2 || x >= white[c] - 2) continue;
      const y = level(c, x) + (target - level(c, x)) * neutral;
      points.push({ x, y: round(Math.min(250, Math.max(last.y + 1, y))) });
    }
    points.push({ x: white[c], y: 255 });
    if (white[c] < 255) points.push({ x: 255, y: 255 });
    return points;
  });
  const mid = Math.min(240, Math.max(15, targets[1]));
  const rgb = [{ x: 0, y: 0 }, { x: round(mid), y: MID_TARGET }, { x: 255, y: 255 }];
  return [rgb, ...channels];
}

// ---------- Project ----------

function curvesLayer(name, channels, w, h) {
  const layer = adjustmentLayer('Curves', name, w, h);
  layer.adjustment.curves = { channel: 'RGB', channels };
  return layer;
}

/** Een 1×1 PNG in één kleur (16-bit); Compositor rekt hem op tot de laaggrootte. */
function solidPNG(rgb) {
  const px = new Uint16Array([0, 0, 0]).map((_, c) => Math.round(rgb[c] * 65535));
  return encodePNG16(px, 1, 1);
}

export function analyzeScan(file, o) {
  const preview = NC.downscale(decode(file), 1600);
  const base = filmBase(preview) || [0.8, 0.5, 0.3];
  const baseInverted = base.map((v) => 1 - v);
  return { file, baseInverted, H: histogramAfterBase(preview, baseInverted, o.basis / 100, o.rand / 100) };
}

export function buildProject(scan, H, o) {
  const full = decode(scan.file);
  const w = full.w, h = full.h;
  const encoded = new Uint16Array(full.data.length);
  for (let i = 0; i < encoded.length; i++) encoded[i] = SRGB16[full.data[i]];

  const scanID = uuid(), baseID = uuid();
  const images = [
    [`${scanID}.png`, encodePNG16(encoded, w, h)],
    [`${baseID}.png`, solidPNG(scan.baseInverted)],
  ];
  const baseLayer = imageLayer(baseID, 'Filmbasis', w, h, true);
  baseLayer.blendMode = 'Subtract';
  baseLayer.opacity = o.basis / 100;
  const color = curvesLayer('Witpunt & kleur', whiteAndColor(H, o.neutraal / 100), w, h);
  color.active = true;
  const layers = [
    imageLayer(scanID, 'Scan', w, h, true),
    curvesLayer('Inversie', [INVERT, IDENTITY_CURVE, IDENTITY_CURVE, IDENTITY_CURVE], w, h),
    baseLayer,
    color,
    adjustmentLayer('Hue/Saturation', 'Hue/Saturation', w, h),
    curvesLayer('Contrast', [CONTRAST, IDENTITY_CURVE, IDENTITY_CURVE, IDENTITY_CURVE], w, h),
  ];
  return { w, h, dpi: full.dpi, layers, images, encoded };
}

/**
 * Wat Compositor van deze lagen maakt, voor een pixel (sRGB 0–1 per kanaal): om de instellingen
 * te controleren zonder Compositor.
 */
export function simulate(rgb, layers, baseInverted) {
  const by = (name) => layers.find((l) => l.name === name);
  const inv = by('Inversie').adjustment.curves.channels;
  const base = by('Filmbasis');
  const color = by('Witpunt & kleur').adjustment.curves.channels;
  const contrast = by('Contrast').adjustment.curves.channels;
  return [0, 1, 2].map((c) => {
    let v = applyCurves(inv, c, rgb[c]);
    v = subtract(v, baseInverted[c], base.opacity);
    v = applyCurves(color, c, v);
    return applyCurves(contrast, c, v);
  });
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const files = expandInputs(o.inputs);
  if (!files.length) fail('geen DNG- of TIFF-bestanden gevonden');
  if (o.uit) fs.mkdirSync(o.uit, { recursive: true });

  console.log(`${files.length} scan${files.length > 1 ? 's' : ''} meten…`);
  const scans = files.map((f) => analyzeScan(f, o));
  const rollH = o.rol ? mergeHist(scans.map((s) => s.H)) : null;
  for (const [n, scan] of scans.entries()) {
    const name = path.basename(scan.file).replace(/\.[^.]+$/, '');
    process.stdout.write(`[${n + 1}/${scans.length}] ${name}: `);
    const p = buildProject(scan, rollH || scan.H, o);
    const target = path.join(o.uit || path.dirname(scan.file), `${name}.comp`);
    const dest = o.vervang ? target : freePath(target);
    if (o.vervang) fs.rmSync(dest, { recursive: true, force: true });
    writeProject(dest, p.w, p.h, p.dpi, p.layers, p.images);
    console.log(`${p.w} × ${p.h} px → ${dest}`);
  }
  console.log('Klaar. Open de .comp-bestanden in Compositor en stel de lagen bij.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main();
