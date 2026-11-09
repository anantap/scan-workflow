/*
 * The bridge between the Mac app (Swift, JavaScriptCore) and the converter's maths.
 *
 * Loaded after pako, UTIF, converter-core.js (NC) and compositor/burke-core.js (BurkeCore).
 * Swift passes each scan's file bytes in as an ArrayBuffer; the analyses of the roll's frames stay
 * here between calls, so only images cross over. The rendered positive is left in `Engine.out`
 * (and, for a Compositor project, the scan as Compositor stores it in `Engine.outScan`) for Swift
 * to copy out; `release` drops them.
 */
var Engine = (function () {
  'use strict';

  var BC = typeof BurkeCore === 'function' ? BurkeCore(NC) : BurkeCore;
  var frames = {};
  var roll = null;
  var nextID = 1;

  function load(buffer, width, height, rgba) {
    return rgba ? NC.fromRGBA8(new Uint8Array(buffer), width, height) : NC.decodeTIFF(buffer, UTIF);
  }

  function settings(o) {
    var s = NC.defaults();
    s.positive = o.film === 'positive';
    s.bw = o.film === 'bw';
    if (typeof o.exposure === 'number') s.exposure = o.exposure;
    if (typeof o.contrast === 'number') s.contrast = o.contrast;
    return s;
  }

  return {
    out: null,
    outScan: null,

    /** Measures one scan. Returns JSON: its id for `render`, its size, and whether it has an orange mask. */
    analyze: function (buffer, width, height, rgba, optionsJSON) {
      var o = JSON.parse(optionsJSON);
      var full = load(buffer, width, height, rgba);
      var preview = NC.downscale(full, 1600);
      var hist = NC.histogram(preview, 0.08);
      var frame = {
        hist: hist,
        base: o.film === 'positive' ? null : NC.estimateBase(preview),
        mask: NC.maskStrength(hist),
        burke: o.film === 'color' && o.compositor ? BC.analyzePreview(preview, {}) : null,
      };
      var id = nextID++;
      frames[id] = frame;
      return JSON.stringify({ id: id, width: full.w, height: full.h, masked: frame.mask >= 0.15 });
    },

    /** One colour balance for these frames together (the whole roll). */
    makeRoll: function (idsJSON) {
      var list = JSON.parse(idsJSON).map(function (id) { return frames[id]; });
      var burke = list.every(function (f) { return f.burke; });
      roll = {
        hist: NC.mergeHistograms(list.map(function (f) { return f.hist; })),
        burkeH: burke ? BC.mergeHist(list.map(function (f) { return f.burke.H; })) : null,
      };
    },

    /**
     * Converts one scan, measured before by `analyze`. Leaves the positive (16-bit sRGB RGB) in `out`.
     * With `layerIDs` (six uppercase UUIDs) and `documentID`, also a Compositor project with Alex
     * Burke's layers: its manifest in the result, the scan layer's pixels in `outScan`.
     */
    render: function (id, buffer, width, height, rgba, optionsJSON, useRoll, layerIDsJSON, documentID) {
      var o = JSON.parse(optionsJSON);
      var frame = frames[id];
      var full = load(buffer, width, height, rgba);
      var analysis = NC.analyze(useRoll && roll ? roll.hist : frame.hist, frame.base);
      var rgb = new Uint16Array(full.w * full.h * 3);
      NC.render(full, NC.buildParams(analysis, settings(o)), rgb, 16, false);
      this.out = rgb;
      this.outScan = null;
      var result = { width: full.w, height: full.h, dpi: full.dpi || null };
      if (frame.burke && layerIDsJSON) {
        var H = useRoll && roll && roll.burkeH ? roll.burkeH : frame.burke.H;
        var built = BC.buildLayers(full.w, full.h, H, frame.burke.baseInverted, JSON.parse(layerIDsJSON), {});
        result.manifest = BC.manifest(documentID, full.w, full.h, full.dpi, built);
        result.baseColor = frame.burke.baseInverted;
        this.outScan = BC.encodedScan(full);
      }
      return JSON.stringify(result);
    },

    release: function () {
      this.out = null;
      this.outScan = null;
    },

    forget: function () {
      frames = {};
      roll = null;
      this.release();
    },
  };
})();
