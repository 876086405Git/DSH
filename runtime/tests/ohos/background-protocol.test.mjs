import { symlinkFixture } from './host-link-fixture.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, cp, rm } from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
test('new owner refuses original pinned scheduler without synchronous admission seam', async t=>{
 assert(process.env.DSH_BACKGROUND_OLD_PREFIX,'supply the unchanged 718 OH prefix');
 const directory=await mkdtemp(join(tmpdir(),'background-protocol-'));t.after(()=>rm(directory,{recursive:true,force:true}));
 await cp(new URL('../../ohos/lifecycle/',import.meta.url),join(directory,'lifecycle'),{recursive:true});
 await symlinkFixture(join(process.env.DSH_BACKGROUND_OLD_PREFIX,'node_modules'),join(directory,'node_modules'),'dir');
 globalThis[Symbol.for('dsh.go.ohos.sim')]=true;
 const {apply}=await import(pathToFileURL(join(directory,'lifecycle/index.mjs')));
 await assert.rejects(apply({}),{code:'ERR_OHOS_LIFECYCLE_PROTOCOL'});
});
