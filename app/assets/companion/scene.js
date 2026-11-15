// What floats around her: marine snow, and the little marks that say what she
// feels (hearts, a "!", a "?", Zzz). Drawn on one 2D canvas above the model, in
// the same frame as the model (stage.js calls `companionScene.step`). Coordinates
// are CSS pixels.
window.companionScene = (() => {
  'use strict';

  // The floating window draws only the character, without a second canvas.
  if (document.documentElement.dataset.mode === 'float') return null;

  const canvas = document.getElementById('fx');
  const ctx = canvas.getContext('2d');
  const requestedDpr = Number(new URLSearchParams(location.search).get('dpr'));
  const DPR_CAP = Number.isFinite(requestedDpr) && requestedDpr > 0 ? Math.min(2, Math.max(0.5, requestedDpr)) : 2;

  let width = 1;
  let height = 1;
  let dpr = 1;
  let glowing = false;
  let reduced = false;

  const rand = (lo, hi) => lo + Math.random() * (hi - lo);

  const motes = [];
  function seedMotes() {
    motes.length = 0;
    const count = reduced ? 0 : 26;
    for (let i = 0; i < count; i++) {
      const near = i % 7 === 0;
      motes.push({
        x: Math.random(),
        y: Math.random(),
        r: near ? rand(2.4, 4.2) : rand(0.6, 1.5),
        rise: near ? rand(0.012, 0.022) : rand(0.005, 0.012),
        sway: rand(6, 18),
        phase: rand(0, Math.PI * 2),
        alpha: near ? rand(0.1, 0.2) : rand(0.2, 0.55),
        near,
      });
    }
  }

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP);
    width = canvas.clientWidth || 1;
    height = canvas.clientHeight || 1;
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
  }

  // ── Marks ────────────────────────────────────────────────────────────────

  const sprites = [];
  const MAX_SPRITES = 40;

  function add(sprite) {
    if (sprites.length >= MAX_SPRITES) sprites.shift();
    sprites.push({ age: 0, rot: 0, spin: 0, vx: 0, vy: 0, gravity: 0, scale: 1, pop: true, ...sprite });
  }

  const heartPath = new Path2D('M0 -3.6C-1.4 -7 -7 -7.4 -8.6 -3.6C-10 -0.2 -7.6 3.2 0 8.4C7.6 3.2 10 -0.2 8.6 -3.6C7 -7.4 1.4 -7 0 -3.6Z');
  const starPath = new Path2D('M0 -9C1.2 -3 3 -1.2 9 0C3 1.2 1.2 3 0 9C-1.2 3 -3 1.2 -9 0C-3 -1.2 -1.2 -3 0 -9Z');
  const dropPath = new Path2D('M0 -8C3.4 -3 6 -0.4 6 3C6 6.4 3.3 8.8 0 8.8C-3.3 8.8 -6 6.4 -6 3C-6 -0.4 -3.4 -3 0 -8Z');
  const angerPath = new Path2D(
    'M-2.5 -9C-2.5 -5.5 -2 -3.5 -3.5 -3.5C-5 -3.5 -6.5 -3 -9.5 -3M2.5 -9C2.5 -5.5 2 -3.5 3.5 -3.5C5 -3.5 6.5 -3 9.5 -3M-2.5 9C-2.5 5.5 -2 3.5 -3.5 3.5C-5 3.5 -6.5 3 -9.5 3M2.5 9C2.5 5.5 2 3.5 3.5 3.5C5 3.5 6.5 3 9.5 3',
  );

  function drawSprite(s) {
    const fadeIn = Math.min(1, s.age / 0.14);
    const fadeOut = Math.min(1, (s.life - s.age) / Math.max(0.2, s.life * 0.4));
    ctx.globalAlpha = Math.max(0, Math.min(fadeIn, fadeOut)) * (s.alpha ?? 1);
    const grow = s.pop ? 1 + 0.35 * Math.max(0, 1 - s.age / 0.22) * Math.sin(Math.min(1, s.age / 0.22) * Math.PI) : 1;
    const appear = (s.pop ? Math.min(1, s.age / 0.12) : 1) * (s.shrink ? 1 - 0.35 * Math.max(0, (s.age / s.life - 0.7) / 0.3) : 1);
    ctx.save();
    ctx.translate(s.x, s.y);
    ctx.rotate(s.rot);
    ctx.scale(s.scale * grow * appear, s.scale * grow * appear);
    switch (s.kind) {
      case 'heart':
        ctx.fillStyle = '#ff7d9c';
        ctx.fill(heartPath);
        ctx.fillStyle = 'rgba(255,255,255,0.55)';
        ctx.beginPath();
        ctx.ellipse(-4.2, -3.2, 1.7, 1.1, -0.6, 0, Math.PI * 2);
        ctx.fill();
        break;
      case 'star':
        ctx.fillStyle = '#fff3b8';
        ctx.shadowColor = 'rgba(255,240,170,0.8)';
        ctx.shadowBlur = 8;
        ctx.fill(starPath);
        break;
      case 'drop':
        ctx.fillStyle = '#9fdcff';
        ctx.fill(dropPath);
        ctx.fillStyle = 'rgba(255,255,255,0.7)';
        ctx.beginPath();
        ctx.ellipse(-1.8, 2.8, 1.1, 1.8, 0.3, 0, Math.PI * 2);
        ctx.fill();
        break;
      case 'anger':
        ctx.strokeStyle = '#ff5f6b';
        ctx.lineWidth = 2.6;
        ctx.lineCap = 'round';
        ctx.stroke(angerPath);
        break;
      case 'ring':
        ctx.strokeStyle = 'rgba(226,246,255,0.85)';
        ctx.lineWidth = 1.4 / Math.max(0.3, s.scale);
        ctx.beginPath();
        ctx.arc(0, 0, 10, 0, Math.PI * 2);
        ctx.stroke();
        break;
      case 'snack': {
        ctx.fillStyle = s.color;
        ctx.strokeStyle = 'rgba(120, 72, 40, 0.55)';
        ctx.lineWidth = 1.2;
        ctx.beginPath();
        ctx.arc(0, 0, 7, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
        ctx.fillStyle = 'rgba(120, 72, 40, 0.5)';
        for (const [cx, cy] of [[-2.5, -1.5], [2, 1.5], [-0.5, 3]]) {
          ctx.beginPath();
          ctx.arc(cx, cy, 0.9, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.fillStyle = 'rgba(255,255,255,0.55)';
        ctx.beginPath();
        ctx.ellipse(-2.6, -3, 2, 1.1, -0.5, 0, Math.PI * 2);
        ctx.fill();
        break;
      }
      case 'dot':
        ctx.fillStyle = 'rgba(255,255,255,0.92)';
        ctx.beginPath();
        ctx.arc(0, 0, 4, 0, Math.PI * 2);
        ctx.fill();
        break;
      case 'glyph':
        ctx.font = '800 24px system-ui, "Noto Sans CJK SC", sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.lineJoin = 'round';
        ctx.lineWidth = 5;
        ctx.strokeStyle = 'rgba(255,255,255,0.95)';
        ctx.strokeText(s.text, 0, 0);
        ctx.fillStyle = s.color ?? '#2f6fd0';
        ctx.fillText(s.text, 0, 0);
        break;
    }
    ctx.restore();
  }

  // Each returns nothing; `x`, `y` is where the mark should appear.
  const marks = {
    hearts(x, y, count = 2) {
      for (let i = 0; i < count; i++) {
        add({
          kind: 'heart',
          x: x + rand(-26, 26),
          y: y + rand(-10, 10),
          vx: rand(-12, 12),
          vy: rand(-58, -38),
          scale: rand(0.75, 1.25),
          rot: rand(-0.3, 0.3),
          life: rand(1.1, 1.6),
        });
      }
    },
    sparkles(x, y, count = 3) {
      for (let i = 0; i < count; i++) {
        add({
          kind: 'star',
          x: x - 30 + rand(-58, 44),
          y: y + rand(-16, 34),
          vy: rand(-14, -4),
          scale: rand(0.55, 1.1),
          spin: rand(-1, 1),
          life: rand(0.7, 1.1),
        });
      }
    },
    exclaim(x, y) {
      add({ kind: 'glyph', text: '!', color: '#ff7a59', x, y, vy: -8, scale: 1.25, rot: 0.14, life: 1.3 });
    },
    question(x, y) {
      add({ kind: 'glyph', text: '?', color: '#3f7fe0', x, y, vy: -7, scale: 1.2, rot: 0.16, life: 1.7 });
    },
    anger(x, y) {
      add({ kind: 'anger', x, y: y + 8, scale: 1.5, life: 1.5 });
    },
    sweat(x, y) {
      add({ kind: 'drop', x: x + 6, y: y + 18, vy: 16, gravity: 34, scale: 1, life: 1.2 });
    },
    tear(x, y) {
      add({ kind: 'drop', x: x - 34 + rand(-22, 22), y: y + 44, vy: 22, gravity: 60, scale: 0.7, life: 0.9 });
    },
    zzz(x, y) {
      add({ kind: 'glyph', text: 'Z', color: '#6f8fe8', x, y, vx: 12, vy: -24, scale: rand(0.55, 0.85), rot: 0.2, life: 2.4 });
    },
    thought(x, y, step) {
      add({ kind: 'dot', x: x - 2 + step * 11, y: y + 8 - step * 11, scale: 0.55 + step * 0.32, life: 1.05, pop: true, alpha: 0.95 });
    },
    note(x, y) {
      add({ kind: 'glyph', text: '♪', color: '#6f8ff0', x: x + rand(-6, 10), y, vx: rand(10, 22), vy: rand(-30, -22), scale: rand(0.65, 0.9), rot: rand(-0.2, 0.2), spin: rand(-0.6, 0.6), life: 1.9 });
    },
    /** A snack that floats from [from] to [to] along a soft arc, shrinking at the end. */
    snack(from, to, color) {
      const mid = [(from[0] + to[0]) / 2 + 30, Math.min(from[1], to[1]) - 70];
      add({
        kind: 'snack',
        color,
        life: 1.35,
        pop: true,
        path: (t) => {
          const k = t * t * (3 - 2 * t);
          const a = 1 - k;
          return [a * a * from[0] + 2 * a * k * mid[0] + k * k * to[0], a * a * from[1] + 2 * a * k * mid[1] + k * k * to[1]];
        },
        shrink: true,
      });
    },
    /** A short, nearly straight flight from [from] to [to]: a dropped snack going back, or into her mouth. */
    toss(from, to, color, { arc = 18, life = 0.4, shrink = true } = {}) {
      const mid = [(from[0] + to[0]) / 2, Math.min(from[1], to[1]) - arc];
      add({
        kind: 'snack',
        color,
        life,
        pop: false,
        scale: 1.5,
        path: (t) => {
          const k = t * t * (3 - 2 * t);
          const a = 1 - k;
          return [a * a * from[0] + 2 * a * k * mid[0] + k * k * to[0], a * a * from[1] + 2 * a * k * mid[1] + k * k * to[1]];
        },
        shrink,
      });
    },
    bubbles(x, y, count = 3) {
      for (let i = 0; i < count; i++) {
        add({ kind: 'ring', x: x + rand(-10, 10), y: y + rand(-6, 6), vx: rand(-6, 6), vy: rand(-46, -28), scale: rand(0.28, 0.5), life: rand(0.9, 1.4), pop: false });
      }
    },
    ripple(x, y) {
      add({ kind: 'ring', x, y, scale: 0.6, grow: 3.6, life: 0.55, pop: false });
    },
  };

  // ── Frame ────────────────────────────────────────────────────────────────

  function step(dt, parallaxX) {
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);

    for (const m of motes) {
      m.y -= m.rise * dt;
      if (m.y < -0.03) {
        m.y = 1.03;
        m.x = Math.random();
      }
      m.phase += dt * 0.5;
      const x = m.x * width + Math.sin(m.phase) * m.sway - parallaxX * (m.near ? 10 : 4);
      const y = m.y * height;
      ctx.globalAlpha = m.alpha * (glowing ? 1.25 : 1);
      ctx.fillStyle = glowing ? '#a8f0ff' : '#f2fbff';
      ctx.beginPath();
      ctx.arc(x, y, m.r, 0, Math.PI * 2);
      ctx.fill();
    }

    for (let i = sprites.length - 1; i >= 0; i--) {
      const s = sprites[i];
      s.age += dt;
      if (s.age >= s.life) {
        sprites.splice(i, 1);
        continue;
      }
      if (s.path) {
        [s.x, s.y] = s.path(s.age / s.life);
      } else {
        s.vy += s.gravity * dt;
        s.x += s.vx * dt + (s.kind === 'heart' ? Math.sin(s.age * 5) * 0.25 : 0);
        s.y += s.vy * dt;
      }
      s.rot += s.spin * dt;
      if (s.grow) s.scale += s.grow * dt;
    }
    for (const s of sprites) drawSprite(s);
    if (held) drawSprite(held);
    ctx.globalAlpha = 1;
  }

  /** A snack under a finger: drawn where the finger is every frame, until let go. */
  let held = null;

  /** Whether the frame loop must keep running for the marks. */
  const busy = () => sprites.length > 0 || held !== null;

  return {
    configure({ night, reducedMotion }) {
      glowing = night;
      reduced = reducedMotion;
      seedMotes();
    },
    resize,
    step,
    busy,
    hold(x, y, color) {
      if (held) {
        held.x = x;
        held.y = y;
      } else {
        held = { kind: 'snack', color, x, y, age: 1, life: 1e9, rot: 0, scale: 1.5, pop: false };
      }
    },
    drop() {
      held = null;
    },
    clear() {
      held = null;
      sprites.length = 0;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
    },
    marks,
  };
})();
