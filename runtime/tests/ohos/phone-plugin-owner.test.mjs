import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import vm from 'node:vm';
const ts=createRequire(resolve(process.env.OHOS_TYPESCRIPT_PREFIX,'package.json'))('typescript');
const source=new URL('../../../app/ohos/entry/src/main/ets/runtime/RuntimePlugin.ets',import.meta.url);
const js=ts.transpileModule(readFileSync(source,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2022,module:ts.ModuleKind.CommonJS}}).outputText;
function plugin(){const module={exports:{}};vm.runInNewContext(js,{module,exports:module.exports,require:()=>({})});return new module.exports.RuntimePlugin();}
test('actual Ability binding detach synchronously retires phone owner before clearing context',()=>{
 const p=plugin();const ability={};p.ability=ability;let retired=0;
 p.phone={retire(){assert.equal(p.ability,ability);retired++;}};
 p.onDetachedFromAbility();assert.equal(retired,1);assert.equal(p.ability,null);
});
test('native retire exception still clears detached Ability context',()=>{
 const p=plugin();p.ability={};p.phone={retire(){throw new Error('native failure');}};
 assert.doesNotThrow(()=>p.onDetachedFromAbility());assert.equal(p.ability,null);
});

test('same Ability binding is idempotent; a different binding retires the old owner',()=>{
 const p=plugin();const old={};let retired=0;p.phone={retire(){retired++;}};
 p.onAttachedToAbility(old);p.onAttachedToAbility(old);assert.equal(retired,0);
 const next={};p.onAttachedToAbility(next);assert.equal(retired,1);assert.equal(p.ability,next);
});
