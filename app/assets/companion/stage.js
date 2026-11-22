// The companion's stage: draws one Live2D character and makes it feel alive.
// Runs inside CompanionStage's WebView (lib/ui/companion/companion_stage.dart),
// on Cubism Core and the Cubism Web Framework from the downloaded runtime pack.
// Design: docs/design/companion.md.
//
// The framework's sample drives a model with recorded motions; most community
// models ship without any, so here everything alive is computed each frame, in
// layers, on top of the model's own expressions and physics:
//
//   gaze springs → idle drift → mood pose → emotion face → action curves
//   → touch (pat, poke, tail) → mouth → expressions → physics → tail
//
// To Flutter: `DshCompanion.postMessage(json)`, see `post` calls.
// From Flutter: `stage.command({type, ...})`, see `commands` below.
(() => {
  'use strict';

  const Fw = window.CubismFw;
  const query = new URLSearchParams(location.search);
  const FLOAT = query.get('mode') === 'float';
  const floatAbort = FLOAT ? new AbortController() : null;
  let floatDisposed = false;
  let loadingModel = null;
  const PACK = new URL('../pack/', location.href).href;
  const CHARACTER = `${PACK}character/`;
  const SHADERS = `${PACK}runtime/shaders/`;
  const MAX_TEXTURE = Number(query.get('maxTexture')) || 4096;
  let REDUCED = query.get('reduceMotion') === '1';
  // Both draw at the screen's own density (phones are about 3x): a 2x buffer
  // stretched over a 3x screen reads as out of focus. The room sheds resolution
  // itself when frames can't keep up (`quality` below). A device budget from the
  // app (`dpr`, iOS) caps both canvases, this one and scene.js's.
  const BUDGET_DPR = Number(query.get('dpr'));
  const DPR_CAP = Math.min(FLOAT ? 4 : 3, BUDGET_DPR > 0 ? Math.max(0.5, BUDGET_DPR) : Infinity);
  // Clip masks: the renderer packs them into textures of four channels, at
  // most 36 different masks in one texture, 32 each when there are several.
  // A model that needs more (a detailed one: 49 for 大肥鱼 4096) gets more
  // textures, and past MASK_TEXTURES_MAX each mask drawn as it's needed.
  const MASKS_IN_ONE = 36;
  const MASKS_PER_TEXTURE = 32;
  const MASK_TEXTURES_MAX = 4;
  // Each mask gets a share of its texture: 256 (the framework's) blurs the
  // edges of small clipped parts on a detailed model.
  const MASK_SIZE = Number(query.get('maskSize')) || 1024;
  // The pack's own files beyond what model3.json lists, at most this many of each kind.
  const EXTRA_FILES_MAX = 64;
  const SLEEP_AFTER_MS = 3 * 60 * 1000;

  const canvas = document.getElementById('stage');
  const scene = window.companionScene;
  const reefFar = document.querySelector('.reef.far');
  const reefNear = document.querySelector('.reef.near');
  const sun = document.querySelector('.sun');
  const shafts = [...(document.querySelectorAll?.('.shafts i') ?? [])];
  const whale = document.querySelector('.whale');
  const props = {
    snack: document.getElementById('prop-snack'),
    play: document.getElementById('prop-play'),
    rest: document.getElementById('prop-rest'),
  };

  const post = (message) => {
    try {
      window.DshCompanion?.postMessage(JSON.stringify(message));
    } catch (_) {
      // No bridge: running in a test harness.
    }
  };

  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const lerp = (a, b, t) => a + (b - a) * t;
  const rand = (lo, hi) => lo + Math.random() * (hi - lo);
  const pick = (list) => list[Math.floor(Math.random() * list.length)];
  /** Eases toward a target at a rate that doesn't depend on the frame rate. */
  const ease = (from, to, rate, dt) => from + (to - from) * (1 - Math.exp(-rate * dt));

  class Spring {
    constructor(k, d, x = 0) {
      this.k = k;
      this.d = d;
      this.x = x;
      this.v = 0;
    }

    step(target, dt) {
      this.v += (this.k * (target - this.x) - this.d * this.v) * dt;
      this.x += this.v * dt;
      return this.x;
    }
  }

  // ── Character description (character.json, all optional) ────────────────

  const DEFAULT_ZONES = [
    { id: 'head', from: 0, to: 0.17 },
    { id: 'face', from: 0.17, to: 0.3 },
    { id: 'body', from: 0.3, to: 0.72 },
    { id: 'tail', from: 0.72, to: 1 },
  ];

  /** Standard Cubism parameters only, so any model gets a usable face. */
  const DEFAULT_EMOTIONS = {
    calm: {},
    happy: { face: { ParamMouthForm: 1, ParamEyeSmile: 1 } },
    shy: { face: { ParamMouthForm: 0.4, ParamEyeSmile: 0.4 }, gaze: [0.5, -0.4] },
    sad: { face: { ParamMouthForm: -1, ParamBrowLY: -0.6, ParamBrowRY: -0.6 }, gaze: [0, -0.5] },
    angry: { face: { ParamMouthForm: -0.8, ParamBrowLAngle: -1, ParamBrowRAngle: -1 } },
    surprised: { face: { ParamMouthOpenY: 0.6, ParamBrowLY: 1, ParamBrowRY: 1 } },
    confused: { face: { ParamBrowLY: 0.6, ParamBrowRY: -0.4, ParamMouthForm: -0.3 }, gaze: [0.4, 0.4] },
    smug: { face: { ParamMouthForm: 1, ParamBrowLY: 0.5, ParamBrowRY: 0.5 }, gaze: [-0.3, 0.1] },
    sleepy: { face: { eyelid: 0.45, ParamBrowLY: -0.3, ParamBrowRY: -0.3 } },
    worried: { face: { ParamMouthForm: -0.5, ParamBrowLAngle: 0.8, ParamBrowRAngle: 0.8 } },
    dizzy: { face: { ParamEyeSmile: -0.5, ParamMouthForm: -0.5 } },
  };

  /** Additive curves, [time 0–1, value] pairs. */
  const ACTIONS = {
    nod: { ms: 1100, tracks: { ParamAngleY: [[0, 0], [0.18, -11], [0.42, 1], [0.62, -7], [1, 0]] } },
    nodSmall: { ms: 700, tracks: { ParamAngleY: [[0, 0], [0.3, -5], [1, 0]] } },
    shake: { ms: 1200, tracks: { ParamAngleX: [[0, 0], [0.14, 13], [0.36, -13], [0.58, 9], [0.8, -5], [1, 0]] } },
    tilt: { ms: 1500, tracks: { ParamAngleZ: [[0, 0], [0.2, 13], [0.65, 13], [1, 0]], ParamEyeBallY: [[0, 0], [0.2, 0.25], [0.65, 0.25], [1, 0]] } },
    tiltLeft: { ms: 1500, tracks: { ParamAngleZ: [[0, 0], [0.2, -13], [0.65, -13], [1, 0]], ParamEyeBallY: [[0, 0], [0.2, 0.25], [0.65, 0.25], [1, 0]] } },
    lookUp: { ms: 1500, tracks: { ParamAngleY: [[0, 0], [0.25, 11], [0.65, 11], [1, 0]] } },
    recoil: { ms: 800, tracks: { ParamBodyAngleX: [[0, 0], [0.14, -7], [1, 0]], ParamAngleY: [[0, 0], [0.14, 8], [1, 0]] } },
    duck: { ms: 1500, tracks: { ParamAngleY: [[0, 0], [0.2, -12], [0.7, -12], [1, 0]], ParamBodyAngleY: [[0, 0], [0.2, -4], [0.7, -4], [1, 0]] } },
    sway: { ms: 2600, tracks: { ParamBodyAngleZ: [[0, 0], [0.25, 5], [0.75, -5], [1, 0]], ParamAngleZ: [[0, 0], [0.25, -3], [0.75, 3], [1, 0]] } },
    stretch: { ms: 1900, tracks: { ParamAngleY: [[0, 0], [0.35, 10], [0.7, 10], [1, 0]], ParamBodyAngleY: [[0, 0], [0.35, 6], [0.7, 6], [1, 0]] } },
    yawn: {
      ms: 2400,
      tracks: {
        ParamMouthOpenY: [[0, 0], [0.2, 0.85], [0.62, 0.9], [0.85, 0], [1, 0]],
        ParamEyeLOpen: [[0, 0], [0.2, -0.55], [0.7, -0.6], [0.9, 0], [1, 0]],
        ParamEyeROpen: [[0, 0], [0.2, -0.55], [0.7, -0.6], [0.9, 0], [1, 0]],
        ParamAngleY: [[0, 0], [0.25, 8], [0.7, 8], [1, 0]],
        ParamAngleZ: [[0, 0], [0.3, -4], [0.75, -4], [1, 0]],
      },
    },
  };

  const IDLE_FLOURISHES = ['tilt', 'tiltLeft', 'sway', 'nodSmall', 'lookUp', 'tail', 'hum'];

  /** What she does when nothing is going on depends a little on the hour. */
  /** Where closeness starts to show, in steps: same lines as companion_bond.dart. */
  const BOND_STEPS = [0.03, 0.1, 0.3];
  const bondStep = () => BOND_STEPS.filter((s) => life.vitals.closeness >= s).length;

  function idleChoices() {
    const tod = document.documentElement.dataset.tod;
    const choices =
      tod === 'night'
        ? [...IDLE_FLOURISHES, 'yawn', 'yawn', 'tilt']
        : tod === 'dawn'
          ? [...IDLE_FLOURISHES, 'stretch', 'yawn']
          : [...IDLE_FLOURISHES];
    // The better she knows you, the more she hums to herself, and in time
    // blows you a little heart now and then.
    const step = bondStep();
    if (step >= 2) choices.push('hum');
    if (step >= 3) choices.push('heart', 'heart');
    return choices;
  }

  /** A character's own curves (arms differ from model to model). */
  let actions = ACTIONS;

  /** How long each emotion holds before the face relaxes, ms. */
  const EMOTION_HOLD = 5200;

  /** What a touch does on the stage. The line she says, if any, is Flutter's. */
  const TAPS = {
    head: { emotion: 'happy', hold: 1800, action: 'nodSmall' },
    face: { emotion: 'shy', hold: 1800, action: 'recoil' },
    body: { emotion: 'surprised', hold: 1500, action: 'duck' },
    tail: { emotion: 'surprised', hold: 1500, action: 'recoil', tail: true },
    legs: { emotion: 'confused', hold: 1500, action: 'tilt' },
  };

  // ── Fitting any model (docs/design/companion-adapt.md) ──────────────────

  /** The parameters her life moves, each with the range it writes in. */
  const STANDARD = {
    ParamAngleX: [-30, 30],
    ParamAngleY: [-30, 30],
    ParamAngleZ: [-30, 30],
    ParamBodyAngleX: [-10, 10],
    ParamBodyAngleY: [-10, 10],
    ParamBodyAngleZ: [-10, 10],
    ParamBreath: [0, 1],
    ParamEyeLOpen: [0, 1],
    ParamEyeROpen: [0, 1],
    ParamEyeBallX: [-1, 1],
    ParamEyeBallY: [-1, 1],
    ParamEyeSmile: [0, 1],
    ParamMouthOpenY: [0, 1],
    ParamMouthForm: [-1, 1],
    ParamBrowLY: [-1, 1],
    ParamBrowRY: [-1, 1],
    ParamBrowLAngle: [-1, 1],
    ParamBrowRAngle: [-1, 1],
  };

  /**
   * Other names models give the same thing, beyond case and underscores
   * (`squashId` already makes Cubism 2's PARAM_ANGLE_X ParamAngleX). Each entry
   * is a set of parameters driven together.
   */
  const SYNONYMS = {
    ParamEyeSmile: [['ParamEyeLSmile', 'ParamEyeRSmile'], ['ParamEyeLSmile']],
    ParamMouthOpenY: [['ParamMouthOpen'], ['ParamMouthA'], ['ParamA']],
    ParamBreath: [['ParamBreathe']],
    ParamEyeBallX: [['ParamEyeX'], ['ParamEyeBallLX', 'ParamEyeBallRX']],
    ParamEyeBallY: [['ParamEyeY'], ['ParamEyeBallLY', 'ParamEyeBallRY']],
    ParamBrowLY: [['ParamBrowY']],
    ParamBrowRY: [['ParamBrowY']],
  };

  const squashId = (id) => id.toLowerCase().replace(/[^a-z0-9]/g, '');

  /** A framework id handle's text (a string, or a csmString in older builds). */
  const idText = (handle) => {
    const s = handle?.getString?.();
    return typeof s === 'string' ? s : (s?.s ?? '');
  };

  /** Hit area names → her touch zones. */
  const HIT_KINDS = [
    [/face|顔|脸|臉|cheek|mouth|口|眼/i, 'face'],
    [/head|頭|头|hair|髪|发/i, 'head'],
    [/tail|尾/i, 'tail'],
    [/leg|foot|feet|足|脚|腿/i, 'legs'],
    [/body|体|身|chest|bust|胸|torso|腹|belly|arm|hand|手/i, 'body'],
  ];

  // ── Live2D model ────────────────────────────────────────────────────────

  class StageModel extends Fw.CubismUserModel {
    constructor() {
      super();
      this.expressions = new Map();
      // The model's own motions (model3.json), by group, numbered when a group has several.
      this.motions = new Map();
      this.ids = new Map();
      this.tailIds = [];
      // Her standard parameter → the model's own, fitted to its range:
      // { ids, scale, offset }. Rules first (fitParams), the adapter over them.
      this.alias = new Map();
      this.ruleAlias = new Map();
      this.missing = [];
      this.hitAreas = [];
      this.hitZones = [];
      this.textureSizes = [];
      this.display = null;
      this.mocFile = '';
      this.mocVersion = 0;
    }

    id(name) {
      let handle = this.ids.get(name);
      if (!handle) {
        handle = Fw.CubismFramework.getIdManager().getId(name);
        this.ids.set(name, handle);
      }
      return handle;
    }

    set(name, value, weight = 1) {
      const link = this.alias.get(name);
      if (!link) return this._model.setParameterValueById(this.id(name), value, weight);
      for (const id of link.ids) this._model.setParameterValueById(this.id(id), value * link.scale + link.offset, weight);
    }

    add(name, value) {
      const link = this.alias.get(name);
      if (!link) return this._model.addParameterValueById(this.id(name), value);
      for (const id of link.ids) this._model.addParameterValueById(this.id(id), value * link.scale);
    }

    /** Whether the model has a parameter by this exact id. */
    has(id) {
      return typeof id === 'string' && this._model.getParameterIndex(this.id(id)) < this._model.getParameterCount();
    }

    /** A parameter's [min, max, default], by id. */
    range(id) {
      const raw = this._model.getModel().parameters;
      const i = raw.ids.indexOf(id);
      return i < 0 ? null : [raw.minimumValues[i], raw.maximumValues[i], raw.defaultValues[i]];
    }

    /**
     * The rules: each of her standard parameters found in the model however
     * it's spelled, by a synonym, or by the model's own blink and lip-sync
     * groups; a range far from hers is fitted. What's left is `missing`.
     */
    fitParams(setting) {
      const raw = this._model.getModel().parameters;
      const bySquash = new Map();
      for (const id of raw.ids) if (!bySquash.has(squashId(id))) bySquash.set(squashId(id), id);
      const group = (count, at) => Array.from({ length: count }, (_, i) => idText(at(i))).filter((id) => this.has(id));
      const blink = group(setting.getEyeBlinkParameterCount(), (i) => setting.getEyeBlinkParameterId(i));
      const lip = group(setting.getLipSyncParameterCount(), (i) => setting.getLipSyncParameterId(i));
      const link = (name, ids) => {
        const [low, high] = STANDARD[name];
        const [min, max] = this.range(ids[0]);
        const ratio = (max - min) / (high - low);
        // Close enough is left alone (an eye that opens to 2 is still an eye at
        // 1, a body that turns 30 still turns at 10); only an order off is fitted.
        const apart = max <= low || min >= high;
        const fit = ratio > 0 && (ratio < 0.2 || ratio > 5 || apart);
        if (!fit && ids.length === 1 && ids[0] === name) return;
        this.alias.set(name, { ids, scale: fit ? ratio : 1, offset: fit ? min - low * ratio : 0 });
      };
      this.missing = [];
      for (const name of Object.keys(STANDARD)) {
        const own = bySquash.get(squashId(name));
        const synonym = (SYNONYMS[name] ?? [])
          .map((set) => set.map((other) => bySquash.get(squashId(other))))
          .find((set) => set.every(Boolean));
        if (own) link(name, [own]);
        else if (synonym) link(name, synonym);
        else if (name === 'ParamEyeLOpen' && blink.length) link(name, [blink[0]]);
        else if (name === 'ParamEyeROpen' && blink.length) link(name, [blink[1] ?? blink[0]]);
        else if (name === 'ParamMouthOpenY' && lip.length) link(name, [lip[0]]);
        else this.missing.push(name);
      }
      this.ruleAlias = new Map(this.alias);
    }

    /** The model's hit areas as her touch zones, smallest first (they win). */
    findHitZones(setting) {
      const zones = [];
      this.hitAreas = [];
      for (let i = 0; i < setting.getHitAreasCount(); i++) {
        const handle = setting.getHitAreaId(i);
        const name = setting.getHitAreaName(i) ?? '';
        this.hitAreas.push({ id: idText(handle), name });
        const kind = HIT_KINDS.find(([pattern]) => pattern.test(`${name} ${idText(handle)}`))?.[1];
        const index = this._model.getDrawableIndex(handle);
        if (!kind || index < 0 || index >= this._model.getDrawableCount()) continue;
        const v = this._model.getDrawableVertices(index);
        let left = Infinity;
        let right = -Infinity;
        let top = -Infinity;
        let bottom = Infinity;
        for (let k = 0; k + 1 < v.length; k += 2) {
          const x = this._modelMatrix.transformX(v[k]);
          const y = this._modelMatrix.transformY(v[k + 1]);
          left = Math.min(left, x);
          right = Math.max(right, x);
          top = Math.max(top, y);
          bottom = Math.min(bottom, y);
        }
        if (!(right > left && top > bottom)) continue;
        zones.push({
          id: kind,
          from: clamp((1 - top) / 2, 0, 1),
          to: clamp((1 - bottom) / 2, 0, 1),
          xFrom: left,
          xTo: right,
          area: (right - left) * (top - bottom),
        });
      }
      zones.sort((a, b) => a.area - b.area);
      this.hitZones = zones.map(({ area, ...zone }) => zone);
    }

    /**
     * character.json, then the adapter (adapter.json) over it: which of the
     * model's parameters stand for hers, the tail, the resting pose.
     */
    adapt(config, extra) {
      this.alias = new Map(this.ruleAlias);
      const fromRules = new Set(this.missing);
      for (const [name, link] of Object.entries(extra?.params ?? {})) {
        if (!STANDARD[name] || !link) continue;
        const ids = (Array.isArray(link.id) ? link.id : [link.id]).filter((id) => this.has(id));
        if (!ids.length) continue;
        const scale = Number.isFinite(link.scale) && link.scale !== 0 ? link.scale : 1;
        const offset = Number.isFinite(link.offset) ? link.offset : 0;
        this.alias.set(name, { ids, scale, offset });
        fromRules.delete(name);
      }
      this.missingNow = [...fromRules];
      const tail = Array.isArray(extra?.tail) && extra.tail.length ? extra.tail : config.tail;
      this.tailIds = Array.isArray(tail) ? tail.filter((id) => this.has(id)) : [];
      // The resting pose from scratch, so an adapter taken back leaves nothing behind.
      const core = this._model;
      const raw = core.getModel().parameters;
      for (let i = 0; i < raw.count; i++) core.setParameterValueByIndex(i, raw.defaultValues[i]);
      for (const pose of [config.pose, extra?.pose]) {
        for (const [id, value] of Object.entries(pose ?? {})) {
          if (Number.isFinite(value) && this.has(id)) core.setParameterValueById(this.id(id), value);
        }
      }
      core.saveParameters();
    }

    get core() {
      return this._model;
    }

    get matrix() {
      return this._modelMatrix;
    }

    async load(gl, config) {
      const file = await resolveModelFile(config);
      if (floatDisposed) throw new Error('float_disposed');
      const home = new URL('.', new URL(encodePath(file), CHARACTER)).href;
      const bytes = (name) => fetchBytes(new URL(encodePath(name), home).href);

      const settingBytes = await fetchBytes(new URL(encodePath(file), CHARACTER).href);
      if (floatDisposed) throw new Error('float_disposed');
      const setting = new Fw.CubismModelSettingJson(settingBytes, settingBytes.byteLength);

      // A model exported by a newer Cubism than the runtime knows can't load
      // at all: say which, rather than a bare failure.
      this.mocFile = decodeURIComponent(new URL(encodePath(setting.getModelFileName()), home).href.slice(CHARACTER.length));
      const moc = await bytes(setting.getModelFileName());
      if (floatDisposed) throw new Error('float_disposed');
      const head = new Uint8Array(moc, 0, Math.min(5, moc.byteLength));
      if (String.fromCharCode(...head.slice(0, 4)) !== 'MOC3') throw new Error('moc');
      this.mocVersion = head[4];
      const latest = window.Live2DCubismCore?.Version?.csmGetLatestMocVersion?.() ?? 0;
      if (latest && this.mocVersion > latest) throw new Error(`moc-version ${this.mocVersion}/${latest}`);
      this.loadModel(moc, true);
      if (!this._model) throw new Error('moc');
      // What the editor calls each parameter (cdi3), for the adapter's eyes.
      try {
        const display = JSON.parse(new TextDecoder().decode(settingBytes)).FileReferences?.DisplayInfo;
        if (typeof display === 'string') this.display = JSON.parse(new TextDecoder().decode(await bytes(display)));
      } catch {
        this.display = null;
      }
      // The model matrix already fits the canvas to y −1…1, centred.

      // Models made for other apps often carry expressions and motions their
      // model3.json doesn't list (the other app wires them up itself): the
      // pack's own .exp3/.motion3 files are offered all the same, by file name.
      const listed = new Set();
      const own = (name) => listed.add(new URL(encodePath(name), home).href);
      for (let i = 0; i < setting.getExpressionCount(); i++) own(setting.getExpressionFileName(i));
      for (let g = 0; g < setting.getMotionGroupCount(); g++) {
        const group = setting.getMotionGroupName(g);
        for (let i = 0; i < setting.getMotionCount(group); i++) own(setting.getMotionFileName(group, i));
      }
      const files = await packIndex();
      if (floatDisposed) throw new Error('float_disposed');
      const extra = (ending) =>
        files
          .filter((f) => f.toLowerCase().endsWith(ending) && !listed.has(new URL(encodePath(f), CHARACTER).href))
          .slice(0, EXTRA_FILES_MAX)
          .map((f) => ({ url: new URL(encodePath(f), CHARACTER).href, name: f.split('/').pop().slice(0, -ending.length) }));

      const expressions = [];
      const addExpression = (name, load) =>
        expressions.push(
          load
            .then((buffer) => {
              if (floatDisposed || this.expressions.has(name)) return;
              const motion = this.loadExpression(buffer, buffer.byteLength, name);
              if (motion) {
                motion.setFadeInTime(0.25);
                motion.setFadeOutTime(0.4);
                this.expressions.set(name, motion);
              }
            })
            .catch(() => {}),
        );
      for (let i = 0; i < setting.getExpressionCount(); i++) {
        addExpression(setting.getExpressionName(i), bytes(setting.getExpressionFileName(i)));
      }
      await Promise.all(expressions);
      if (floatDisposed) throw new Error('float_disposed');
      for (const { url, name } of extra('.exp3.json')) addExpression(name, fetchBytes(url));
      await Promise.all(expressions);
      if (floatDisposed) throw new Error('float_disposed');

      // Its own motions, for the AI and the person to call by name. One that
      // won't load is left out, not fatal.
      const motions = [];
      // The parameters its motions' blink and lip-sync curves move (the
      // framework needs both lists, even empty, to update a motion at all).
      const effectIds = (count, at) => {
        const ids = [];
        for (let i = 0; i < count; i++) ids.push(at(i));
        return ids;
      };
      const blinkIds = effectIds(setting.getEyeBlinkParameterCount(), (i) => setting.getEyeBlinkParameterId(i));
      const lipIds = effectIds(setting.getLipSyncParameterCount(), (i) => setting.getLipSyncParameterId(i));
      for (let g = 0; g < setting.getMotionGroupCount(); g++) {
        const group = setting.getMotionGroupName(g);
        const count = setting.getMotionCount(group);
        for (let i = 0; i < count; i++) {
          const name = count > 1 ? `${group}_${i + 1}` : group;
          motions.push(
            bytes(setting.getMotionFileName(group, i))
              .then((buffer) => {
                if (floatDisposed) return;
                const motion = this.loadMotion(buffer, buffer.byteLength, name);
                if (!motion) return;
                motion.setEffectIds(blinkIds, lipIds);
                // The model's own fades when it gives them, else soft ones.
                const fadeIn = setting.getMotionFadeInTimeValue(group, i);
                const fadeOut = setting.getMotionFadeOutTimeValue(group, i);
                motion.setFadeInTime(fadeIn >= 0 ? fadeIn : 0.35);
                motion.setFadeOutTime(fadeOut >= 0 ? fadeOut : 0.45);
                this.motions.set(name, motion);
              })
              .catch(() => {}),
          );
        }
      }
      await Promise.all(motions);
      if (floatDisposed) throw new Error('float_disposed');
      for (const { url, name } of extra('.motion3.json')) {
        if (this.motions.has(name)) continue;
        motions.push(
          fetchBytes(url)
            .then((buffer) => {
              if (floatDisposed) return;
              const motion = this.loadMotion(buffer, buffer.byteLength, name);
              if (!motion) return;
              motion.setEffectIds(blinkIds, lipIds);
              motion.setFadeInTime(0.35);
              motion.setFadeOutTime(0.45);
              this.motions.set(name, motion);
            })
            .catch(() => {}),
        );
      }
      await Promise.all(motions);
      if (floatDisposed) throw new Error('float_disposed');
      // Relaxing a face is fading to an expression with nothing in it.
      const empty = new TextEncoder().encode('{"Type":"Live2D Expression","Parameters":[]}').buffer;
      this.neutral = this.loadExpression(empty, empty.byteLength, 'neutral');
      this.neutral?.setFadeInTime(0.5);

      if (setting.getPhysicsFileName()) {
        const buffer = await bytes(setting.getPhysicsFileName());
        if (floatDisposed) throw new Error('float_disposed');
        this.loadPhysics(buffer, buffer.byteLength);
      }
      if (setting.getPoseFileName()) {
        const buffer = await bytes(setting.getPoseFileName());
        if (floatDisposed) throw new Error('float_disposed');
        this.loadPose(buffer, buffer.byteLength);
      }

      const masks = clipSets(this._model);
      const textures = masks > MASKS_IN_ONE ? Math.ceil(masks / MASKS_PER_TEXTURE) : 1;
      this.createRenderer(canvas.width, canvas.height, Math.min(textures, MASK_TEXTURES_MAX));
      const renderer = this.getRenderer();
      if (textures > MASK_TEXTURES_MAX) renderer.useHighPrecisionMask(true);
      else if (this._model.isUsingMasking()) renderer.setClippingMaskBufferSize(MASK_SIZE);
      this.masks = { sets: masks, textures: Math.min(textures, MASK_TEXTURES_MAX), precise: renderer.isUsingHighPrecisionMask() };
      renderer.startUp(gl);
      renderer.loadShaders(SHADERS);
      renderer.setIsPremultipliedAlpha(true);
      for (let i = 0; i < setting.getTextureCount(); i++) {
        renderer.bindTexture(
          i,
          await loadTexture(gl, new URL(encodePath(setting.getTextureFileName(i)), home).href, this.textureSizes),
        );
      }

      this.fitParams(setting);
      // Vertices are only real after an update.
      this._model.update();
      this.findHitZones(setting);
      this.adapt(config, null);
    }

    /** One frame. [animate] writes everything that isn't saved between frames. */
    tick(dt, animate) {
      const core = this._model;
      core.loadParameters();
      animate.before(this, dt);
      // One of its own motions, while it plays, takes over from the pose she
      // keeps herself; expressions and physics still come after.
      if (!this._motionManager.isFinished()) this._motionManager.updateMotion(core, dt);
      this._expressionManager.updateMotion(core, dt);
      this._physics?.evaluate(core, dt);
      this._pose?.updateParameters(core, dt);
      animate.after(this, dt);
      core.update();
    }

    draw(projection, viewport) {
      const renderer = this.getRenderer();
      projection.multiplyByMatrix(this._modelMatrix);
      renderer.setMvpMatrix(projection);
      renderer.setRenderState(null, viewport);
      renderer.drawModel(SHADERS);
    }

    /** Whether the point, in model-matrix space, lands on something drawn. */
    hit(x, y) {
      const core = this._model;
      const lx = this._modelMatrix.invertTransformX(x);
      const ly = this._modelMatrix.invertTransformY(y);
      for (let i = 0; i < core.getDrawableCount(); i++) {
        if (core.getDrawableOpacity(i) < 0.1 || !core.getDrawableDynamicFlagIsVisible(i)) continue;
        const v = core.getDrawableVertices(i);
        const tris = core.getDrawableVertexIndices(i);
        const n = core.getDrawableVertexIndexCount(i);
        for (let t = 0; t + 2 < n; t += 3) {
          const a = tris[t] * 2;
          const b = tris[t + 1] * 2;
          const c = tris[t + 2] * 2;
          const d1 = (lx - v[b]) * (v[a + 1] - v[b + 1]) - (v[a] - v[b]) * (ly - v[b + 1]);
          const d2 = (lx - v[c]) * (v[b + 1] - v[c + 1]) - (v[b] - v[c]) * (ly - v[c + 1]);
          const d3 = (lx - v[a]) * (v[c + 1] - v[a + 1]) - (v[c] - v[a]) * (ly - v[a + 1]);
          const negative = d1 < 0 || d2 < 0 || d3 < 0;
          const positive = d1 > 0 || d2 > 0 || d3 > 0;
          if (!(negative && positive)) return true;
        }
      }
      return false;
    }

    startExpression(name) {
      const motion = name ? this.expressions.get(name) : this.neutral;
      if (motion) this._expressionManager.startMotion(motion, false);
    }

    /** Plays one of its own motions once; false when it has none by that name. */
    playMotion(name) {
      const motion = this.motions.get(name);
      if (!motion) return false;
      this._motionManager.startMotionPriority(motion, false, 2);
      return true;
    }

    get moving() {
      return !this._motionManager.isFinished();
    }

    /** Its own motions stopped where they are. */
    stopMotions() {
      this._motionManager.stopAllMotions();
    }
  }

  const encodePath = (path) => path.split('/').map(encodeURIComponent).join('/');

  /**
   * How many different clip masks a model needs: drawables clipped by the same
   * set of drawables share one, in any order (as the framework's clipping
   * manager groups them).
   */
  function clipSets(core) {
    const counts = core.getDrawableMaskCounts();
    const masks = core.getDrawableMasks();
    const sets = new Set();
    for (let i = 0; i < core.getDrawableCount(); i++) {
      if (counts[i] <= 0) continue;
      sets.add([...masks[i]].slice(0, counts[i]).sort((a, b) => a - b).join(','));
    }
    return sets.size;
  }

  /** The character's files, as the app listed them when it unpacked the pack. */
  let packFiles = null;
  function packIndex() {
    // Spelled out: WebView 83 (Android 10) cannot parse logical assignment (#1165).
    packFiles ?? (packFiles = fetch(`${CHARACTER}index.json`, { signal: floatAbort?.signal })
      .then((response) => (response.ok ? response.json() : []))
      .then((files) => (Array.isArray(files) ? files.filter((f) => typeof f === 'string') : []))
      .catch(() => []));
    return packFiles;
  }

  async function fetchBytes(url) {
    const response = await fetch(url, { signal: floatAbort?.signal });
    if (!response.ok) throw new Error(`${response.status} ${url}`);
    return response.arrayBuffer();
  }

  /** The configured model file, else the first `*.model3.json` the app lists. */
  async function resolveModelFile(config) {
    if (typeof config.model === 'string') return config.model;
    const files = await packIndex();
    const found = files.find((f) => f.toLowerCase().endsWith('.model3.json'));
    if (!found) throw new Error('model3');
    return found;
  }

  async function loadTexture(gl, url, sizes) {
    const blob = await (await fetch(url, { signal: floatAbort?.signal })).blob();
    const size = await createImageBitmap(blob);
    if (floatDisposed) { size.close(); throw new Error('float_disposed'); }
    sizes?.push([size.width, size.height]);
    const limit = Math.min(MAX_TEXTURE, gl.getParameter(gl.MAX_TEXTURE_SIZE));
    const scale = Math.min(1, limit / Math.max(size.width, size.height));
    const width = Math.round(size.width * scale);
    const height = Math.round(size.height * scale);
    size.close();
    const bitmap = await createImageBitmap(blob, {
      resizeWidth: width,
      resizeHeight: height,
      resizeQuality: 'high',
      premultiplyAlpha: 'premultiply',
      colorSpaceConversion: 'none',
    });
    if (floatDisposed) { bitmap.close(); throw new Error('float_disposed'); }
    const texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.bindTexture(gl.TEXTURE_2D, null);
    bitmap.close();
    return texture;
  }

  // ── What she is doing ───────────────────────────────────────────────────

  const life = {
    mood: 'idle', // idle | listening | thinking | speaking | sleeping
    emotion: 'calm',
    emotionUntil: 0,
    gazeHold: null, // [x, y] an emotion or mood looks at
    glance: null, // { at: [x, y], until } a short look at one of her things
    pointer: null, // [x, y] a finger, in stage units
    wander: [0, 0.05],
    wanderAt: 0,
    flourishAt: performance.now() + rand(9000, 20000),
    lastTouch: performance.now(),
    eye: { x: new Spring(170, 22), y: new Spring(170, 22) },
    head: { x: new Spring(34, 9), y: new Spring(34, 9) },
    body: { x: new Spring(14, 6.5), y: new Spring(14, 6.5) },
    poke: { x: new Spring(70, 7), z: new Spring(70, 7) },
    // The phone tilting or being shaken: she tips with the water, then finds her balance.
    sway: new Spring(26, 5),
    hop: new Spring(95, 11),
    face: new Map(),
    actions: new Map(),
    blink: { next: performance.now() + 1500, start: 0, second: false },
    pat: 0,
    patting: false,
    patX: 0,
    patHeartAt: 0,
    // A long press on her: a hug. She leans toward the hand (hugSide) and stays.
    hug: 0,
    hugging: false,
    hugSide: 0,
    hugHeartAt: 0,
    // A snack carried toward her: her mouth opens a little as it comes close.
    expect: 0,
    expecting: 0,
    // Her day: drowsy late at night (heavier lids, slower), and the flourishes
    // queued for the first morning visit.
    drowsy: 0,
    waking: [],
    tailKick: 0,
    speech: 0, // seconds of mouth movement still owed
    syllable: 0,
    mouth: 0,
    mouthOverride: null,
    // A fetched voice's loudness, frame by frame, from when it started playing.
    voice: null, // { levels, frameMs, start }
    sleep: 0,
    time: 0,
    // From the Host: how pleased, how lively, how familiar (0–1).
    vitals: { valence: 0.25, energy: 0.75, closeness: 0 },
  };

  let character = {};
  let emotions = DEFAULT_EMOTIONS;
  let authored = { emotions: {}, actions: {} };
  // adapter.json beside character.json: what the person's AI worked out for
  // this model (companion_adapt.dart checks it before it's written).
  let adapter = null;
  let zonesFrom = 'default';
  let defaultZoom = null;

  async function loadAdapter() {
    try {
      const response = await fetch(`${CHARACTER}adapter.json`, { cache: 'no-store', signal: floatAbort?.signal });
      const json = response.ok ? await response.json() : null;
      return json && typeof json === 'object' && !Array.isArray(json) ? json : null;
    } catch {
      return null;
    }
  }

  /** character.json, the rules' findings, then the adapter: the latest word wins. */
  function applyCharacter() {
    // What the character itself says, kept apart: a pet state in the float window only
    // wears what was authored for it, while a tap there reacts as it does in the room.
    authored = {
      emotions: { ...(character.emotions ?? {}), ...(adapter?.emotions ?? {}) },
      actions: { ...(character.actions ?? {}), ...(adapter?.actions ?? {}) },
    };
    emotions = mergeEmotions(authored.emotions);
    actions = { ...ACTIONS, ...authored.actions };
    if (Array.isArray(adapter?.zones) && adapter.zones.length) {
      zones = adapter.zones;
      zonesFrom = 'adapter';
    } else if (Array.isArray(character.zones) && character.zones.length) {
      zones = character.zones;
      zonesFrom = 'character';
    } else if (model?.hitZones.length) {
      zones = model.hitZones;
      zonesFrom = 'hitAreas';
    } else {
      // Hers end in a tail; a model without one has legs there.
      zones = model && !model.tailIds.length ? DEFAULT_ZONES.map((z) => (z.id === 'tail' ? { ...z, id: 'legs' } : z)) : DEFAULT_ZONES;
      zonesFrom = 'default';
    }
    defaultZoom ?? (defaultZoom = camera.zoom);
    camera.zoom = Number(adapter?.framing?.zoom) || Number(character.framing?.zoom) || defaultZoom;
    camera.y = Number(adapter?.framing?.y ?? character.framing?.y) || 0;
    if (FLOAT) {
      // Separate, explicit float framing; never write it into the room's adapter.
      const zoom = Number(query.get('floatZoom'));
      const y = Number(query.get('floatY'));
      camera.zoom = zoom > 0 && zoom <= 4 ? zoom : 0.9;
      camera.y = Number.isFinite(y) ? clamp(y, -1, 1) : 0;
    }
  }

  /** What the model is, for the app's check and the person's AI (companion_adapt.dart). */
  function probeReport() {
    const raw = model.core.getModel();
    const display = model.display ?? {};
    const groupName = new Map((display.ParameterGroups ?? []).map((g) => [g.Id, g.Name]));
    const info = new Map((display.Parameters ?? []).map((p) => [p.Id, p]));
    const partName = new Map((display.Parts ?? []).map((p) => [p.Id, p.Name]));
    const params = [];
    for (let i = 0; i < Math.min(raw.parameters.count, 800); i++) {
      const id = raw.parameters.ids[i];
      params.push({
        id,
        name: info.get(id)?.Name ?? null,
        group: groupName.get(info.get(id)?.GroupId) ?? null,
        // These are contract facts, not display labels. Rounding can collapse
        // a valid small native range and lose an existing affine calibration.
        min: raw.parameters.minimumValues[i],
        max: raw.parameters.maximumValues[i],
        def: raw.parameters.defaultValues[i],
      });
    }
    return {
      moc: model.mocFile,
      mocVersion: model.mocVersion,
      parameterCount: raw.parameters.count,
      drawables: raw.drawables.count,
      masks: model.masks,
      textures: model.textureSizes,
      params,
      parts: Array.from({ length: Math.min(raw.parts.count, 300) }, (_, i) => ({
        id: raw.parts.ids[i],
        name: partName.get(raw.parts.ids[i]) ?? null,
      })),
      expressions: [...model.expressions.keys()],
      motions: [...model.motions.keys()],
      hitAreas: model.hitAreas,
      // linked describes the CURRENT adapter too. It does not prove that an
      // alias survives adapt(), which starts afresh from ruleAlias.
      linked: Object.fromEntries([...model.alias].map(([name, link]) => [name, link.ids])),
      ruleAliasVersion: 1,
      ruleAliases: Object.fromEntries([...model.ruleAlias].map(([name, link]) => [name, {
        ids: [...link.ids], scale: link.scale, offset: link.offset,
      }])),
      missing: model.missingNow ?? model.missing,
      zones,
      zonesFrom,
      emotionsFrom: character.emotions ? 'character' : 'default',
      tail: model.tailIds,
      adapter: adapter !== null,
      name: character.name ?? null,
    };
  }
  let zones = DEFAULT_ZONES;
  let transientEpoch = 0;

  function setEmotion(name, hold = EMOTION_HOLD, native = false) {
    const own = native && model?.expressions.has(name);
    // Not one she knows: one of the model's own expressions, by its name.
    const def = own ? { expression: name } : (emotions[name] ?? (model?.expressions.has(name) ? { expression: name } : null));
    if (!def) return;
    // The model's own never borrows the face of a feeling of hers with the same name.
    const key = own ? `model:${name}` : name;
    const changed = life.emotion !== key;
    life.emotion = key;
    life.emotionUntil = key === 'calm' ? 0 : performance.now() + hold;
    life.gazeHold = def.gaze ?? null;
    model?.startExpression(def.expression ?? null);
    if (changed && model && !own && !FLOAT) emotionMark(name);
  }

  /** Emotions relax on their own: to calm in the room, to the pet state's in the float window. */
  function relaxEmotion(now) {
    if (!life.emotionUntil || now <= life.emotionUntil) return;
    if (FLOAT) setEmotion(floatEmotion, Infinity);
    else setEmotion('calm');
  }

  /** A few notes, one after another, while she hums. */
  function humNotes(count) {
    const epoch = transientEpoch;
    for (let i = 0; i < count; i++) {
      setTimeout(() => {
        if (epoch === transientEpoch && !paused && model) {
          const [x, y] = headOnScreen();
          scene.marks.note(x, y);
        }
      }, i * 520);
    }
  }

  /** The little sign over her head that goes with a feeling. */
  function emotionMark(name) {
    const [x, y] = headOnScreen();
    switch (name) {
      case 'happy':
        scene.marks.sparkles(x, y);
        break;
      case 'shy':
        scene.marks.hearts(x, y, 1);
        break;
      case 'surprised':
        scene.marks.exclaim(x, y);
        break;
      case 'confused':
        scene.marks.question(x, y);
        break;
      case 'angry':
      case 'dizzy':
        scene.marks.anger(x, y);
        break;
      case 'worried':
        scene.marks.sweat(x, y);
        break;
      case 'sad':
        scene.marks.tear(x, y);
        break;
      default:
        break;
    }
  }

  function playAction(name) {
    const action = actions[name];
    if (!action) return;
    if (REDUCED) return;
    // The adapter can make one of hers a motion of the model's own.
    if (typeof action.motion === 'string') {
      if (!model?.playMotion(action.motion) && action.tracks) life.actions.set(name, { action, start: performance.now() });
      return;
    }
    life.actions.set(name, { action, start: performance.now() });
  }

  function hop(strength = 1) {
    if (!REDUCED) life.hop.v += 1.15 * strength;
  }

  /** Curve value at t in 0–1, smooth between keys. */
  function sample(keys, t) {
    for (let i = 1; i < keys.length; i++) {
      if (t <= keys[i][0]) {
        const [t0, v0] = keys[i - 1];
        const [t1, v1] = keys[i];
        const k = (t - t0) / (t1 - t0 || 1);
        return lerp(v0, v1, k * k * (3 - 2 * k));
      }
    }
    return keys[keys.length - 1][1];
  }

  function gazeTarget(now) {
    if (life.pointer) return life.pointer;
    if (home.gaze) return home.gaze;
    if (life.glance) {
      if (now < life.glance.until) return life.glance.at;
      life.glance = null;
    }
    if (life.gazeHold) return life.gazeHold;
    switch (life.mood) {
      case 'thinking':
        return [0.5 + Math.sin(now / 1900) * 0.12, 0.55 + Math.sin(now / 1300) * 0.08];
      case 'listening':
        return [0, -0.32];
      case 'speaking':
        return [Math.sin(now / 2300) * 0.08, 0.03];
      case 'sleeping':
        return [0, -0.5];
      default:
        break;
    }
    if (now > life.wanderAt) {
      // The better she knows you, the more she looks at you instead of away.
      const glance = Math.random() < 0.22 * (1 - life.vitals.closeness * 0.6);
      const toWindow = glance && Math.random() < 0.3;
      life.wander = toWindow
        ? [rand(-0.85, -0.65), rand(0.45, 0.65)]
        : glance
          ? [rand(-0.7, 0.7), rand(-0.3, 0.45)]
          : [rand(-0.1, 0.1), rand(-0.02, 0.1)];
      life.wanderAt = now + (glance ? rand(900, 1800) : rand(2600, 7000));
      if (glance && now > life.blink.next - 2500) life.blink.next = now; // eyes blink as they jump
    }
    return life.wander;
  }

  function eyelid(now) {
    const b = life.blink;
    let open = 1;
    if (now >= b.next) {
      if (b.start === 0) b.start = now;
      const p = now - b.start;
      if (p < 80) {
        const k = p / 80;
        open = 1 - k * k;
      } else if (p < 240) {
        const k = (p - 80) / 160;
        open = 1 - (1 - k) * (1 - k);
      } else {
        b.start = 0;
        b.second = !b.second && Math.random() < 0.18;
        b.next = now + (b.second ? 120 : rand(2400, 6200));
      }
    }
    return open;
  }

  const animate = {
    before(m, dt) {
      const now = performance.now();
      life.time += dt;
      const t = life.time;

      // Falling asleep and waking.
      // Late at night she drifts off sooner.
      const sleepAfter = document.documentElement.dataset.tod === 'night' ? SLEEP_AFTER_MS / 2 : SLEEP_AFTER_MS;
      if (!FLOAT && life.mood === 'idle' && now - life.lastTouch > sleepAfter) setMood('sleeping');
      life.sleep = ease(life.sleep, life.mood === 'sleeping' ? 1 : 0, 1.6, dt);

      // Emotions relax on their own.
      relaxEmotion(now);

      const [gx, gy] = gazeTarget(now);
      const eyeX = life.eye.x.step(gx, dt);
      const eyeY = life.eye.y.step(gy, dt);
      const headX = life.head.x.step(gx * 0.8, dt);
      const headY = life.head.y.step(gy * 0.8, dt);
      const bodyX = life.body.x.step(gx * 0.5, dt);
      const bodyY = life.body.y.step(gy * 0.3, dt);

      const pokeX = life.poke.x.step(0, dt);
      const pokeZ = life.poke.z.step(0, dt);
      const sway = swayStep(dt);

      // Head pat: she leans into the hand and melts a little.
      life.pat = ease(life.pat, life.patting ? 1 : 0, life.patting ? 3.5 : 1.8, dt);
      life.hug = ease(life.hug, life.hugging ? 1 : 0, life.hugging ? 3 : 1.6, dt);
      life.expect = ease(life.expect, life.expecting, 8, dt);

      const vitals = life.vitals;
      // Livelier when rested, calmer when not; never frozen.
      const drift = REDUCED ? 0 : (0.65 + vitals.energy * 0.55) * (1 - 0.3 * life.drowsy);
      const asleep = life.sleep;
      const thinking = life.mood === 'thinking' ? 1 : 0;

      m.set('ParamAngleX', headX * 26 + Math.sin(t * 0.43) * 2.2 * drift + Math.sin(t * 0.17) * 1.6 * drift + pokeX + life.pat * life.patX * 10);
      m.set('ParamAngleY', headY * 22 + Math.cos(t * 0.61) * 1.6 * drift - asleep * 17 - life.pat * 7);
      m.set('ParamAngleZ', headX * -7 + Math.sin(t * 0.29) * 1.8 * drift + pokeZ + thinking * 4 + asleep * 8 + life.pat * life.patX * 7);
      m.set('ParamBodyAngleX', bodyX * 9 + Math.sin(t * 0.37) * 1.1 * drift);
      m.set('ParamBodyAngleY', bodyY * 7 - asleep * 4);
      m.set('ParamBodyAngleZ', bodyX * -3 + Math.sin(t * 0.41 + 1) * 1.3 * drift);
      if (sway) {
        // Her body goes with the water; her head lags behind it.
        m.add('ParamBodyAngleZ', sway * 8);
        m.add('ParamBodyAngleX', sway * 4);
        m.add('ParamAngleZ', sway * 5);
        m.add('ParamAngleX', sway * -6);
      }
      if (life.hug > 0.01) {
        // Leaning into the hug, head a little down.
        m.add('ParamAngleZ', life.hug * life.hugSide * 9);
        m.add('ParamAngleY', -life.hug * 5);
        m.add('ParamBodyAngleZ', life.hug * life.hugSide * 5);
        m.add('ParamBodyAngleX', life.hug * life.hugSide * 3);
      }
      m.set('ParamEyeBallX', Math.tanh(eyeX * 1.25) * (1 - asleep));
      m.set('ParamEyeBallY', Math.tanh(eyeY * 1.25) * (1 - asleep));
      // Slow breath; slower still asleep.
      const breathRate = lerp(1.75, 0.95, asleep);
      m.set('ParamBreath', 0.5 + 0.5 * Math.sin(t * breathRate));

      // Face: every parameter eases to where the emotion wants it.
      const want = emotions[life.emotion]?.face ?? {};
      for (const id of Object.keys(want)) if (!life.face.has(id)) life.face.set(id, 0);
      for (const [id, value] of life.face) life.face.set(id, ease(value, want[id] ?? 0, 7, dt));
      let lidFromFace = 1;
      for (const [id, value] of life.face) {
        if (id === 'eyelid') lidFromFace = 1 - (1 - (want.eyelid ?? 1)) * clamp(Math.abs(value), 0, 1);
        else m.add(id, value);
      }
      if (thinking) {
        m.add('ParamBrowLY', 0.35);
        m.add('ParamBrowRY', 0.15);
      }
      // A good mood shows as the faintest resting smile.
      if (life.emotion === 'calm') {
        const pleased = (vitals.valence - 0.25) * 0.7;
        m.add('ParamMouthForm', pleased);
        m.add('ParamEyeSmile', pleased * 0.5);
      }

      // Eyes: blink, emotions, a pat, sleep.
      const heavy = life.mood === 'idle' ? 1 - 0.2 * life.drowsy : 1;
      const lid = eyelid(now) * lidFromFace * (1 - 0.92 * life.pat) * (1 - asleep) * heavy;
      m.set('ParamEyeLOpen', lid);
      m.set('ParamEyeROpen', lid);
      if (life.pat > 0.02) {
        m.add('ParamEyeSmile', life.pat);
        m.add('ParamMouthForm', life.pat);
      }

      if (!FLOAT) homePose(m, now, dt);

      // Actions add on top of all that.
      for (const [name, run] of life.actions) {
        const p = (now - run.start) / run.action.ms;
        if (p >= 1) {
          life.actions.delete(name);
          continue;
        }
        for (const [id, keys] of Object.entries(run.action.tracks)) m.add(id, sample(keys, p));
      }

      // Idle flourishes, only when nothing else is going on.
      if (!FLOAT && !REDUCED && life.mood === 'idle' && !life.pointer && now > life.flourishAt && life.emotion === 'calm') {
        // The first morning visit: a stretch, then a yawn, before anything else.
        const name = life.waking.length ? life.waking.shift() : pick(idleChoices());
        if (name === 'tail') {
          life.tailKick = 1;
        } else if (name === 'heart') {
          playAction('nodSmall');
          const [mx, my] = mouthOnScreen();
          scene.marks.hearts(mx + 18, my - 10, 1);
        } else if (name === 'hum') {
          playAction('sway');
          humNotes(3);
        } else {
          playAction(name);
        }
        life.flourishAt = life.waking.length
          ? now + 2600
          : now + rand(11000, 28000) / (0.6 + life.vitals.energy * 0.8);
      }

      // Mouth: real audio levels when given (later), else the rhythm of the text.
      let mouth = 0;
      if (life.mouthOverride !== null) {
        mouth = life.mouthOverride;
      } else if (life.speech > 0) {
        life.speech = Math.max(0, life.speech - dt);
        life.syllable += dt * 8.5;
        const beat = Math.sin(life.syllable * Math.PI);
        mouth = Math.pow(Math.abs(beat), 0.7) * (0.55 + 0.4 * Math.sin(life.syllable * 0.37) ** 2);
      }
      if (life.voice) {
        const i = Math.floor((now - life.voice.start) / life.voice.frameMs);
        if (i < life.voice.levels.length) mouth = Math.max(mouth, life.voice.levels[i]);
        else life.voice = null;
      }
      mouth = Math.max(mouth, life.expect * 0.45);
      life.mouth = ease(life.mouth, mouth, mouth > life.mouth ? 26 : 16, dt);
      m.add('ParamMouthOpenY', life.mouth);
    },

    after(m, dt) {
      // The tail runs after physics: a wag on top of whatever physics did.
      if (!m.tailIds.length) return;
      life.tailKick = Math.max(0, life.tailKick - dt * 0.55);
      const happy = life.emotion === 'happy' || life.patting ? 0.45 : 0;
      const amount = REDUCED ? 0 : Math.max(life.tailKick, happy);
      const t = life.time;
      m.tailIds.forEach((id, i) => {
        const sway = Math.sin(t * 1.1 - i * 0.55) * 3;
        const wag = Math.sin(t * 7 - i * 0.8) * 13 * amount;
        m.add(id, sway + wag);
      });
    },
  };

  function setMood(mood) {
    if (life.mood === mood) return;
    const wasAsleep = life.mood === 'sleeping';
    life.mood = mood;
    post({ type: 'mood', mood });
    if (wasAsleep) {
      playAction('stretch');
      life.blink.next = performance.now() + 300;
    }
    life.wanderAt = 0;
  }

  // ── Home (Pro C204): a shell dish, a seaweed cushion, a bubble ball ──────
  //
  // A tap gives an immediate short show (no network, no model) and tells
  // Flutter, which sends snack / play / rest to the Host. What lasts afterwards
  // (a warm dish, a pressed cushion, her leaning back) follows the activity the
  // Host answers with, or the page's guess when this host can't keep it.

  const SHOW_MS = { snack: 3200, play: 3600, rest: 1200 };

  const home = {
    activity: 'idle',
    until: 0,
    show: null, // { kind, start, familiar }
    beckon: null, // { prop, next }: bubbles rise from it while she invites
    gaze: null,
    rest: 0, // 0–1, eased
    reach: 0, // model units she leans toward the dish
    ball: { x: 0, y: 0, s: 1 },
  };

  function propRect(name) {
    return props[name]?.getBoundingClientRect() ?? null;
  }

  function propAt(x, y, names) {
    for (const name of names) {
      const r = propRect(name);
      if (!r) continue;
      // A little more than the drawing: fingers are bigger than shells.
      const pad = 10;
      if (x >= r.left - pad && x <= r.right + pad && y >= r.top - pad && y <= r.bottom + pad) return name;
    }
    return null;
  }

  function squash(name) {
    const el = props[name];
    if (!el) return;
    el.classList.add('squash');
    setTimeout(() => el.classList.remove('squash'), 160);
  }

  function useProp(name) {
    post({ type: 'object', id: name });
    showProp(name);
  }

  /** The short show alone, telling Flutter nothing: for a yes to her invitation. */
  function showProp(name) {
    if (!props[name]) return;
    squash(name);
    // One show at a time: another tap meanwhile is only acknowledged.
    if (home.show || REDUCED) return;
    home.show = { kind: name, start: performance.now(), familiar: life.vitals.closeness };
  }

  function glanceAt(name, ms) {
    const r = propRect(name);
    if (!r) return;
    const hold = clamp(Number.isFinite(ms) ? ms : 1400, 200, 4000);
    life.glance = { at: toGazeFromClient(...center(r)), until: performance.now() + hold };
  }

  /** While she invites: two small bubbles from the thing every 1.5 s. */
  function beckonFrame(now) {
    const beckon = home.beckon;
    if (!beckon || REDUCED || now < beckon.next) return;
    beckon.next = now + 1500;
    const r = propRect(beckon.prop);
    if (r) scene.marks.bubbles(r.left + r.width * 0.5, r.top + r.height * 0.36, 2);
  }

  function setActivity(name, remainingMs) {
    const known = ['idle', 'snack', 'play', 'rest'].includes(name) ? name : 'idle';
    if (known !== home.activity) post({ type: 'activity', name: known });
    home.activity = known;
    home.until = known === 'idle' || remainingMs == null ? (known === 'idle' ? 0 : home.until || performance.now() + 15 * 60000) : performance.now() + Math.max(0, remainingMs);
    props.snack?.classList.toggle('warm', known === 'snack');
    props.play?.classList.toggle('lively', known === 'play');
    props.rest?.classList.toggle('resting', known === 'rest');
  }

  function toGazeFromClient(x, y) {
    return toGaze(x, y);
  }

  function center(rect) {
    return [rect.left + rect.width / 2, rect.top + rect.height / 2];
  }

  /** Where her mouth roughly is on screen, for the snack to arrive at. */
  function mouthOnScreen() {
    const [x, y] = toScreen(0, 0.52);
    return [x - 22, y + 10];
  }

  function homePose(m, now, dt) {
    if (home.activity !== 'idle' && home.until && now > home.until) setActivity('idle', 0);
    beckonFrame(now);
    home.rest = ease(home.rest, home.activity === 'rest' ? 1 : 0, home.activity === 'rest' ? 1.6 : 3, dt);
    if (home.rest > 0.01) {
      // Leaning back on the cushion: a little to the right, head a little low.
      m.add('ParamBodyAngleZ', -6 * home.rest);
      m.add('ParamAngleZ', -5 * home.rest);
      m.add('ParamAngleY', -3 * home.rest);
      m.add('ParamBodyAngleX', 4 * home.rest);
    }
    const show = home.show;
    if (!show) {
      home.gaze = null;
      return;
    }
    const t = (now - show.start) / SHOW_MS[show.kind];
    if (t >= 1) {
      home.show = null;
      home.gaze = null;
      home.reach = 0;
      resetBall();
      return;
    }
    if (show.kind === 'snack') snackShow(m, show, t);
    else if (show.kind === 'play') playShow(m, show, t);
    else restShow(show, t);
  }

  const smooth = (u) => {
    const k = clamp(u, 0, 1);
    return k * k * (3 - 2 * k);
  };

  // 3.2 s: look at the dish, a snack floats up, gone with a nod, look back.
  function snackShow(m, show, t) {
    const dish = propRect('snack');
    const lookFirst = show.familiar >= 0.025 && t < 0.08;
    if (lookFirst) {
      home.gaze = [0, 0.05];
    } else if (t < 0.5 && dish) {
      home.gaze = toGazeFromClient(...center(dish));
    } else if (t < 0.66) {
      home.gaze = toGazeFromClient(...mouthOnScreen());
    } else {
      home.gaze = [0, 0.05];
    }
    if (!show.snack && t > 0.06 && dish) {
      show.snack = true;
      const from = [dish.left + dish.width * 0.5, dish.top + dish.height * 0.42];
      const warm = getComputedStyle(document.documentElement).getPropertyValue('--warm').trim() || '242, 213, 172';
      scene.marks.snack(from, mouthOnScreen(), `rgb(${warm})`);
    }
    const toward = smooth((t - 0.15) / 0.3) * (1 - smooth((t - 0.62) / 0.25));
    m.add('ParamBodyAngleX', -4 * toward);
    home.reach = -0.03 * toward;
    if (!show.ate && t > 0.5) {
      show.ate = true;
      playAction('nodSmall');
      setEmotion('happy', 1800);
      life.tailKick = Math.max(life.tailKick, 0.6);
      const [x, y] = mouthOnScreen();
      scene.marks.sparkles(x + 20, y - 20, 2);
    }
  }

  // 3.6 s: the ball goes to her, she watches it, it bobs, it comes back.
  function playShow(m, show, t) {
    const el = props.play;
    const rect = el ? el.getBoundingClientRect() : null;
    if (!el || !rect) return;
    if (!show.home) show.home = center(rect);
    const [hx, hy] = show.home;
    const [fx, fy] = toScreen(0.2, 0.62); // beside her face, never on it
    const near = [fx + 24 - hx, fy - hy];
    const back = [near[0] * 0.55, near[1] * 0.45 + 18];
    let dx = 0;
    let dy = 0;
    let s = 1;
    if (t < 0.25) {
      const k = smooth((t - 0.05) / 0.2);
      dx = near[0] * k;
      dy = near[1] * k - Math.sin(k * Math.PI) * 28;
    } else if (t < 0.5) {
      const k = smooth((t - 0.25) / 0.25);
      dx = lerp(near[0], back[0], k);
      dy = lerp(near[1], back[1], k) - Math.sin(k * Math.PI) * 12;
    } else if (t < 0.75) {
      const k = smooth((t - 0.5) / 0.25);
      dx = lerp(back[0], 0, k);
      dy = lerp(back[1], 0, k);
      // Handing it back, when she knows you well.
      if (show.familiar >= 0.095) s = 1 + 0.05 * Math.sin(k * Math.PI);
    }
    setBall(dx, dy, s);
    home.gaze = toGazeFromClient(hx + dx, hy + dy);
    if (t > 0.75) home.gaze = [0, 0.05];
    m.add('ParamBodyAngleX', 3 * Math.sin(clamp(t / 0.5, 0, 1) * Math.PI));
    if (!show.caught && t > 0.3) {
      show.caught = true;
      life.tailKick = 1;
      setEmotion('happy', 1600);
      hop(0.5);
    }
    if (!show.trail && t > 0.75) {
      show.trail = true;
      scene.marks.bubbles(hx, hy - 10, 3);
    }
  }

  // 1.2 s: the cushion takes her weight; what lasts is the activity.
  function restShow(show, t) {
    if (!show.sighed && t > 0.3) {
      show.sighed = true;
      setEmotion('sleepy', 2600);
    }
    home.gaze = t < 0.5 ? [0.4, -0.3] : null;
  }

  function setBall(dx, dy, s) {
    const b = home.ball;
    if (Math.abs(b.x - dx) < 0.3 && Math.abs(b.y - dy) < 0.3 && Math.abs(b.s - s) < 0.003) return;
    b.x = dx;
    b.y = dy;
    b.s = s;
    props.play.style.transform = `translate3d(${dx.toFixed(1)}px, ${dy.toFixed(1)}px, 0) scale(${s.toFixed(3)})`;
  }

  // Always clear: the last frame can leave it at exactly 0,0,1 with the
  // inline transform still set, and that would win over the CSS states.
  function resetBall() {
    home.ball = { x: 0, y: 0, s: 1 };
    if (props.play) props.play.style.transform = '';
  }

  // ── Camera ──────────────────────────────────────────────────────────────

  const camera = { zoom: 1.2, x: 0, y: 0 };

  function modelLift() {
    const float = REDUCED ? 0 : Math.sin(life.time * 0.85) * 0.011;
    return life.hop.x * 0.12 + float - home.rest * 0.025;
  }

  /** Where she is sideways: at home, reaching, and carried a little by the water. */
  function modelShift() {
    return home.rest * 0.07 + home.reach + life.sway.x * 0.05;
  }

  function projection() {
    const aspect = canvas.height / canvas.width;
    // She floats: a slow lift and drift, on top of any hop.
    const hopY = modelLift();
    const lean = modelShift();
    const m = new Fw.CubismMatrix44();
    const sx = camera.zoom * aspect;
    const sy = camera.zoom;
    m.setMatrix(new Float32Array([sx, 0, 0, 0, 0, sy, 0, 0, 0, 0, 1, 0, (lean - camera.x) * sx, -camera.y * sy + hopY, 0, 1]));
    return m;
  }

  /** Client coordinates → model-matrix space. */
  function toModel(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    const cx = ((clientX - rect.left) / rect.width) * 2 - 1;
    const cy = 1 - ((clientY - rect.top) / rect.height) * 2;
    const aspect = canvas.height / canvas.width;
    return {
      x: cx / (camera.zoom * aspect) + camera.x - modelShift(),
      y: (cy - modelLift()) / camera.zoom + camera.y,
    };
  }

  /** Model-matrix space → CSS pixels. */
  function toScreen(x, y) {
    const rect = canvas.getBoundingClientRect();
    const aspect = canvas.height / (canvas.width || 1);
    const cx = (x - camera.x + modelShift()) * camera.zoom * aspect;
    const cy = (y - camera.y) * camera.zoom + modelLift();
    return [((cx + 1) / 2) * rect.width, ((1 - cy) / 2) * rect.height];
  }

  function headOnScreen() {
    const [ax, ay] = Array.isArray(character.mark) ? character.mark : [0.19, 0.84];
    const [x, y] = toScreen(ax, ay);
    return [x + life.head.x.x * 16, y - life.head.y.x * 10]; // Beside her head, where manga puts them.
  }

  function zoneAt(x, y) {
    const fromTop = (1 - y) / 2;
    return (
      zones.find(
        (z) => fromTop >= z.from && fromTop < z.to && x >= (z.xFrom ?? -Infinity) && x < (z.xTo ?? Infinity),
      )?.id ?? null
    );
  }

  function touched() {
    life.lastTouch = performance.now();
    if (life.mood === 'sleeping') {
      setMood('idle');
      post({ type: 'wake' });
    }
  }

  // ── Touch ───────────────────────────────────────────────────────────────

  const pointers = new Map();
  const gesture = { pinch: 0, zoom: 0, midX: 0, midY: 0, camX: 0, camY: 0 };
  let press = null;
  const taps = [];

  function toGaze(clientX, clientY) {
    const rect = canvas.getBoundingClientRect();
    const x = ((clientX - rect.left) / rect.width) * 2 - 1;
    const y = 1 - ((clientY - rect.top) / rect.height) * 2;
    // Her face sits in the upper part of the stage: aim from there.
    return [clamp(x * 1.15, -1, 1), clamp((y - 0.25) * 1.1, -1, 1)];
  }

  function pinchInfo() {
    const [a, b] = [...pointers.values()];
    return { distance: Math.hypot(a.x - b.x, a.y - b.y), midX: (a.x + b.x) / 2, midY: (a.y + b.y) / 2 };
  }

  if (!FLOAT) canvas.addEventListener('pointerdown', (e) => {
    canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    touched();
    if (pointers.size === 2) {
      const info = pinchInfo();
      Object.assign(gesture, { pinch: info.distance, zoom: camera.zoom, midX: info.midX, midY: info.midY, camX: camera.x, camY: camera.y });
      // A second finger means zooming: no hug, and a carried snack goes back.
      if (press) clearTimeout(press.hugTimer);
      if (press?.dragging) {
        scene.drop();
        life.expecting = 0;
      }
      life.hugging = false;
      press = null;
      life.pointer = null;
      life.patting = false;
      return;
    }
    if (pointers.size > 2) return;
    const point = toModel(e.clientX, e.clientY);
    const front = propAt(e.clientX, e.clientY, ['snack', 'play']);
    const onHer = !front && model?.hit(point.x, point.y);
    press = {
      id: e.pointerId,
      x: e.clientX,
      y: e.clientY,
      // Event time, not handler time: a slow frame must not turn a tap into a hold.
      at: e.timeStamp,
      prop: front ?? (onHer ? null : propAt(e.clientX, e.clientY, ['rest'])),
      zone: onHer ? zoneAt(point.x, point.y) : null,
      travel: 0,
      lastX: e.clientX,
      lastY: e.clientY,
      modelX: point.x,
    };
    life.pointer = toGaze(e.clientX, e.clientY);
    scene.marks.ripple(e.clientX, e.clientY);
    // A finger that stays on her becomes a hug.
    if (press.zone) {
      const held = press;
      held.hugTimer = setTimeout(() => startHug(held), HUG_MS);
    }
  });

  const HUG_MS = 650;
  /** How close to her mouth a carried snack must be let go to count. */
  const FEED_RADIUS = 80;

  /** Her mouth itself, following her head: where a carried snack is aimed. */
  function mouthPoint() {
    const [x, y] = toScreen(0, 0.59);
    return [x + life.head.x.x * 10, y - life.head.y.x * 6];
  }

  function warmColor() {
    const warm = getComputedStyle(document.documentElement).getPropertyValue('--warm').trim() || '242, 213, 172';
    return `rgb(${warm})`;
  }

  function startHug(held) {
    if (press !== held || held.travel >= 14 || life.patting || pointers.size !== 1) return;
    held.hugging = true;
    life.hugging = true;
    const [cx] = toScreen(0, 0.4);
    life.hugSide = held.x < cx ? 1 : -1;
    // Shy the first times; glad once she knows you.
    setEmotion(bondStep() === 0 ? 'shy' : 'happy', 30000);
    scene.marks.hearts(held.x, held.y - 18, 2);
    post({ type: 'touch', zone: held.zone, kind: 'hug' });
  }

  /** A snack carried from the dish: into her mouth if let go there, else back to the dish. */
  function endDrag(e) {
    scene.drop();
    life.expecting = 0;
    const at = [e.clientX, e.clientY];
    const mouth = mouthPoint();
    const warm = warmColor();
    if (e.type === 'pointerup' && Math.hypot(at[0] - mouth[0], at[1] - mouth[1]) < FEED_RADIUS) {
      scene.marks.toss(at, mouth, warm, { arc: 8, life: 0.28 });
      post({ type: 'object', id: 'snack' });
      const epoch = transientEpoch;
      setTimeout(() => {
        if (epoch !== transientEpoch) return;
        // The bite lands.
        setEmotion('happy', 2600);
        playAction('nodSmall');
        life.tailKick = 1;
        scene.marks.sparkles(mouth[0] + 20, mouth[1] - 20, 2);
      }, 280);
    } else {
      const dish = propRect('snack');
      if (dish) scene.marks.toss(at, center(dish), warm, { arc: 40, life: 0.5, shrink: false });
    }
  }

  if (!FLOAT) canvas.addEventListener('pointermove', (e) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    touched();
    if (pointers.size === 2) {
      const info = pinchInfo();
      camera.zoom = clamp(gesture.zoom * (info.distance / (gesture.pinch || 1)), 0.55, 3.2);
      const rect = canvas.getBoundingClientRect();
      const aspect = canvas.height / canvas.width;
      camera.x = gesture.camX - (((info.midX - gesture.midX) / rect.width) * 2) / (camera.zoom * aspect);
      camera.y = gesture.camY + (((info.midY - gesture.midY) / rect.height) * 2) / camera.zoom;
      return;
    }
    if (!press || press.id !== e.pointerId) return;
    life.pointer = toGaze(e.clientX, e.clientY);
    press.travel += Math.hypot(e.clientX - press.lastX, e.clientY - press.lastY);
    press.lastX = e.clientX;
    press.lastY = e.clientY;
    if (press.travel > 14) clearTimeout(press.hugTimer);
    // Pulled off the dish: she watches it come, mouth opening as it nears.
    if (press.prop === 'snack' && (press.dragging || press.travel > 14)) {
      press.dragging = true;
      scene.hold(e.clientX, e.clientY, warmColor());
      const [mx, my] = mouthPoint();
      life.expecting = clamp(1 - Math.hypot(e.clientX - mx, e.clientY - my) / 170, 0, 1);
      return;
    }
    if (press.zone === 'head' && press.travel > 26 && !press.hugging) {
      if (!life.patting) {
        life.patting = true;
        press.patStart = performance.now();
        post({ type: 'touch', zone: 'head', kind: 'pat' });
        setEmotion('shy', 30000);
        life.patHeartAt = 0;
      }
      if (performance.now() > life.patHeartAt) {
        life.patHeartAt = performance.now() + 420;
        scene.marks.hearts(e.clientX, e.clientY - 18, 1);
      }
      const point = toModel(e.clientX, e.clientY);
      life.patX = clamp((point.x - press.modelX) * 2.2, -1, 1);
    }
  });

  function endPointer(e) {
    if (!pointers.delete(e.pointerId)) return;
    if (!press || press.id !== e.pointerId) return;
    const quick = e.type === 'pointerup' && e.timeStamp - press.at < 420 && press.travel < 14;
    clearTimeout(press.hugTimer);
    if (press.dragging) {
      endDrag(e);
    } else if (press.hugging) {
      life.hugging = false;
      life.emotionUntil = performance.now() + 1800;
    } else if (life.patting) {
      life.patting = false;
      life.emotionUntil = performance.now() + 1600;
    } else if (quick && press.prop) {
      useProp(press.prop);
    } else if (quick && press.zone) {
      tap(press.zone, e.clientX);
    }
    press = null;
    // Her eyes stay on where the finger was for a moment.
    setTimeout(() => {
      if (!press) life.pointer = null;
    }, 700);
  }
  if (!FLOAT) canvas.addEventListener('pointerup', endPointer);
  if (!FLOAT) canvas.addEventListener('pointercancel', endPointer);
  if (!FLOAT) canvas.addEventListener('lostpointercapture', endPointer);

  function tap(zone, clientX) {
    const now = performance.now();
    taps.push(now);
    while (taps.length && now - taps[0] > 1100) taps.shift();
    const rect = canvas.getBoundingClientRect();
    const side = (clientX - rect.left) / rect.width < 0.5 ? -1 : 1;
    if (taps.length >= 3) {
      taps.length = 0;
      setEmotion('dizzy', 2400);
      playAction('shake');
      post({ type: 'touch', zone, kind: 'tease' });
      return;
    }
    const reaction = TAPS[zone] ?? TAPS.body;
    setEmotion(reaction.emotion, reaction.hold);
    playAction(reaction.action);
    if (reaction.tail) life.tailKick = 1;
    if (!REDUCED) {
      life.poke.x.v += side * -70;
      life.poke.z.v += side * 45;
      if (zone === 'tail') hop(0.8);
    }
    post({ type: 'touch', zone, kind: 'tap' });
  }

  // ── Commands from Flutter ───────────────────────────────────────────────

  const commands = {
    mood: ({ mood }) => {
      touched();
      setMood(mood);
    },
    emotion: ({ name, hold, native }) => setEmotion(name, hold, native === true),
    action: ({ name, native }) => {
      if (native === true) {
        if (!REDUCED) model?.playMotion(name);
        return;
      }
      if (name === 'hop') hop();
      else if (name === 'tail') life.tailKick = 1;
      else if (actions[name]) playAction(name);
      // Not one of hers: one of the model's own motions, by its name.
      else if (!REDUCED) model?.playMotion(name);
    },
    // New reply text arrived: the mouth keeps moving for about as long as
    // reading it aloud would take.
    say: ({ chars }) => {
      life.speech = Math.min(life.speech + chars * 0.085, 12);
      touched();
    },
    quiet: () => {
      life.speech = 0;
      life.voice = null;
    },
    // Her voice from a speech API: how loud it is every frameMs, from now.
    loudness: ({ levels, frameMs }) => {
      const valid = Array.isArray(levels) && levels.length && levels.every(Number.isFinite);
      life.voice = valid ? { levels: levels.map((v) => clamp(v, 0, 1)), frameMs: Math.max(10, frameMs || 40), start: performance.now() } : null;
      touched();
    },
    // A sentence ended while she speaks: the small dip people do between phrases.
    beat: () => {
      if (!REDUCED) life.head.y.v -= 0.55;
    },
    mouth: ({ value }) => {
      life.mouthOverride = value == null ? null : clamp(value, 0, 1);
    },
    vitals: ({ valence, energy, closeness }) => {
      const unit = (v, fallback) => (Number.isFinite(v) ? clamp(v, 0, 1) : fallback);
      life.vitals = {
        valence: unit(valence, life.vitals.valence),
        energy: unit(energy, life.vitals.energy),
        closeness: unit(closeness, life.vitals.closeness),
      };
    },
    activity: ({ name, remainingMs }) => setActivity(name, remainingMs),
    // adapter.json was written (or removed): wear it now, no reload.
    adapter: async () => {
      adapter = await loadAdapter();
      model.adapt(character, adapter);
      applyCharacter();
      post({ type: 'adapted', probe: probeReport() });
    },
    // Her invitation (shown in Flutter): a look at the cushion, bubbles from it
    // while she waits, and the cushion's short show on a yes. None of these
    // posts anything back; the rest itself comes as an activity.
    glance: ({ prop, ms }) => glanceAt(prop, ms),
    beckon: ({ prop }) => {
      home.beckon = prop && props[prop] ? { prop, next: 0 } : null;
    },
    prop: ({ name }) => showProp(name),
    covered: ({ on }) => {
      covered = on === true;
    },
    pause: () => {
      nativePaused = true;
      pause();
    },
    resume: () => {
      nativePaused = false;
      resume();
    },
  };

  // ── Loop ────────────────────────────────────────────────────────────────

  let gl = null;
  let model = null;
  // Flutter can cover this route while the WebView document stays visible.
  let nativePaused = false;
  let paused = false;
  let frame = 0;
  let last = 0;
  let drawn = 0;
  let fpsAt = performance.now();
  let fps = 0;
  // Share of the full resolution drawn: steps down while frames come late
  // (an old phone, a heavy model), never below half, and back up once they
  // keep time again. A frame is late against the rate asked when it was drawn,
  // so a second that is part busy (60) and part idle (30) isn't counted slow.
  // It starts where it last settled on this phone (`quality`, kept by the app),
  // so a phone that can't hold full resolution doesn't stutter down to it on
  // every visit, and one that can is never held back by a guess.
  let quality = clamp(Number(query.get('quality')) || 1, 0.5, 1);
  // The app keeps the level that held: a step down at once, a step up once it
  // has kept time for a minute's worth of seconds at the full rate.
  let holdSeconds = 0;
  const settled = () => post({ type: 'quality', value: Math.round(quality * 100) / 100 });
  let slowSeconds = 0;
  let quickSeconds = 0;
  let late = 0;
  // A second with frames asked at twelve (asleep, under the log) can say she's
  // slow but not that she keeps up: twelve frames are easy at any resolution.
  let easySecond = false;
  // Ten quiet seconds earn the next step up; a step up that turns slow again
  // before it has held makes the next try wait twice as long (to five minutes),
  // so a phone that only keeps up while she idles doesn't stutter every time she
  // moves just to find that out again.
  let upAfter = 10;
  // Flutter's full-screen blur over her (the log): she's barely seen, so drawn slowly.
  let covered = false;
  // Loading the model (texture upload, mipmaps) stalls a few frames; not the phone's pace.
  let settleUntil = 0;

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, DPR_CAP) * quality;
    const width = Math.round(canvas.clientWidth * dpr);
    const height = Math.round(canvas.clientHeight * dpr);
    if (width === canvas.width && height === canvas.height) return;
    canvas.width = width;
    canvas.height = height;
    model?.setRenderTargetSize(width, height);
  }

  function render(ts) {
    if (FLOAT) return renderFloat(ts);
    if (paused || document.hidden) return;
    frame = requestAnimationFrame(render);
    // Thirty frames while she idles, sixty while something's happening, and
    // twelve asleep: she's on screen for long stretches.
    const busy =
      pointers.size > 0 ||
      life.actions.size > 0 ||
      life.mood === 'speaking' ||
      life.speech > 0 ||
      life.voice !== null ||
      model?.moving ||
      life.patting ||
      home.show !== null ||
      scene.busy();
    const target = life.sleep > 0.9 || covered ? 12 : busy ? 60 : 30;
    if (ts - last < 1000 / target - 2) return;
    // Over half a second is a gap (paused, hidden, waking), not a late frame.
    const gap = ts - last;
    if (gap > 1500 / target && gap < 500) late++;
    if (target < 30) easySecond = true;
    const dt = clamp((ts - last) / 1000, 0.001, 0.05);
    last = ts;
    life.hop.step(0, dt);
    resize();
    model.tick(dt, animate);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    model.draw(projection(), [0, 0, canvas.width, canvas.height]);
    moodMarks(ts);
    scene.step(dt, life.body.x.x + tilt.sx * 0.8);
    parallax(dt);
    water(ts);
    drawn++;
    if (ts - fpsAt > 1000) {
      // A gap (paused, hidden) says nothing about how fast she draws.
      if (ts - fpsAt < 2000) {
        fps = (drawn * 1000) / (ts - fpsAt);
        if (ts >= settleUntil && drawn > 0) {
          const share = late / drawn;
          slowSeconds = share > 0.3 ? slowSeconds + 1 : 0;
          // A handful of frames can say she's slow (a very slow phone draws only
          // a few a second) but not that she keeps time.
          quickSeconds = drawn >= 5 && share < 0.1 && !easySecond ? quickSeconds + 1 : 0;
          if (slowSeconds >= 3 && quality > 0.5) {
            quality = Math.max(0.5, quality - 0.15);
            slowSeconds = 0;
            // Once per step up that didn't hold, however far it then falls.
            if (holdSeconds > 0) upAfter = Math.min(upAfter * 2, 300);
            holdSeconds = 0;
            settled();
          } else if (quickSeconds >= upAfter && quality < 1) {
            quality = Math.min(1, quality + 0.15);
            quickSeconds = 0;
            holdSeconds = 60;
          } else if (holdSeconds > 0 && quickSeconds > 0 && --holdSeconds === 0) {
            settled();
          }
        }
      }
      drawn = 0;
      late = 0;
      easySecond = false;
      fpsAt = ts;
    }
  }

  const floatGate = FLOAT ? new window.CompanionFloat.FrameGate() : null;
  const floatBounds = FLOAT ? new window.CompanionFloat.BoundsFollower() : null;
  let floatPixels = null;
  let floatState = null;
  let floatEmotion = 'calm';
  let floatGazeUntil = 0;

  function setFloatState(state, reduced) {
    if (typeof reduced === 'boolean' && reduced !== REDUCED) {
      REDUCED = reduced;
      if (reduced) {
        life.actions.clear();
        model.stopMotions();
      }
    }
    if (state === floatState) return;
    floatState = state;
    const effect = window.CompanionFloat.stateEffect(state, authored.emotions, authored.actions);
    life.actions.clear();
    model.stopMotions();
    life.mood = effect.mood;
    floatEmotion = effect.emotion;
    setEmotion(effect.emotion, Infinity);
    if (effect.action) playAction(effect.action);
  }

  function renderFloat(ts) {
    if (paused || floatDisposed || document.hidden || !model) return;
    frame = requestAnimationFrame(render);
    // Asleep on the desktop she breathes slowly: twelve frames, as in the room.
    if (!floatGate.take(ts, life.sleep > 0.9 ? 12 : 30)) return;
    try {
      const dt = clamp((ts - last) / 1000, 0.001, 0.05);
      last = ts;
      resize();
      if (floatGazeUntil && ts > floatGazeUntil) { floatGazeUntil = 0; life.pointer = null; }
      model.tick(dt, animate);
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      model.draw(projection(), [0, 0, canvas.width, canvas.height]);
      // Read in this draw task; preserveDrawingBuffer is unnecessary. The native
      // viewport is fixed and small, so the buffer stays small at device density.
      const length = canvas.width * canvas.height * 4;
      if (floatPixels?.length !== length) floatPixels = new Uint8Array(length);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, floatPixels);
      const bounds = window.CompanionFloat.opaqueBounds(floatPixels, canvas.width, canvas.height);
      const box = floatBounds.next(bounds, canvas.width, canvas.height);
      if (box !== undefined) post({ type: 'floatBounds', width: canvas.width, height: canvas.height, bounds: box });
      drawn++;
      if (ts - fpsAt >= 1000) { fps = drawn * 1000 / (ts - fpsAt); drawn = 0; fpsAt = ts; }
    } catch (_) { floatFailed('companion_render_failed'); }
  }

  /** A tap from the native window, in 0–1 of the viewport: the room's tap, without its marks. */
  function floatTap(x, y) {
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    const rect = canvas.getBoundingClientRect();
    const clientX = rect.left + clamp(x, 0, 1) * rect.width;
    const clientY = rect.top + clamp(y, 0, 1) * rect.height;
    const point = toModel(clientX, clientY);
    // Her eyes stay on where the finger was for a moment.
    life.pointer = toGaze(clientX, clientY);
    floatGazeUntil = performance.now() + 700;
    tap(zoneAt(point.x, point.y) ?? 'body', clientX);
  }

  function releaseFloat() {
    if (floatDisposed) return;
    floatDisposed = true;
    floatAbort.abort();
    const current = model;
    try { pause(); }
    finally {
      model = null;
      floatPixels = null;
      try { current?.release(); }
      finally {
        try { gl?.getExtension('WEBGL_lose_context')?.loseContext(); }
        finally { gl = null; }
      }
    }
  }

  function floatFailed(code) {
    try { releaseFloat(); } catch (_) { /* Native still destroys the page. */ }
    post({ type: 'floatError', code });
  }

  let moodMarkAt = 0;
  let thoughtStep = 0;

  /** Signs that repeat while a mood lasts. */
  function moodMarks(ts) {
    if (ts < moodMarkAt || REDUCED) return;
    const [x, y] = headOnScreen();
    if (life.mood === 'thinking') {
      scene.marks.thought(x, y, thoughtStep);
      thoughtStep = (thoughtStep + 1) % 3;
      moodMarkAt = ts + (thoughtStep === 0 ? 900 : 300);
    } else if (life.hugging) {
      scene.marks.hearts(x, y, 1);
      moodMarkAt = ts + 650;
    } else if (life.mood === 'sleeping' && life.sleep > 0.6) {
      scene.marks.zzz(x, y);
      moodMarkAt = ts + 1900;
    } else {
      moodMarkAt = ts + 400;
    }
  }

  let lastParallax = null;

  // Tilting the phone shifts the water a little, then it settles back to
  // however the phone is being held: a window into the water, not a level.
  const tilt = { x: 0, y: 0, sx: 0, sy: 0, beta: null, gamma: null };
  if (!FLOAT) window.addEventListener('deviceorientation', (e) => {
    if (REDUCED || e.beta == null || e.gamma == null) return;
    if (tilt.beta == null) {
      tilt.beta = e.beta;
      tilt.gamma = e.gamma;
    }
    tilt.beta += (e.beta - tilt.beta) * 0.004;
    tilt.gamma += (e.gamma - tilt.gamma) * 0.004;
    tilt.x = clamp((e.gamma - tilt.gamma) / 20, -1, 1);
    tilt.y = clamp((e.beta - tilt.beta) / 20, -1, 1);
  });

  // Moving the phone moves the water she floats in. `devicemotion` gives the push
  // (gravity already taken out where the phone can); three hard ones close together
  // are a shake, and that makes her dizzy.
  const motion = { push: 0, jolts: [], last: 0, shookAt: -Infinity };
  const JOLT = 14; // m/s²: a deliberate shake, well past walking or setting the phone down.
  if (!FLOAT) window.addEventListener('devicemotion', (e) => {
    if (REDUCED || paused || !model) return;
    const a = e.acceleration?.x != null ? e.acceleration : null;
    if (!a) return;
    // Below this it is a hand that isn't quite still.
    motion.push = Math.abs(a.x) < 1.5 ? 0 : clamp(a.x, -20, 20);
    const now = performance.now();
    if (Math.hypot(a.x, a.y ?? 0, a.z ?? 0) < JOLT || now - motion.last < 80) return;
    motion.last = now;
    motion.jolts.push(now);
    while (now - motion.jolts[0] > 900) motion.jolts.shift();
    if (motion.jolts.length < 3 || now - motion.shookAt < 2600) return;
    motion.jolts.length = 0;
    motion.shookAt = now;
    shaken();
  });

  /** How far the water has tipped her, about -1.5 to 1.5; zero with reduced motion. */
  function swayStep(dt) {
    if (FLOAT || REDUCED) return 0;
    // The phone goes one way and she is left behind: the push is against the motion.
    life.sway.v -= motion.push * 3 * dt;
    motion.push *= Math.max(0, 1 - dt * 12); // A sensor that stops reporting must not push forever.
    const x = life.sway.step(tilt.x, dt);
    if (Math.abs(x) > 1.5) { life.sway.x = clamp(x, -1.5, 1.5); life.sway.v = 0; }
    return life.sway.x;
  }

  function shaken() {
    touched();
    setEmotion('dizzy', 2400);
    playAction('shake');
    const [x, y] = headOnScreen();
    scene.marks.bubbles(x, y - 10, 5);
    post({ type: 'touch', zone: 'body', kind: 'shake' });
  }

  /** The far water moves a touch less than she does: depth, not a parallax show. */
  function parallax(dt) {
    if (REDUCED) return;
    tilt.sx += (tilt.x - tilt.sx) * Math.min(1, dt * 5);
    tilt.sy += (tilt.y - tilt.sy) * Math.min(1, dt * 5);
    const x = Math.round((life.body.x.x * 4 + tilt.sx * 9) * 10) / 10;
    const y = Math.round(tilt.sy * 50) / 10;
    const key = `${x},${y}`;
    if (key === lastParallax) return;
    lastParallax = key;
    reefFar.style.transform = `translate3d(${-x * 0.7}px, ${-y * 0.6}px, 0)`;
    reefNear.style.transform = `translate3d(${-x * 1.5}px, ${-y * 1.2}px, 0)`;
    sun.style.transform = `translate3d(${x * 0.4}px, ${y * 0.3}px, 0)`;
  }

  // The light shafts and the whale move on the frames she's drawn anyway. As CSS
  // animations they kept their own clock, and with it the whole page, and the
  // frosted glass Flutter lays over it, redrawing at the screen's full rate
  // (up to 120) while she idles at thirty. A shaft sways three degrees in about
  // twenty seconds and the whale crosses in thirty-seven: thirty steps a second,
  // or twelve while she sleeps, look the same.
  const SHAFTS = [
    // tilt (deg), period (s), how far into its sway it starts (s)
    [13, 21, 0],
    [6, 27, 9],
    [-3, 17, 4],
    [-11, 24, 15],
  ];
  const WHALE_S = 74;
  const looks = new Map();
  // The app's reduced motion and a bare page are fixed at load; the system's own
  // setting can change while she's open, so that one is asked on every frame.
  const stillPage = FLOAT || REDUCED || document.documentElement.dataset.bare === '1';
  const reduceQuery = (!FLOAT && window.matchMedia?.('(prefers-reduced-motion: reduce)')) || null;

  function look(el, transform, opacity) {
    if (!el?.style) return;
    const was = looks.get(el);
    if (was?.[0] === transform && was[1] === opacity) return;
    looks.set(el, [transform, opacity]);
    el.style.transform = transform;
    el.style.opacity = opacity;
  }

  function water(ts) {
    if (stillPage || reduceQuery?.matches) {
      // Turned off while she's here: the water rests as it does without motion.
      for (const el of looks.keys()) {
        el.style.transform = '';
        el.style.opacity = '';
      }
      looks.clear();
      return;
    }
    const s = ts / 1000;
    shafts.forEach((el, i) => {
      const [tilt, period, start] = SHAFTS[i % SHAFTS.length];
      // An ease in and out each way, back and forth.
      const k = 0.5 - 0.5 * Math.cos((Math.PI * (s + start)) / period);
      look(el, `rotate(${Math.round((tilt - 1.6 + 3.2 * k) * 20) / 20}deg)`, `${Math.round((0.55 + 0.45 * k) * 100) / 100}`);
    });
    // Out across the water in the first half of its round, then gone for the second.
    const p = (((s + 38) % WHALE_S) + WHALE_S) % WHALE_S / WHALE_S;
    const k = Math.min(1, p / 0.5);
    const shown = p < 0.04 ? p / 0.04 : p < 0.46 ? 1 : p < 0.5 ? (0.5 - p) / 0.04 : 0;
    look(
      whale,
      `translate3d(${Math.round((-24 + 144 * k) * 10) / 10}vw, ${Math.round((16 - 38 * k) * 4) / 4}px, 0)`,
      `${Math.round(shown * 50) / 100}`,
    );
  }

  function discardTransient() {
    transientEpoch++;
    pointers.clear();
    press = null;
    life.pointer = null;
    life.patting = false;
    life.pat = 0;
    life.speech = 0;
    life.mouth = 0;
    life.mouthOverride = null;
    life.voice = null;
    life.actions.clear();
    life.glance = null;
    life.hugging = false;
    life.hug = 0;
    life.expecting = 0;
    life.expect = 0;
    home.show = null;
    home.beckon = null;
    home.gaze = null;
    home.reach = 0;
    resetBall();
    if (!FLOAT) scene.clear();
    // One of the model's own motions doesn't carry on after she was out of sight.
    model?.stopMotions();
  }

  function pause() {
    if (paused) return;
    paused = true;
    cancelAnimationFrame(frame);
    document.documentElement.dataset.paused = '1';
    discardTransient();
  }

  function resume() {
    if (FLOAT || !paused || document.hidden) return;
    // Commands received out of sight must not replay an old short performance.
    discardTransient();
    paused = false;
    delete document.documentElement.dataset.paused;
    applyTimeOfDay();
    last = performance.now();
    if (model) frame = requestAnimationFrame(render);
  }

  document.addEventListener('visibilitychange', () => {
    if (FLOAT) {
      if (document.hidden) releaseFloat();
      else if (floatDisposed) post({ type: 'floatResume' });
    } else if (document.hidden) pause();
    else if (!nativePaused) resume();
  });
  if (FLOAT) window.addEventListener('pagehide', releaseFloat);

  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault();
    if (FLOAT) {
      if (!floatDisposed) floatFailed('companion_context_lost');
    } else pause();
  });
  canvas.addEventListener('webglcontextrestored', () => { if (!FLOAT) location.reload(); });

  /** The water follows the hour. */
  function timeOfDay(hour) {
    if (hour >= 5 && hour < 8) return 'dawn';
    if (hour >= 8 && hour < 17) return 'day';
    if (hour >= 17 && hour < 19) return 'dusk';
    return 'night';
  }

  const TINTS = { dawn: [1, 0.98, 0.96], day: [1, 1, 1], dusk: [1, 0.95, 0.93], night: [0.92, 0.94, 1] };

  function applyTimeOfDay() {
    if (FLOAT) return;
    const hour = Number(query.get('hour') ?? new Date().getHours());
    const tod = query.get('tod') ?? timeOfDay(hour);
    document.documentElement.dataset.tod = tod;
    // Past eleven and before five she's drowsy.
    life.drowsy = tod === 'night' && (hour >= 23 || hour < 5) ? 1 : 0;
    scene.configure({ night: tod === 'night', reducedMotion: REDUCED });
    const [r, g, b] = TINTS[tod] ?? TINTS.day;
    model?.getRenderer().setModelColor(r, g, b, 1);
  }

  async function boot() {
    const started = performance.now();
    if (REDUCED) document.documentElement.dataset.motion = 'reduced';
    applyTimeOfDay();
    if (!FLOAT) {
      scene.resize();
      window.addEventListener('resize', () => scene.resize());
      // The water already where it will be on her first frame.
      water(performance.now());
    }
    try {
      const response = await fetch(`${CHARACTER}character.json`, { signal: floatAbort?.signal });
      character = response.ok ? await response.json() : {};
      adapter = await loadAdapter();
      applyCharacter();
      if (floatDisposed) return;

      Fw.CubismFramework.startUp(Object.assign(new Fw.Option(), { logFunction: () => {}, loggingLevel: Fw.LogLevel?.LogLevel_Off ?? 5 }));
      Fw.CubismFramework.initialize();

      // MSAA costs a lot of fill on a phone (13 → 24 fps on an old one) and
      // shows little on a dense screen, where the canvas is drawn at 2×.
      const antialias = query.get('antialias') === '1' || (query.get('antialias') !== '0' && (window.devicePixelRatio || 1) < 1.5);
      // Cubism never depth-tests, so no depth buffer.
      const options = { alpha: true, depth: false, premultipliedAlpha: true, antialias, preserveDrawingBuffer: query.get('capture') === '1' };
      gl = canvas.getContext('webgl2', options) || canvas.getContext('webgl', options);
      if (!gl || (FLOAT && !gl.getContextAttributes()?.alpha)) throw new Error('webgl');
      canvas.width = canvas.height = 0;
      resize();

      const next = new StageModel();
      if (FLOAT) loadingModel = next;
      await next.load(gl, character);
      if (floatDisposed) { loadingModel = null; next.release(); return; }
      next.adapt(character, adapter);
      model = next;
      loadingModel = null;
      settleUntil = performance.now() + 3000;
      applyCharacter();
      applyTimeOfDay();
      if (!FLOAT) setInterval(applyTimeOfDay, 10 * 60 * 1000);
      setEmotion('calm');
      // A hello, so opening the page is already a small event.
      if (!FLOAT) playAction('nodSmall');
      last = performance.now();
      if (document.hidden) { if (FLOAT) releaseFloat(); else pause(); }
      if (!paused) frame = requestAnimationFrame(render);
      document.documentElement.dataset.ready = '1';
      // Early morning: she's only just up. A stretch, then a yawn, once the
      // greeting has settled.
      if (!FLOAT && document.documentElement.dataset.tod === 'dawn' && !REDUCED) {
        life.waking = ['stretch', 'yawn'];
        life.flourishAt = performance.now() + 6000;
      }
      if (FLOAT) { post({ type: 'floatReady' }); return; }
      post({
        type: 'ready',
        ms: Math.round(performance.now() - started),
        name: character.name ?? null,
        expressions: [...model.expressions.keys()],
        motions: [...model.motions.keys()],
        probe: probeReport(),
      });
    } catch (error) {
      if (FLOAT) {
        const unfinished = loadingModel;
        loadingModel = null;
        try { unfinished?.release(); } catch (_) { /* GL/page termination remains mandatory. */ }
        if (!floatDisposed) floatFailed('companion_render_failed');
        return;
      }
      post({ type: 'error', message: String(error?.message ?? error) });
      document.documentElement.dataset.ready = 'error';
      document.documentElement.dataset.error = String(error?.stack ?? error);
    }
  }

  function mergeEmotions(custom) {
    const merged = { ...DEFAULT_EMOTIONS };
    if (custom && typeof custom === 'object') {
      for (const [name, def] of Object.entries(custom)) {
        if (def && typeof def === 'object') merged[name] = { ...merged[name], ...def };
      }
    }
    return merged;
  }

  window.stage = {
    command(message) {
      if (FLOAT) {
        if (message?.type === 'dispose' || message?.type === 'pause') releaseFloat();
        else if (!floatDisposed && model && message?.type === 'freeze') pause();
        else if (!floatDisposed && model && message?.type === 'thaw' && paused && !document.hidden) {
          paused = false;
          delete document.documentElement.dataset.paused;
          last = performance.now();
          frame = requestAnimationFrame(render);
        } else if (!floatDisposed && model && message?.type === 'petState') setFloatState(message.state, message.reduceMotion);
        else if (!floatDisposed && model && message?.type === 'tap') floatTap(message.x, message.y);
        return;
      }
      const run = commands[message?.type];
      if (run && model) run(message);
    },
    // For the verification harness; nothing in the app reads it.
    debug: () => ({
      fps,
      quality,
      quality,
      masks: model?.masks ?? null,
      zones,
      zonesFrom,
      camera: { ...camera },
      mood: life.mood,
      emotion: life.emotion,
      patting: life.patting,
      hugging: life.hugging,
      hug: life.hug,
      expect: life.expect,
      mouthAt: model ? mouthPoint() : null,
      tilt: [tilt.sx, tilt.sy],
      drowsy: life.drowsy,
      waking: [...life.waking],
      bond: bondStep(),
      choices: idleChoices(),
      zoom: camera.zoom,
      paused,
      drawables: model?.core.getDrawableCount() ?? 0,
      canvas: [canvas.width, canvas.height],
      model,
    }),
  };

  boot();
})();
