#!/usr/bin/env node
/*
 * scan-inbox — zet nieuwe negatief-scans vanzelf om.
 *
 * VueScan bewaart raw DNG's in een inbox-map. Dit script zet elke nieuwe, volledig
 * geschreven scan om naar een positief in <inbox>/Positief/:
 *   naam.tif   16-bit, om verder te bewerken (Lightroom, Foto's, Affinity…)
 *   naam.jpg   kwaliteit 92, om te bekijken en te delen
 *
 * Zodra er een paar minuten geen nieuwe scan bijkomt, is de rol klaar: dan worden alle
 * frames van die rol opnieuw omgezet met één kleurbalans, zodat ze bij elkaar passen.
 *
 * Bedoeld om te draaien als achtergrondtaak (zie install.sh), maar met de hand kan ook:
 *   node automation/scan-inbox.mjs ~/Scans/Inbox
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const require = createRequire(import.meta.url);

// ---------- Rekenkern (dezelfde als de converter) ----------

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
// Alex Burke's lagen als Compositor-project (--burke)
const burke = await import(path.join(root, 'compositor/burke2comp.mjs'));
const comp = await import(path.join(root, 'compositor/comp-lib.mjs'));

// ---------- Opties ----------

const HELP = `scan-inbox — nieuwe negatief-scans vanzelf omzetten

Gebruik:
  node automation/scan-inbox.mjs <inbox-map> [opties]

Opties:
  --zw            zwart-wit negatieven
  --positief      de scans zijn al positief: alleen bijstellen, niet omkeren
  --geen-jpg      alleen de 16-bit TIFF
  --burke        in plaats van TIFF en JPEG een Compositor-project per scan met
                  Alex Burke's lagen (inversie, filmbasis, curven), om bij te stellen
  --geen-rol      elk frame op zichzelf laten, geen kleurbalans per rol
  --rust <min>    minuten zonder nieuwe scan voordat de rol klaar heet (standaard 3)
  --stil          geen meldingen
  -h, --help      deze uitleg
`;

function parseArgs(argv) {
  const o = { inbox: null, zw: false, positief: false, jpg: true, rol: true, rust: 3, stil: false, burke: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { process.stdout.write(HELP); process.exit(0); }
    else if (a === '--zw') o.zw = true;
    else if (a === '--positief') o.positief = true;
    else if (a === '--geen-jpg') o.jpg = false;
    else if (a === '--geen-rol') o.rol = false;
    else if (a === '--burke') o.burke = true;
    else if (a === '--stil') o.stil = true;
    else if (a === '--rust') {
      o.rust = Number(argv[++i]);
      if (!Number.isFinite(o.rust) || o.rust < 0) fail('--rust moet een aantal minuten zijn');
    } else if (a.startsWith('-')) fail(`onbekende optie ${a} (zie --help)`);
    else if (!o.inbox) o.inbox = a;
    else fail('geef één inbox-map op');
  }
  if (!o.inbox) { process.stdout.write(HELP); process.exit(1); }
  if (o.burke && (o.zw || o.positief)) fail('--burke is voor kleurnegatieven, niet samen met --zw of --positief');
  return o;
}

function fail(msg) {
  log('Fout: ' + msg);
  process.exit(1);
}

function log(msg) {
  const t = new Date().toLocaleString('nl-NL', { hour12: false });
  console.log(`[${t}] ${msg}`);
}

// ---------- Bestanden ----------

/** Een scan: DNG of TIFF, geen verborgen bestand en niet een eigen uitvoer. */
function isScan(name) {
  return /\.(dng|tiff?)$/i.test(name) && !name.startsWith('.');
}

const baseName = (file) => path.basename(file).replace(/\.[^.]+$/, '');

