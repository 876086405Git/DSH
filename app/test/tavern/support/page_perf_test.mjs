// Runs the cards' pages' lightening helpers (tavern_page_perf.dart:
// dshOffscreen, dshCalm, dshPerf; tavern_page_perf_test.dart writes them to
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

test('dshCalm: blur and backdrop blur go, other filters stay, endless animations play once', () => {
  const style = (s) => ({ filter: '', backdropFilter: '', animationIterationCount: '', ...s });
  const glass = style({ backdropFilter: 'blur(12px) saturate(1.4)', filter: 'blur(4px) brightness(1.2)' });
  const pulse = style({ animationIterationCount: 'infinite, 2' });
  const frame = style({ filter: 'blur(2px)' });
  const keep = style({ filter: 'drop-shadow(0 0 2px red)', animationIterationCount: '3' });
  const inline = style({ filter: 'blur(1px)' });
  let readsOfLocked = 0;
  const sheets = [
    { cssRules: [{ style: glass }, { cssRules: [{ style: pulse }] }, { cssRules: [{ style: frame }] }, { style: keep }] },
    {
      get cssRules() {
        readsOfLocked++;
        throw new Error('SecurityError');
      },
    },
  ];
  let asked = null;
  const w = page({
    document: {
      styleSheets: sheets,
      querySelectorAll: (q) => {
        asked = q;
        return [{ style: inline }];
      },
    },
  });
  vm.runInContext('dshCalm()', w);
  assert.equal(glass.backdropFilter, 'none');
  assert.equal(glass.filter, 'brightness(1.2)');
  assert.equal(pulse.animationIterationCount, '1, 2');
  assert.equal(frame.filter, 'none');
  assert.deepEqual(keep, style({ filter: 'drop-shadow(0 0 2px red)', animationIterationCount: '3' }));
  assert.equal(inline.filter, 'none');
  assert.match(asked, /\[style\*="blur"\]/);
  // A sheet is gone through once.
  glass.backdropFilter = 'blur(1px)';
  vm.runInContext('dshCalm()', w);
  assert.equal(glass.backdropFilter, 'blur(1px)');
  assert.equal(readsOfLocked, 1);
  // Under a root: only its inline styles are looked at.
  let rootAsked = false;
  vm.runInContext('dshCalm', w)({ querySelectorAll: () => ((rootAsked = true), []) });
  assert.equal(rootAsked, true);
});

test('dshPerf: frames, those over 50 ms, the longest, every 5 s; nothing for a span without frames', () => {
  let frame = null;
  let every = null;
  let now = 0;
  const posted = [];
  const w = page({
    performance: { now: () => now },
    requestAnimationFrame: (f) => {
      frame = f;
    },
    setInterval: (f, ms) => {
      every = { f, ms };
    },
  });
  vm.runInContext('dshPerf', w)(
    (o) => posted.push(JSON.parse(JSON.stringify(o))),
    () => ({ mes: 3 }),
  );
  assert.equal(every.ms, 5000);
  for (const t of [16, 32, 48, 130, 146, 2000, 2016]) frame(t);
  now = 5000;
  every.f();
  // 2000 after 146 is a pause, not a frame.
  assert.deepEqual(posted, [{ type: 'perf', span: 5000, frames: 5, long: 1, worst: 82, mes: 3 }]);
  now = 10000;
  every.f();
  assert.equal(posted.length, 1);
});

test("dshScope: a page's html, body and :root styles stay in its message", () => {
  const w = page();
  const rule = (selectorText, inner) => ({ selectorText, ...(inner ? { cssRules: inner } : {}) });
  const rules = [
    rule('html, body'),
    rule('body'),
    rule('body.dark .card > p'),
    rule(':root'),
    rule('.tbody, #body, .x body-y'),
    { cssRules: [rule('body')] }, // an @media block
    rule('html body .card'),
    rule('html > body'),
    rule(':root body, body'),
    rule('body, dsh-letter::part(body)'),
    rule(':is(body) .x'),
  ];
  const box = {
    dataset: {},
    classList: { contains: (c) => c === 'mes_text' },
    querySelectorAll: () => [{ sheet: { cssRules: rules } }],
  };
  vm.runInContext('dshScope', w)(box);
  const at = `.mes_text[data-dsh-scope="${box.dataset.dshScope}"]`;
  assert.equal(rules[0].selectorText, `${at}, ${at}`);
  assert.equal(rules[1].selectorText, at);
  assert.equal(rules[2].selectorText, `${at}.dark .card > p`);
  assert.equal(rules[3].selectorText, at);
  assert.equal(rules[4].selectorText, '.tbody, #body, .x body-y'); // not the element names
  assert.equal(rules[5].cssRules[0].selectorText, at);
  // html body, html > body and :root body are one root here, not one inside another.
  assert.equal(rules[6].selectorText, `${at} .card`);
  assert.equal(rules[7].selectorText, at);
  assert.equal(rules[8].selectorText, `${at}, ${at}`);
  // A ::part() argument is a part's name, not the page's body.
  assert.equal(rules[9].selectorText, `${at}, dsh-letter::part(body)`);
  assert.equal(rules[10].selectorText, `:is(${at}) .x`);
  // A sheet already done is left as it is.
  vm.runInContext('dshScope', w)(box);
  assert.equal(rules[1].selectorText, at);
});
