import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { FrameGate, opaqueBounds, BoundsFollower } = require('../../app/assets/companion/float.js');

// The plain full scan the float window used to run every frame.
function reference(rgba, width, height) {
  let left = width, bottom = height, right = 0, top = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (rgba[(y * width + x) * 4 + 3] === 0) continue;
      left = Math.min(left, x);
      right = Math.max(right, x + 1);
      bottom = Math.min(bottom, y);
      top = Math.max(top, y + 1);
    }
  }
  return right > left ? { left, top: height - top, right, bottom: height - bottom } : null;
}

function seeded(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

test('opaqueBounds finds the same box as a full scan', () => {
  const random = seeded(7);
  for (let round = 0; round < 400; round++) {
    const width = 1 + Math.floor(random() * 40);
    const height = 1 + Math.floor(random() * 40);
    const rgba = new Uint8Array(width * height * 4);
    // Mostly empty, a blob or a few stray pixels, colour without alpha now and then.
    const dots = Math.floor(random() * 6);
    for (let d = 0; d < dots; d++) {
      const x = Math.floor(random() * width), y = Math.floor(random() * height);
      const w = 1 + Math.floor(random() * 8), h = 1 + Math.floor(random() * 8);
      for (let yy = y; yy < Math.min(height, y + h); yy++) {
        for (let xx = x; xx < Math.min(width, x + w); xx++) {
          const i = (yy * width + xx) * 4;
          rgba[i] = 255;
          rgba[i + 3] = random() < 0.8 ? 1 + Math.floor(random() * 255) : 0;
        }
      }
    }
    assert.deepEqual(opaqueBounds(rgba, width, height), reference(rgba, width, height), `round ${round}`);
  }
});

test('opaqueBounds reads a view that does not start on a word', () => {
  const width = 5, height = 4;
  const backing = new Uint8Array(width * height * 4 + 1);
  const rgba = backing.subarray(1);
  rgba[(2 * width + 3) * 4 + 3] = 1;
  assert.deepEqual(opaqueBounds(rgba, width, height), reference(rgba, width, height));
  assert.equal(opaqueBounds(new Uint8Array(0), 0, 0), null);
});

test('the window follows her outline loosely', () => {
  const follow = new BoundsFollower();
  const at = (left, top, right, bottom) => ({ left, top, right, bottom });
  // 640 tall: ten pixels to spare on each side, kept until she is thirty clear of one.
  const first = follow.next(at(100, 50, 380, 600), 480, 640);
  assert.deepEqual(first, at(90, 40, 390, 610));
  // Breathing: a pixel or two either way moves nothing.
  for (const box of [at(99, 49, 381, 601), at(101, 52, 379, 599), at(92, 42, 388, 608)]) {
    assert.equal(follow.next(box, 480, 640), undefined);
  }
  // An arm past the edge: grows at once, with room to spare again.
  assert.deepEqual(follow.next(at(100, 50, 395, 600), 480, 640), at(90, 40, 405, 610));
  // Drawn back in, but not far: stays.
  assert.equal(follow.next(at(100, 50, 380, 600), 480, 640), undefined);
  // Well clear of the right edge: shrinks to her again.
  assert.deepEqual(follow.next(at(100, 50, 370, 600), 480, 640), at(90, 40, 380, 610));
  // Never past the buffer.
  assert.deepEqual(follow.next(at(0, 0, 480, 640), 480, 640), at(0, 0, 480, 640));
});

test('the window hears once when she is gone and again on a new buffer size', () => {
  const follow = new BoundsFollower();
  assert.equal(follow.next(null, 480, 640), null);
  assert.equal(follow.next(null, 480, 640), undefined);
  const box = follow.next({ left: 10, top: 10, right: 20, bottom: 20 }, 480, 640);
  assert.ok(box);
  assert.equal(follow.next(null, 480, 640), null);
  assert.ok(follow.next({ left: 10, top: 10, right: 20, bottom: 20 }, 480, 640));
  // Same outline, new buffer: box coordinates mean something else now.
  assert.ok(follow.next({ left: 10, top: 10, right: 20, bottom: 20 }, 360, 480));
  assert.equal(follow.next(null, 360, 480), null);
  assert.equal(follow.next(null, 240, 320), null);
});

test('the frame gate keeps the rate it is asked for', () => {
  const count = (fps, hz) => {
    const gate = new FrameGate();
    let taken = 0;
    for (let i = 0; i < hz * 10; i++) if (gate.take((i * 1000) / hz, fps)) taken++;
    return taken / 10;
  };
  for (const hz of [60, 90, 120]) {
    assert.equal(count(30, hz), 30, `30 on ${hz} Hz`);
    assert.ok(Math.abs(count(12, hz) - 12) <= 1, `12 on ${hz} Hz`);
  }
  assert.equal(new FrameGate().take(Number.NaN), false);
});
