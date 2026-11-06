/*
 * Negatief-converter — rekenkern.
 *
 * Werkwijze (zoals bij een analoge afdruk):
 *  1. Scannerwaarde (lineaire transmissie) → optische dichtheid D = -log10(T).
 *  2. Per kanaal: D normaliseren tussen het dunste punt (filmbasis/schaduwen)
 *     en het dichtste punt (hooglichten). Dit neutraliseert het oranje masker
 *     en geeft een waarde n die lineair is in log-belichting van de scène.
 *  3. n door een S-vormige "papiercurve" sturen → weergavewaarde (sRGB).
 *
 * Geen DOM-afhankelijkheden: draait in de browser en in Node (voor tests).
 */
(function (root) {
  'use strict';

  const NC = {};
  const MAXV = 65535;

  // Dichtheid per 16-bit waarde
  const DLUT = new Float32Array(65536);
  for (let i = 0; i < 65536; i++) DLUT[i] = -Math.log10(Math.max(i, 1) / MAXV);
  NC.DLUT = DLUT;

  // sRGB (8-bit) → lineair 16-bit
  const SRGB8 = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    const c = i / 255;
    const l = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    SRGB8[i] = Math.round(l * MAXV);
  }
  NC.SRGB8 = SRGB8;

  // ---------- Decoderen ----------

  /** RGBA 8-bit (canvas ImageData) → lineair 16-bit RGB */
  NC.fromRGBA8 = function (rgba, w, h) {
    const n = w * h, data = new Uint16Array(n * 3);
    for (let p = 0, q = 0; p < n; p++, q += 4) {
      data[p * 3] = SRGB8[rgba[q]];
      data[p * 3 + 1] = SRGB8[rgba[q + 1]];
      data[p * 3 + 2] = SRGB8[rgba[q + 2]];
    }
    return { w, h, data };
  };

  /** TIFF / DNG (ArrayBuffer) → lineair 16-bit RGB, via UTIF */
  NC.decodeTIFF = function (buffer, UTIF) {
    const ifds = UTIF.decode(buffer);
    const all = [];
    (function collect(list) {
      for (const f of list || []) {
        all.push(f);
        if (f.subIFD) collect(f.subIFD);
      }
    })(ifds);

    let img = null, best = 0;
    for (const f of all) {
      if (!f.t256 || !f.t257) continue;
      const comp = f.t259 ? f.t259[0] : 1;
      const photo = f.t262 ? f.t262[0] : 2;
      if (comp === 6 || photo === 6 || photo === 32803) continue; // JPEG-thumbnails / Bayer-CFA
      const area = f.t256[0] * f.t257[0];
      if (area > best) { best = area; img = f; }
    }
    if (!img) throw new Error('Geen bruikbare afbeelding gevonden in dit bestand');

    UTIF.decodeImage(buffer, img, ifds);
    const w = img.width, h = img.height;
    const bps = img.t258 ? img.t258[0] : 8;
    const spp = img.t277 ? img.t277[0] : (img.t258 ? img.t258.length : 1);
    const fmt = img.t339 ? img.t339[0] : 1;
    const isDNG = !!img.t50706 || !!ifds[0].t50706;
    const n = w * h;
    const out = new Uint16Array(n * 3);
    const src = img.data;

    let get; // (sampleIndex) → 0..1 (of 0..65535 bij 16-bit)
    if (bps === 16) {
      const a = (src.byteOffset % 2 === 0)
        ? new Uint16Array(src.buffer, src.byteOffset, Math.floor(src.byteLength / 2))
        : new Uint16Array(src.slice().buffer);
      get = (i) => a[i];
    } else if (bps === 32 && fmt === 3) {
      const a = (src.byteOffset % 4 === 0)
        ? new Float32Array(src.buffer, src.byteOffset, Math.floor(src.byteLength / 4))
        : new Float32Array(src.slice().buffer);
      get = (i) => Math.max(0, Math.min(MAXV, a[i] * MAXV));
    } else if (bps === 8) {
      // 8-bit TIFF is vrijwel altijd gamma-gecodeerd
      get = isDNG ? (i) => src[i] * 257 : (i) => SRGB8[src[i]];
    } else {
      throw new Error('Niet ondersteunde bitdiepte: ' + bps + ' bit');
    }

    // DNG zwart-/witniveau
    // (get() levert altijd 0..65535; bij 8-bit DNG is de tagwaarde in 8-bit schaal)
    const unit = bps === 8 ? 257 : 1;
    let black = 0, white = MAXV;
    if (isDNG && bps !== 32 && img.t50714) black = img.t50714[0] * unit;
    if (isDNG && bps !== 32 && img.t50717) white = img.t50717[0] * unit;
    const scale = MAXV / Math.max(1, white - black);

    for (let p = 0; p < n; p++) {
      const base = p * spp;
      for (let c = 0; c < 3; c++) {
        let v = get(base + (spp >= 3 ? c : 0));
        if (black || scale !== 1) v = (v - black) * scale;
        out[p * 3 + c] = v < 0 ? 0 : v > MAXV ? MAXV : v;
      }
    }
    return { w, h, data: out };
  };

  /** Box-verkleining tot de lange zijde ≤ maxEdge */
  NC.downscale = function (img, maxEdge) {
    const f = Math.max(1, Math.ceil(Math.max(img.w, img.h) / maxEdge));
    if (f === 1) return img;
    const w = Math.floor(img.w / f), h = Math.floor(img.h / f);
    const out = new Uint16Array(w * h * 3), d = img.data, sw = img.w, inv = 1 / (f * f);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let r = 0, g = 0, b = 0;
        for (let yy = 0; yy < f; yy++) {
          let i = ((y * f + yy) * sw + x * f) * 3;
          for (let xx = 0; xx < f; xx++, i += 3) { r += d[i]; g += d[i + 1]; b += d[i + 2]; }
        }
        const o = (y * w + x) * 3;
        out[o] = r * inv; out[o + 1] = g * inv; out[o + 2] = b * inv;
      }
    }
    return { w, h, data: out };
  };

  // ---------- Analyse ----------

  NC.HBINS = 2048;
  NC.DMAX = 5;

  /** Dichtheidshistogram per kanaal, met rand (fractie) uitgesloten */
  NC.histogram = function (img, border) {
    const B = NC.HBINS, k = B / NC.DMAX;
    const hist = [new Uint32Array(B), new Uint32Array(B), new Uint32Array(B)];
    const x0 = Math.floor(img.w * border), x1 = img.w - x0;
    const y0 = Math.floor(img.h * border), y1 = img.h - y0;
    const d = img.data, hi = MAXV * 0.985;
    let total = 0;
    for (let y = y0; y < y1; y++) {
      let i = (y * img.w + x0) * 3;
      for (let x = x0; x < x1; x++, i += 3) {
        const r = d[i], g = d[i + 1], b = d[i + 2];
        // Overslaan: doorzon (perforatie, lichtlek) en volledig zwart (houder)
        if ((r >= hi && g >= hi && b >= hi) || (r < 3 && g < 3 && b < 3)) continue;
        hist[0][Math.min(B - 1, (DLUT[r] * k) | 0)]++;
        hist[1][Math.min(B - 1, (DLUT[g] * k) | 0)]++;
        hist[2][Math.min(B - 1, (DLUT[b] * k) | 0)]++;
        total++;
      }
    }
    return { hist, total };
  };

  NC.mergeHistograms = function (list) {
    const B = NC.HBINS;
    const hist = [new Uint32Array(B), new Uint32Array(B), new Uint32Array(B)];
    let total = 0;
    for (const h of list) {
      for (let c = 0; c < 3; c++) for (let i = 0; i < B; i++) hist[c][i] += h.hist[c][i];
      total += h.total;
    }
    return { hist, total };
  };

  function percentile(h, total, p) {
    const target = total * p;
    let acc = 0;
    for (let i = 0; i < h.length; i++) {
      acc += h[i];
      if (acc >= target) return (i + 0.5) * NC.DMAX / NC.HBINS;
    }
    return NC.DMAX;
  }

  /**
   * lo = dunste punt (schaduwen), hi = dichtste punt (hooglichten), per kanaal.
   * Met een gekozen filmbasis wordt die als zwartpunt gebruikt.
   */
  NC.analyze = function (H, base, clipLo, clipHi) {
    clipLo = clipLo == null ? 0.002 : clipLo;
    clipHi = clipHi == null ? 0.002 : clipHi;
    const lo = [0, 0, 0], hi = [0, 0, 0];
    for (let c = 0; c < 3; c++) {
      if (!H || H.total === 0) { lo[c] = 0.2; hi[c] = 2.0; continue; }
      lo[c] = percentile(H.hist[c], H.total, clipLo);
      hi[c] = percentile(H.hist[c], H.total, 1 - clipHi);
    }
    if (base && H && H.total) {
      // Filmbasis bepaalt de kleurbalans in de schaduwen; het zwartpunt
      // ligt voor alle kanalen op dezelfde fractie tussen basis en hooglicht.
      let f = 0;
      for (let c = 0; c < 3; c++) f += Math.max(0, (lo[c] - base[c]) / Math.max(0.05, hi[c] - base[c]));
      f /= 3;
      for (let c = 0; c < 3; c++) lo[c] = base[c] + f * (hi[c] - base[c]);
    }
    for (let c = 0; c < 3; c++) if (hi[c] - lo[c] < 0.05) hi[c] = lo[c] + 0.05;
    return { lo, hi };
  };

  /** Gemiddelde dichtheid rond (x, y) in bronpixels */
  NC.sampleDensity = function (img, x, y, r) {
    const s = [0, 0, 0];
    let n = 0;
    for (let yy = Math.max(0, y - r); yy <= Math.min(img.h - 1, y + r); yy++) {
      for (let xx = Math.max(0, x - r); xx <= Math.min(img.w - 1, x + r); xx++) {
        const i = (yy * img.w + xx) * 3;
        for (let c = 0; c < 3; c++) s[c] += img.data[i + c];
        n++;
      }
    }
    return s.map((v) => -Math.log10(Math.max(v / n, 1) / MAXV));
  };

  // ---------- Instellingen → parameters ----------

  NC.defaults = function () {
    return {
      exposure: 0,   // -100..100
      contrast: 30,  // 0..100
      mid: 0,        // -100..100 (middentonen / gamma)
      black: 0,      // -50..50
      white: 0,      // -50..50
      temp: 0,       // -100..100
      tint: 0,       // -100..100
      sat: 100,      // 0..200
      bw: false,
      base: null,    // [D_r, D_g, D_b] van gekozen filmbasis
      wb: [0, 0, 0], // correctie uit neutraal-kiezer (in n-eenheden)
      rot: 0,        // 0, 90, 180, 270 (rechtsom)
      flip: false,
    };
  };

  const NMIN = -1, NMAX = 2, CURVE_N = 32768;
  const CSCALE = (CURVE_N - 1) / (NMAX - NMIN);

  NC.buildParams = function (an, s) {
    const T = 0.0015;
    const off = [
      s.exposure * 0.003 + s.wb[0] + s.temp * T,
      s.exposure * 0.003 + s.wb[1] - s.tint * T,
      s.exposure * 0.003 + s.wb[2] - s.temp * T,
    ];
    const scale = [0, 1, 2].map((c) => 1 / (an.hi[c] - an.lo[c]));

    // Papiercurve: n (log-belichting, 0..1) → lineair licht over ~2 log-eenheden
    // (zoals een afdruk), dan sRGB, dan een S-curve voor contrast en gamma.
    const R = 2.0, floor = Math.pow(10, -R);
    const bp = s.black / 200, wp = 1 + s.white / 200;
    const k = 0.01 + s.contrast * 0.08;
    const sig = (x) => 1 / (1 + Math.exp(-k * (x - 0.5)));
    const s0 = sig(0), s1 = sig(1);
    const g = Math.pow(2, s.mid / 100);
    const curve = new Float32Array(CURVE_N);
    for (let i = 0; i < CURVE_N; i++) {
      const n = NMIN + i / CSCALE;
      const x = (n - bp) / (wp - bp);
      let lin = (Math.pow(10, (x - 1) * R) - floor) / (1 - floor);
      lin = lin <= 0 ? 0 : lin >= 1 ? 1 : lin;
      let y = lin <= 0.0031308 ? lin * 12.92 : 1.055 * Math.pow(lin, 1 / 2.4) - 0.055;
      y = (sig(y) - s0) / (s1 - s0);
      y = y <= 0 ? 0 : y >= 1 ? 1 : Math.pow(y, 1 / g);
      curve[i] = y;
    }
    return { lo: an.lo, scale, off, curve, sat: s.sat / 100, bw: s.bw };
  };

  /**
   * Render naar RGBA 8-bit (bits=8, out = Uint8ClampedArray w*h*4)
   * of RGB 16-bit (bits=16, out = Uint16Array w*h*3). Geen oriëntatie.
   * invert=false toont het ruwe negatief (voor vergelijking).
   */
  NC.render = function (img, P, out, bits, rawNegative) {
    const d = img.data, n = img.w * img.h, curve = P.curve;
    const loR = P.lo[0], loG = P.lo[1], loB = P.lo[2];
    const sR = P.scale[0], sG = P.scale[1], sB = P.scale[2];
    const oR = P.off[0], oG = P.off[1], oB = P.off[2];
    const sat = P.sat, bw = P.bw, doSat = !bw && Math.abs(sat - 1) > 1e-3;
    const top = CURVE_N - 1;
    const q = bits === 16 ? 65535 : 255;
    for (let p = 0; p < n; p++) {
      const i = p * 3;
      let r, g, b;
      if (rawNegative) {
        r = d[i] / 65535; g = d[i + 1] / 65535; b = d[i + 2] / 65535;
        r = Math.pow(r, 1 / 2.2); g = Math.pow(g, 1 / 2.2); b = Math.pow(b, 1 / 2.2);
      } else {
        let nr = (DLUT[d[i]] - loR) * sR + oR;
        let ng = (DLUT[d[i + 1]] - loG) * sG + oG;
        let nb = (DLUT[d[i + 2]] - loB) * sB + oB;
        if (bw) nr = ng = nb = 0.25 * nr + 0.5 * ng + 0.25 * nb;
        let ir = ((nr - NMIN) * CSCALE) | 0, ig = ((ng - NMIN) * CSCALE) | 0, ib = ((nb - NMIN) * CSCALE) | 0;
        r = curve[ir < 0 ? 0 : ir > top ? top : ir];
        g = curve[ig < 0 ? 0 : ig > top ? top : ig];
        b = curve[ib < 0 ? 0 : ib > top ? top : ib];
        if (doSat) {
          const l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
          r = l + (r - l) * sat; g = l + (g - l) * sat; b = l + (b - l) * sat;
          r = r < 0 ? 0 : r > 1 ? 1 : r;
          g = g < 0 ? 0 : g > 1 ? 1 : g;
          b = b < 0 ? 0 : b > 1 ? 1 : b;
        }
      }
      if (bits === 16) {
        out[i] = r * q + 0.5; out[i + 1] = g * q + 0.5; out[i + 2] = b * q + 0.5;
      } else {
        const o = p * 4;
        out[o] = r * q + 0.5; out[o + 1] = g * q + 0.5; out[o + 2] = b * q + 0.5; out[o + 3] = 255;
      }
    }
    return out;
  };

  /** n-waarden (zonder wb/temp/tint) bij een dichtheid — voor de neutraal-kiezer */
  NC.normalized = function (an, D) {
    return [0, 1, 2].map((c) => (D[c] - an.lo[c]) / (an.hi[c] - an.lo[c]));
  };

  // ---------- Oriëntatie ----------

  /** Doelpixel → bronpixel. Eerst horizontaal spiegelen, dan rechtsom draaien. */
  NC.destToSrc = function (xd, yd, w, h, rot, flip) {
    let fx, fy;
    if (rot === 90) { fx = yd; fy = h - 1 - xd; }
    else if (rot === 180) { fx = w - 1 - xd; fy = h - 1 - yd; }
    else if (rot === 270) { fx = w - 1 - yd; fy = xd; }
    else { fx = xd; fy = yd; }
    return [flip ? w - 1 - fx : fx, fy];
  };

  NC.orientedSize = function (w, h, rot) {
    return rot === 90 || rot === 270 ? [h, w] : [w, h];
  };

  /** Buffer (ch kanalen per pixel) heroriënteren */
  NC.transform = function (buf, w, h, ch, rot, flip) {
    if (!rot && !flip) return { buf, w, h };
    const [W, H] = NC.orientedSize(w, h, rot);
    const out = new buf.constructor(W * H * ch);
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const [sx, sy] = NC.destToSrc(x, y, w, h, rot, flip);
        const si = (sy * w + sx) * ch, di = (y * W + x) * ch;
        for (let c = 0; c < ch; c++) out[di + c] = buf[si + c];
      }
    }
    return { buf: out, w: W, h: H };
  };

  // ---------- TIFF schrijven (16-bit RGB, ongecomprimeerd) ----------

  NC.encodeTIFF16 = function (rgb, w, h) {
    const entries = [
      [256, 4, 1, w],          // ImageWidth
      [257, 4, 1, h],          // ImageLength
      [258, 3, 3, null],       // BitsPerSample → offset
      [259, 3, 1, 1],          // Compression: geen
      [262, 3, 1, 2],          // Photometric: RGB
      [273, 4, 1, null],       // StripOffsets → data
      [274, 3, 1, 1],          // Orientation
      [277, 3, 1, 3],          // SamplesPerPixel
      [278, 4, 1, h],          // RowsPerStrip
      [279, 4, 1, w * h * 6],  // StripByteCounts
      [284, 3, 1, 1],          // PlanarConfiguration
      [305, 2, 0, null],       // Software
    ];
    const software = 'scan-workflow negatief-converter\0';
    entries[11][2] = software.length;
    const ifdSize = 2 + entries.length * 12 + 4;
    const bpsOff = 8 + ifdSize;
    const swOff = bpsOff + 6;
    let dataOff = swOff + software.length;
    dataOff += dataOff % 2;
    const total = dataOff + w * h * 6;
    const buf = new ArrayBuffer(total);
    const v = new DataView(buf);
    v.setUint8(0, 0x49); v.setUint8(1, 0x49); v.setUint16(2, 42, true); v.setUint32(4, 8, true);
    v.setUint16(8, entries.length, true);
    entries.forEach(([tag, type, count, val], k) => {
      const o = 10 + k * 12;
      v.setUint16(o, tag, true); v.setUint16(o + 2, type, true); v.setUint32(o + 4, count, true);
      if (tag === 258) v.setUint32(o + 8, bpsOff, true);
      else if (tag === 273) v.setUint32(o + 8, dataOff, true);
      else if (tag === 305) v.setUint32(o + 8, swOff, true);
      else if (type === 3) v.setUint16(o + 8, val, true);
      else v.setUint32(o + 8, val, true);
    });
    v.setUint32(10 + entries.length * 12, 0, true);
    for (let c = 0; c < 3; c++) v.setUint16(bpsOff + c * 2, 16, true);
    for (let i = 0; i < software.length; i++) v.setUint8(swOff + i, software.charCodeAt(i));
    new Uint16Array(buf, dataOff, w * h * 3).set(rgb); // little-endian hosts
    return new Uint8Array(buf);
  };

  // ---------- ZIP (opslaan, geen compressie) ----------

  const CRC = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    CRC[n] = c >>> 0;
  }
  NC.crc32 = function (u8) {
    let c = 0xffffffff;
    for (let i = 0; i < u8.length; i++) c = CRC[(c ^ u8[i]) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };

  /** Bouwt een ZIP-archief. Geeft een lijst onderdelen (Uint8Arrays) terug. */
  NC.zipParts = function (files) { // [{name, data: Uint8Array}]
    const parts = [], central = [];
    let offset = 0;
    for (const f of files) {
      const name = new TextEncoder().encode(f.name);
      const crc = NC.crc32(f.data), size = f.data.length;
      const lh = new DataView(new ArrayBuffer(30));
      lh.setUint32(0, 0x04034b50, true); lh.setUint16(4, 20, true); lh.setUint16(6, 0x0800, true);
      lh.setUint16(8, 0, true); lh.setUint32(14, crc, true);
      lh.setUint32(18, size, true); lh.setUint32(22, size, true); lh.setUint16(26, name.length, true);
      parts.push(new Uint8Array(lh.buffer), name, f.data);
      const ch = new DataView(new ArrayBuffer(46));
      ch.setUint32(0, 0x02014b50, true); ch.setUint16(4, 20, true); ch.setUint16(6, 20, true);
      ch.setUint16(8, 0x0800, true); ch.setUint32(16, crc, true);
      ch.setUint32(20, size, true); ch.setUint32(24, size, true); ch.setUint16(28, name.length, true);
      ch.setUint32(42, offset, true);
      central.push(new Uint8Array(ch.buffer), name);
      offset += 30 + name.length + size;
    }
    const cdSize = central.reduce((a, b) => a + b.length, 0);
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true);
    end.setUint16(8, files.length, true); end.setUint16(10, files.length, true);
    end.setUint32(12, cdSize, true); end.setUint32(16, offset, true);
    return parts.concat(central, [new Uint8Array(end.buffer)]);
  };

  if (typeof module === 'object' && module.exports) module.exports = NC;
  else root.NC = NC;
})(typeof self !== 'undefined' ? self : this);