function scansIn(inbox) {
  return fs.readdirSync(inbox, { withFileTypes: true })
    .filter((e) => e.isFile() && isScan(e.name))
    .map((e) => path.join(inbox, e.name))
    .sort((a, b) => path.basename(a).localeCompare(path.basename(b), undefined, { numeric: true }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Wacht tot VueScan klaar is met schrijven: de grootte blijft gelijk en het bestand is
 * een paar seconden niet veranderd. Nil als het na `maxWait` nog bezig is.
 */
async function settled(file, maxWait = 60000) {
  const start = Date.now();
  let last = -1;
  while (Date.now() - start < maxWait) {
    let st;
    try { st = fs.statSync(file); } catch { return false; }
    if (st.size > 0 && st.size === last && Date.now() - st.mtimeMs > 3000) return true;
    last = st.size;
    await sleep(2000);
  }
  return false;
}

function writeAtomic(dest, data) {
  const tmp = path.join(path.dirname(dest), `.${path.basename(dest)}.tmp-${process.pid}`);
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, dest);
}

// ---------- Status: welke rol loopt er ----------

function readState(file) {
  try { return Object.assign({ roll: null, failed: {} }, JSON.parse(fs.readFileSync(file, 'utf8'))); }
  catch { return { roll: null, failed: {} }; }
}

function writeState(file, state) {
  writeAtomic(file, JSON.stringify(state, null, 2));
}

// ---------- Omzetten ----------

function decode(file) {
  const buf = fs.readFileSync(file);
  return NC.decodeTIFF(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length), UTIF);
}

function analysis(file, o) {
  const preview = NC.downscale(decode(file), 1600);
  const hist = NC.histogram(preview, 0.08);
  const masked = NC.maskStrength(hist) >= 0.15;
  return { hist, base: o.positief ? null : NC.estimateBase(preview), masked };
}

/** Schrijft naam.tif (16-bit) en naam.jpg in `outDir`. */
function render(file, an, o, outDir) {
  const settings = Object.assign(NC.defaults(), { positive: o.positief, bw: o.zw });
  const full = decode(file);
  const rgb = new Uint16Array(full.w * full.h * 3);
  NC.render(full, NC.buildParams(an, settings), rgb, 16, false);
  const tif = path.join(outDir, `${baseName(file)}.tif`);
  writeAtomic(tif, NC.encodeTIFF16(rgb, full.w, full.h));
  if (o.jpg) {
    const jpg = path.join(outDir, `${baseName(file)}.jpg`);
    const tmp = path.join(outDir, `.${path.basename(jpg)}.tmp-${process.pid}.jpg`);
    try {
      // sips hoort bij macOS: van 16-bit TIFF naar JPEG
      execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '92', tif, '--out', tmp], { stdio: 'ignore' });
      fs.renameSync(tmp, jpg);
    } catch {
      fs.rmSync(tmp, { force: true });
      log(`  JPEG overgeslagen voor ${baseName(file)} (sips niet beschikbaar)`);
    }
  }
  return [full.w, full.h];
}

/** Alex Burke's lagen als Compositor-project in `outDir`; `H` is het histogram van de scan of van de rol. */
const BURKE = { basis: 80, neutraal: 75, rand: 8 };
function writeBurke(scan, H, outDir) {
  const p = burke.buildProject(scan, H, BURKE);
  const dest = path.join(outDir, `${baseName(scan.file)}.comp`);
  fs.rmSync(dest, { recursive: true, force: true });
  comp.writeProject(dest, p.w, p.h, p.dpi, p.layers, p.images);
  return [p.w, p.h];
}

function notify(o, title, message) {
  if (o.stil) return;
  try {
    execFileSync('osascript', ['-e', `display notification ${JSON.stringify(message)} with title ${JSON.stringify(title)}`],
                 { stdio: 'ignore' });
  } catch { /* geen macOS of geen meldingen: niet erg */ }
}

