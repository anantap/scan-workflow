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
import { createRequire } from 'node:module';
import { NC, fail, expandInputs, encodePNG16, uuid, freePath, writeProject, decode } from './comp-lib.mjs';

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

// ---------- Rekenkern (gedeeld met de Mac-app) ----------

const BC = createRequire(import.meta.url)('./burke-core.js')(NC);
export const mergeHist = BC.mergeHist;
export const curveValue = BC.curveValue;

export function analyzeScan(file, o) {
  return { file, ...BC.analyzePreview(NC.downscale(decode(file), 1600), o) };
}

/** Een 1×1 PNG in één kleur (16-bit); Compositor rekt hem op tot de laaggrootte. */
function solidPNG(rgb) {
  return encodePNG16(new Uint16Array([0, 1, 2].map((c) => Math.round(rgb[c] * 65535))), 1, 1);
}

export function buildProject(scan, H, o) {
  const full = decode(scan.file);
  const w = full.w, h = full.h;
  const encoded = BC.encodedScan(full);
  const ids = Array.from({ length: 6 }, () => uuid());
  const built = BC.buildLayers(w, h, H, scan.baseInverted, ids, o);
  built.layers.find((l) => l.id === built.activeLayerID).active = true;
  const images = [
    [`${ids[0]}.png`, encodePNG16(encoded, w, h)],
    [`${ids[2]}.png`, solidPNG(scan.baseInverted)],
  ];
  return { w, h, dpi: full.dpi, layers: built.layers, images, encoded };
}

/** Wat Compositor van deze lagen maakt, voor een pixel (sRGB 0–1 per kanaal). */
export const simulate = BC.simulate;

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
