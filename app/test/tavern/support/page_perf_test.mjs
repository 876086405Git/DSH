// Runs the cards' pages' lightening helpers (tavern_page_perf.dart:
// dshOffscreen; tavern_page_perf_test.dart writes them to
// the file DSH_PAGE_SCRIPTS names) on a bare global with just enough of a
// page, and checks what they do.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const scripts = JSON.parse(readFileSync(process.env.DSH_PAGE_SCRIPTS, 'utf8'));

function page(extra = {}) {
  const window = { console, ...extra };
  window.window = window;
  vm.createContext(window);
  for (const code of Object.values(scripts)) vm.runInContext(code, window);
  return window;
}

/** An element as far as the helpers look: classes, its media, a style. */
function element(media = []) {
  const classes = new Set();
  return {
    classList: {
      contains: (c) => classes.has(c),
      toggle: (c, on) => (on ? classes.add(c) : classes.delete(c)),
    },
    querySelectorAll: () => media,
    get off() {
      return classes.has('dsh-off');
    },
  };
}

function medium(playing) {
  return {
    paused: !playing,
    plays: 0,
    pause() {
      this.paused = true;
    },
    play() {
      this.paused = false;
      this.plays++;
      return Promise.resolve();
    },
  };
}

function observed() {
  const observers = [];
  class IntersectionObserver {
    constructor(callback, options) {
      this.callback = callback;
      this.options = options;
      this.targets = new Set();
      observers.push(this);
    }
    observe(t) {
      this.targets.add(t);
    }
    unobserve(t) {
      this.targets.delete(t);
    }
    tell(target, isIntersecting) {
      this.callback([{ target, isIntersecting }]);
    }
  }
  return { observers, IntersectionObserver };
}

test('dshOffscreen: one observer, a screen of margin; out of sight is off, the tail never', () => {
  const { observers, IntersectionObserver } = observed();
  const w = page({ IntersectionObserver });
  const sight = vm.runInContext('dshOffscreen()', w);
  assert.equal(observers.length, 1);
  assert.equal(observers[0].options.rootMargin, '100% 0px');
  const old = element();
  const tail = element();
  sight.watch(old, false);
  sight.watch(tail, true);
  // Not heard of yet: off, unless it is the tail.
  assert.equal(old.off, true);
  assert.equal(tail.off, false);
  assert.equal(observers[0].targets.size, 2);
  observers[0].tell(old, true);
  assert.equal(old.off, false);
  observers[0].tell(old, false);
  assert.equal(old.off, true);
  observers[0].tell(tail, false);
  assert.equal(tail.off, false);
  // No longer the tail (a newer message came): out of sight, it goes off.
  sight.watch(tail, false);
  assert.equal(tail.off, true);
  // Watched again, it is not observed twice; gone, it is not observed.
  sight.watch(old, false);
  assert.equal(observers[0].targets.size, 2);
  sight.unwatch(old);
  assert.equal(observers[0].targets.size, 1);
});

test('dshOffscreen: playing media pause out of sight and go on when back; paused ones stay', () => {
  const { observers, IntersectionObserver } = observed();
  const w = page({ IntersectionObserver });
  const sight = vm.runInContext('dshOffscreen()', w);
  const video = medium(true);
  const still = medium(false);
  const m = element([video, still]);
  sight.watch(m, false);
  observers[0].tell(m, true);
  assert.equal(video.paused, false);
  const plays = video.plays;
  observers[0].tell(m, false);
  assert.equal(video.paused, true);
  observers[0].tell(m, true);
  assert.equal(video.paused, false);
  assert.equal(video.plays, plays + 1);
  assert.equal(still.paused, true);
  assert.equal(still.plays, 0);
});
