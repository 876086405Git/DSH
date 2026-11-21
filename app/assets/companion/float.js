// Float-only contracts, shared by the real stage and its Node tests.
// No model assets, browser emulation or GPU claims in the pure tests.
(() => {
  'use strict';

  class FrameGate {
    constructor() { this.last = -Infinity; }
    take(time, fps = 30) {
      // The 2ms slack is for rAF jitter: on 60, 90 and 120 Hz a 30 fps frame is a whole
      // number of refreshes, and a timestamp a hair early would otherwise skip to the next
      // one and land at 20–24 fps. Same allowance as the room's render loop.
      if (!Number.isFinite(time) || time - this.last < 1000 / fps - 2) return false;
      this.last = time;
      return true;
    }
  }

  // Whichever byte order the phone has, the word whose alpha byte alone is set.
  const ALPHA = new Uint32Array(new Uint8Array([0, 0, 0, 255]).buffer)[0];

  // readPixels starts at the bottom-left; the native window uses top-left.
  // Even alpha=1 counts. A mesh's vertices do not prove pixel opacity.
  // Every frame in the float window: rows come in from the top and bottom until
  // one is drawn on, then each row in between only from its ends inward to the
  // sides found so far, so the inside of her is never read.
  function opaqueBounds(rgba, width, height) {
    if (!(width > 0 && height > 0)) return null;
    const words = rgba.byteOffset % 4 === 0
      ? new Uint32Array(rgba.buffer, rgba.byteOffset, width * height)
      : new Uint32Array(Uint8Array.from(rgba.subarray(0, width * height * 4)).buffer);
    const rowDrawn = (y) => {
      for (let i = y * width, end = i + width; i < end; i++) if (words[i] & ALPHA) return true;
      return false;
    };
    let bottom = 0;
    while (bottom < height && !rowDrawn(bottom)) bottom++;
    if (bottom === height) return null;
    let top = height;
    while (!rowDrawn(top - 1)) top--;
    let left = width, right = 0;
    for (let y = bottom; y < top; y++) {
      const row = y * width;
      for (let x = 0; x < left; x++) if (words[row + x] & ALPHA) { left = x; break; }
      for (let x = width - 1; x >= right; x--) if (words[row + x] & ALPHA) { right = x + 1; break; }
    }
    return { left, top: height - top, right, bottom: height - bottom };
  }

  // The native window around her moves with every box it is given (a relayout
  // of the window and the WebView in it), and her outline shifts a pixel or two
  // in nearly every frame she breathes. So the window follows loosely: when she
  // reaches past it, it grows at once to her outline and a little room to spare;
  // it shrinks back only once she has drawn in well clear of that.
  class BoundsFollower {
    constructor() { this.width = 0; this.height = 0; this.box = undefined; }
    // The box for the window when it has to change, else undefined.
    next(bounds, width, height) {
      const resized = width !== this.width || height !== this.height;
      this.width = width;
      this.height = height;
      if (!bounds) {
        if (!resized && this.box === null) return undefined;
        this.box = null;
        return null;
      }
      const pad = Math.max(2, Math.round(Math.max(width, height) * 0.015));
      const box = this.box;
      const inside = !resized && box != null &&
        bounds.left >= box.left && bounds.top >= box.top && bounds.right <= box.right && bounds.bottom <= box.bottom;
      const loose = inside && (bounds.left - box.left > pad * 3 || bounds.top - box.top > pad * 3 ||
        box.right - bounds.right > pad * 3 || box.bottom - bounds.bottom > pad * 3);
      if (inside && !loose) return undefined;
      this.box = {
        left: Math.max(0, bounds.left - pad),
        top: Math.max(0, bounds.top - pad),
        right: Math.min(width, bounds.right + pad),
        bottom: Math.min(height, bounds.bottom + pad),
      };
      return this.box;
    }
  }

  const states = {
    idle: ['calm', null], thinking: ['confused', 'tilt'],
    working: ['calm', 'nodSmall'], juggling: ['calm', 'nodSmall'],
    sweeping: ['calm', 'nodSmall'], carrying: ['calm', 'nodSmall'],
    attention: ['happy', 'nod'], notification: ['worried', 'lookUp'],
    error: ['sad', 'shake'], sleeping: ['sleepy', 'yawn'], waking: ['calm', 'stretch'],
  };

  // Only the character/adapter's authored mappings opt a state into effects.
  // The room's generic ACTIONS/DEFAULT_EMOTIONS are deliberately not evidence.
  function stateEffect(state, emotions, actions) {
    const owns = (object, key) => object != null && Object.prototype.hasOwnProperty.call(object, key);
    const mappedEmotion = name => owns(emotions, name) && emotions[name] != null &&
      typeof emotions[name] === 'object' && !Array.isArray(emotions[name]);
    const mappedAction = name => owns(actions, name) && actions[name] != null &&
      typeof actions[name] === 'object' &&
      (typeof actions[name].motion === 'string' && actions[name].motion.length > 0 ||
       actions[name].tracks && typeof actions[name].tracks === 'object' &&
       Number.isFinite(actions[name].ms) && actions[name].ms > 0);
    const [emotion, action] = owns(states, state) ? states[state] : states.idle;
    return {
      emotion: mappedEmotion(emotion) ? emotion : 'calm',
      action: action && mappedAction(action) ? action : null,
      mood: state === 'sleeping' && mappedEmotion('sleepy') ? 'sleeping' : 'idle',
    };
  }

  const api = { FrameGate, opaqueBounds, BoundsFollower, stateEffect };
  if (typeof module !== 'undefined') module.exports = api;
  if (typeof window !== 'undefined') {
    window.CompanionFloat = api;
    if (new URLSearchParams(location.search).get('mode') === 'float') {
      document.documentElement.dataset.mode = 'float';
    }
  }
})();
