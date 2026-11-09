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
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const require = createRequire(import.meta.url);

// ---------- Rekenkern en TIFF/DNG-lezer laden ----------

/** Laadt een UMD/CommonJS-bestand met een eigen `require`. */
function loadModule(file, deps = {}) {
  const src = fs.readFileSync(file, 'utf8');
  const module = { exports: {} };
  const req = (name) => (name in deps ? deps[name] : require(name));
  new Function('module', 'exports', 'require', 'self', src)(module, module.exports, req, globalThis);
  return module.exports;
}
const pako = loadModule(path.join(root, 'vendor/pako_inflate.min.js'));
const UTIF = loadModule(path.join(root, 'vendor/utif.js'), { pako });
const NC = loadModule(path.join(root, 'converter-core.js'));

// ---------- Opties ----------

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

function fail(msg) {
  console.error('Fout: ' + msg);
  process.exit(1);
}

function expandInputs(inputs) {
  const files = [];
  for (const p of inputs) {
    if (!fs.existsSync(p)) fail(`${p} bestaat niet`);
    if (fs.statSync(p).isDirectory()) {
      for (const f of fs.readdirSync(p)) {
        if (/\.(dng|tiff?)$/i.test(f) && !f.startsWith('.')) files.push(path.join(p, f));
      }
    } else if (/\.(dng|tiff?)$/i.test(p)) {
      files.push(p);
    } else {
      console.warn(`Overgeslagen: ${p} (alleen DNG en TIFF)`);
    }
  }
  return files.sort((a, b) => path.basename(a).localeCompare(path.basename(b), undefined, { numeric: true }));
}

// ---------- PNG schrijven (16-bit RGB) ----------

const CRC_TABLE = new Int32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c;
});
function crc32(buf) {
  let c = -1;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 255] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

/** rgb: Uint16Array (RGB, 0–65535). Rijen met het Sub-filter, voor kleinere bestanden. */
function encodePNG16(rgb, w, h) {
  const bpp = 6, stride = w * bpp;
  const raw = Buffer.alloc(h * (stride + 1));
  for (let y = 0; y < h; y++) {
    const o = y * (stride + 1);
    raw[o] = 1; // Sub
    const row = raw.subarray(o + 1, o + 1 + stride);
    for (let x = 0, i = y * w * 3; x < w * 3; x++, i++) {
      row[x * 2] = rgb[i] >> 8;
      row[x * 2 + 1] = rgb[i] & 255;
    }
    for (let x = stride - 1; x >= bpp; x--) row[x] = (row[x] - row[x - bpp]) & 255;
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 16; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0; // 16-bit, RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('sRGB', Buffer.from([0])),
    chunk('IDAT', zlib.deflateSync(raw, { level: 6 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- Compositor-project ----------

const uuid = () => crypto.randomUUID().toUpperCase();

function transform(w, h) {
  return { origin: [0, 0], size: [w, h], rotation: 0, flipX: false, flipY: false, sampling: 'High quality' };
}

const IDENTITY_RANGE = { black: 0, gamma: 1, white: 255, outputBlack: 0, outputWhite: 255 };
const IDENTITY_CURVE = [{ x: 0, y: 0 }, { x: 255, y: 255 }];

/** Een neutrale aanpassingslaag: alle velden die Compositor verwacht, op hun nulstand. */
function adjustmentLayer(kind, name, w, h) {
  const adjustment = {
    kind,
    hue: 0, saturation: 0, lightness: 0, colorize: false,
    levels: { channel: 'RGB', ranges: [IDENTITY_RANGE, IDENTITY_RANGE, IDENTITY_RANGE, IDENTITY_RANGE] },
    curves: { channel: 'RGB', channels: [IDENTITY_CURVE, IDENTITY_CURVE, IDENTITY_CURVE, IDENTITY_CURVE] },
  };
  if (kind === 'Color Balance') {
    adjustment.colorBalanceSettings = {
      shadowCyanRed: 0, shadowMagentaGreen: 0, shadowYellowBlue: 0,
      midCyanRed: 0, midMagentaGreen: 0, midYellowBlue: 0,
      highlightCyanRed: 0, highlightMagentaGreen: 0, highlightYellowBlue: 0,
      preserveLuminosity: true,
    };
  }
  return { id: uuid(), name, isVisible: true, isGroup: false, opacity: 1, blendMode: 'Normal',
           transform: transform(w, h), adjustment };
}

function imageLayer(id, name, w, h, visible) {
  return { id, name, imageFile: `${id}.png`, isVisible: visible, isGroup: false, opacity: 1,
           blendMode: 'Normal', transform: transform(w, h) };
}

function freePath(p) {
  if (!fs.existsSync(p)) return p;
  const ext = path.extname(p), base = p.slice(0, -ext.length);
  for (let n = 2; ; n++) if (!fs.existsSync(`${base} ${n}${ext}`)) return `${base} ${n}${ext}`;
}

/** Schrijft het project eerst naast de bestemming en hernoemt het daarna. */
function writeProject(dest, w, h, dpi, layers, images) {
  const tmp = path.join(path.dirname(dest), `.${path.basename(dest)}.tmp-${process.pid}`);
  fs.rmSync(tmp, { recursive: true, force: true });
  fs.mkdirSync(path.join(tmp, 'images'), { recursive: true });
  for (const [file, data] of images) fs.writeFileSync(path.join(tmp, 'images', file), data);
  const active = layers.find((l) => l.name === 'Positief') || layers[0];
  const manifest = {
    format: 'com.compositor.project',
    version: 12, // 16-bit lagen vanaf versie 12
    colorSpace: 'sRGB',
    documentID: uuid(),
    width: w,
    height: h,
    resolution: dpi || 72,
    activeLayerID: active.id,
    layers,
  };
  fs.writeFileSync(path.join(tmp, 'manifest.json'), JSON.stringify(manifest, null, 2));
  fs.renameSync(tmp, dest);
}

// ---------- Omzetten ----------

function decode(file) {
  const buf = fs.readFileSync(file);
  return NC.decodeTIFF(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length), UTIF);
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