// ---------- Hoofdlus ----------

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const inbox = path.resolve(o.inbox.replace(/^~(?=\/|$)/, process.env.HOME || '~'));
  if (!fs.existsSync(inbox) || !fs.statSync(inbox).isDirectory()) fail(`${inbox} is geen map`);
  const outDir = path.join(inbox, 'Positief');
  fs.mkdirSync(outDir, { recursive: true });
  const stateFile = path.join(inbox, '.scan-inbox.json');

  // Eén tegelijk: een tweede start (de taak en de hand) stopt meteen.
  const lock = path.join(inbox, '.scan-inbox.lock');
  try {
    fs.writeFileSync(lock, String(process.pid), { flag: 'wx' });
  } catch {
    const pid = Number(fs.readFileSync(lock, 'utf8'));
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch { /* niet meer actief */ }
    if (alive) return;
    fs.writeFileSync(lock, String(process.pid));
  }
  const unlock = () => { try { fs.rmSync(lock, { force: true }); } catch { /* al weg */ } };
  process.on('exit', unlock);

  const state = readState(stateFile);
  let converted = 0, noMask = [];

  // 1. Nieuwe scans: alles zonder TIFF in Positief/, zodra VueScan klaar is met schrijven
  for (;;) {
    // Een scan die niet lukte, pas opnieuw als het bestand veranderd is.
    const failedBefore = (f) => state.failed[path.basename(f)] === fs.statSync(f).size;
    const output = (f) => path.join(outDir, `${baseName(f)}.${o.burke ? 'comp' : 'tif'}`);
    const pending = scansIn(inbox).filter((f) => !fs.existsSync(output(f)) && !failedBefore(f));
    if (!pending.length) break;
    let progressed = false;
    for (const file of pending) {
      if (!(await settled(file))) { log(`${path.basename(file)}: wordt nog geschreven, later opnieuw`); continue; }
      try {
        let size;
        if (o.burke) {
          const scan = burke.analyzeScan(file, BURKE);
          size = writeBurke(scan, scan.H, outDir);
        } else {
          const an = analysis(file, o);
          if (!o.positief && !an.masked) noMask.push(path.basename(file));
          size = render(file, NC.analyze(an.hist, an.base), o, outDir);
        }
        log(`${path.basename(file)} → ${path.relative(inbox, output(file))} (${size[0]} × ${size[1]})`);
        // Een scan na een afgeronde rol begint een nieuwe rol.
        if (!state.roll || state.roll.balanced) state.roll = { files: [], balanced: false };
        if (!state.roll.files.includes(path.basename(file))) state.roll.files.push(path.basename(file));
        state.roll.last = Date.now();
        delete state.failed[path.basename(file)];
        writeState(stateFile, state);
        converted++;
        progressed = true;
      } catch (e) {
        log(`${path.basename(file)}: kon niet worden omgezet: ${e.message}`);
        state.failed[path.basename(file)] = fs.statSync(file).size;
        writeState(stateFile, state);
      }
    }
    if (!progressed) break;
  }
  if (converted) {
    notify(o, 'Scans omgezet', `${converted} nieuw${converted > 1 ? 'e scans' : 'e scan'} in Positief`);
  }
  if (noMask.length) {
    log(`Geen oranje masker in ${noMask.join(', ')}: al positief, of zwart-wit? Gebruik dan --positief of --zw.`);
  }

  // 2. Rol klaar (een tijd geen nieuwe scan): alle frames samen in balans brengen
  const roll = state.roll;
  if (o.rol && roll && !roll.balanced && roll.files.length > 1 && Date.now() - roll.last >= o.rust * 60000) {
    const files = roll.files.map((f) => path.join(inbox, f)).filter((f) => fs.existsSync(f));
    log(`Rol klaar: ${files.length} frames met één kleurbalans…`);
    if (o.burke) {
      const scans = files.map((f) => burke.analyzeScan(f, BURKE));
      const rollH = burke.mergeHist(scans.map((s) => s.H));
      for (const scan of scans) {
        writeBurke(scan, rollH, outDir);
        log(`  ${path.basename(scan.file)} opnieuw`);
      }
    } else {
      const each = files.map((f) => ({ file: f, ...analysis(f, o) }));
      const rollHist = NC.mergeHistograms(each.map((e) => e.hist));
      for (const e of each) {
        render(e.file, NC.analyze(rollHist, e.base), o, outDir);
        log(`  ${path.basename(e.file)} opnieuw`);
      }
    }
    roll.balanced = true;
    writeState(stateFile, state);
    notify(o, 'Rol klaar', `${files.length} foto's met één kleurbalans in Positief`);
  }
}

main().catch((e) => fail(e.stack || e.message));
