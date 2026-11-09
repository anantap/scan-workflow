#!/usr/bin/env node
/*
 * neg2comp — zet negatieven om naar Compositor-projecten (.comp).
 *
 * Gebruikt dezelfde rekenkern als de Negatief Converter (../converter-core.js),
 * dus de kleuren komen overeen. Per scan komt er één project met:
 *   - "Positief": het omgezette beeld als 16-bit laag
 *   - neutrale aanpassingslagen (Niveaus, Curven, Kleurbalans) om bij te stellen
 *   - optioneel het originele negatief als verborgen laag eronder
 *
 * Gebruik:  node compositor/neg2comp.mjs [opties] <scans of mappen...>
 */
import fs from 'node:fs';
import path from 'node:path';
import { NC, fail, expandInputs, encodePNG16, uuid, adjustmentLayer, imageLayer, freePath, writeProject, decode }
  from './comp-lib.mjs';

const HELP = `neg2comp — negatieven omzetten naar Compositor-projecten

Gebruik:
  node compositor/neg2comp.mjs [opties] <scans of mappen...>

Leest DNG en TIFF (de raw-bestanden van VueScan). Per scan komt er een
<naam>.comp naast de scan, of in de map van --uit.

Opties:
  --rol             één kleurbalans voor alle scans samen (consistent over de rol)
  --positief        de scans zijn al positief: niet omkeren
  --zw              zwart-wit
  --rand <procent>  rand die de analyse negeert (standaard 8)
  --belichting <n>  -100 tot 100 (standaard 0)
  --contrast <n>    0 tot 100 (standaard 30)
  --met-negatief    het originele negatief als verborgen laag toevoegen
  --uit <map>       map voor de projecten
  -h, --help        deze uitleg
`;

function parseArgs(argv) {
  const o = { rol: false, positief: false, zw: false, rand: 8, belichting: 0, contrast: 30,
              metNegatief: false, uit: null, inputs: [] };
  const num = (v, name, lo, hi) => {
    const n = Number(v);
    if (!Number.isFinite(n) || n < lo || n > hi) fail(`${name} moet een getal tussen ${lo} en ${hi} zijn`);
    return n;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--rol') o.rol = true;
    else if (a === '--positief') o.positief = true;
    else if (a === '--zw') o.zw = true;
    else if (a === '--met-negatief') o.metNegatief = true;
    else if (a === '--rand') o.rand = num(argv[++i], '--rand', 0, 25);
    else if (a === '--belichting') o.belichting = num(argv[++i], '--belichting', -100, 100);
    else if (a === '--contrast') o.contrast = num(argv[++i], '--contrast', 0, 100);
    else if (a === '--uit') o.uit = argv[++i] || fail('--uit heeft een map nodig');
    else if (a.startsWith('-')) fail(`onbekende optie ${a} (zie --help)`);
    else o.inputs.push(a);
  }
  if (!o.inputs.length) { process.stdout.write(HELP); process.exit(1); }
  return o;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  const files = expandInputs(o.inputs);
  if (!files.length) fail('geen DNG- of TIFF-bestanden gevonden');
  if (o.uit) fs.mkdirSync(o.uit, { recursive: true });

  const settings = Object.assign(NC.defaults(), {
    positive: o.positief, bw: o.zw, exposure: o.belichting, contrast: o.contrast,
  });
  const border = o.rand / 100;

  // 1. Analyse op een verkleinde versie (zoals in de converter)
  console.log(`${files.length} scan${files.length > 1 ? 's' : ''} analyseren…`);
  const info = files.map((file) => {
    const preview = NC.downscale(decode(file), 1600);
    const hist = NC.histogram(preview, border);
    const mask = NC.maskStrength(hist);
    if (!o.positief && mask < 0.15) {
      console.warn(`  ${path.basename(file)}: geen oranje masker gevonden. Al positief? Gebruik dan --positief.`);
    }
    return { file, hist, base: o.positief ? null : NC.estimateBase(preview) };
  });
  const rollHist = o.rol ? NC.mergeHistograms(info.map((i) => i.hist)) : null;

  // 2. Volledige resolutie omzetten en wegschrijven
  for (const [n, it] of info.entries()) {
    const name = path.basename(it.file).replace(/\.[^.]+$/, '');
    process.stdout.write(`[${n + 1}/${info.length}] ${name}: `);
    const full = decode(it.file);
    const an = NC.analyze(rollHist || it.hist, it.base);
    const P = NC.buildParams(an, settings);

    const pos = new Uint16Array(full.w * full.h * 3);
    NC.render(full, P, pos, 16, false);
    const posID = uuid();
    const images = [[`${posID}.png`, encodePNG16(pos, full.w, full.h)]];
    const layers = [];

    if (o.metNegatief) {
      const neg = new Uint16Array(full.w * full.h * 3);
      NC.render(full, P, neg, 16, true);
      const negID = uuid();
      images.push([`${negID}.png`, encodePNG16(neg, full.w, full.h)]);
      layers.push(imageLayer(negID, 'Negatief (origineel)', full.w, full.h, false));
    }
    layers.push(imageLayer(posID, 'Positief', full.w, full.h, true));
    layers.push(adjustmentLayer('Levels', 'Niveaus', full.w, full.h));
    layers.push(adjustmentLayer('Curves', 'Curven', full.w, full.h));
    layers.push(adjustmentLayer('Color Balance', 'Kleurbalans', full.w, full.h));

    const dest = freePath(path.join(o.uit || path.dirname(it.file), `${name}.comp`));
    writeProject(dest, full.w, full.h, full.dpi, layers, images);
    console.log(`${full.w} × ${full.h} px → ${dest}`);
  }
  console.log('Klaar. Open de .comp-bestanden in Compositor.');
}

main();
