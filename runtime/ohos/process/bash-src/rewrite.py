"""Local OH-only fixes applied to exactly pinned just-bash 3.6.0 ESM inputs.

Inputs and outputs are reviewed published JavaScript, not an upstream TS
rebuild. Each replacement has one occurrence after whole-file verification.
"""

def rewrite(inputs):
    texts = {name: data.decode('utf-8') for name, data in inputs.items()}

    def denial(error):
        return f'({error}?.code==="EACCES"||({error} instanceof Error&&/^EACCES:/.test({error}.message)))'

    def change(name, before, after):
        if texts[name].count(before) != 1:
            raise ValueError('unique pinned anchor mismatch: ' + before[:100])
        texts[name] = texts[name].replace(before, after)
    def change_many(name, before, after, expected):
        if texts[name].count(before) != expected:
            raise ValueError('fixed pinned anchor count mismatch: ' + before[:100])
        texts[name] = texts[name].replace(before, after)
    # Catch sites: cd, input/readwrite descriptor, direct input redirection, cat.
    index = 'index.js'
    cat = 'chunks/chunk-MHDZERK4.js'
    change(index, 'catch{return T(`bash: cd: ${n}: No such file or directory\n`)}', 'catch(ohosError){return T(`bash: cd: ${n}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`)}')
    change(index, 'catch{if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};', 'catch(ohosError){if(' + denial('ohosError') + ')return{error:L("",`bash: ${t}: EACCES: Permission denied\n`,1)};if(!n)return{error:L("",`bash: ${t}: No such file or directory\n`,1)};')
    change(index, '}catch{return{error:L("",`bash: ${t}: No such file or directory\n`,1)}}}}var Ip=', '}catch(ohosError){return{error:L("",`bash: ${t}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1)}}}}var Ip=')
    change(index, 'catch{return h(L("",`bash: ${v}: No such file or directory\n`,1),y)}}else if(g.operator==="<>")', 'catch(ohosError){return h(L("",`bash: ${v}: ${' + denial('ohosError') + '?"EACCES: Permission denied":"No such file or directory"}\n`,1),y)}}else if(g.operator==="<>")')
    change(cat, '$(T),h+=`cat: ${y}: No such file or directory\n`,d=1', '$(T),h+=`cat: ${y}: ${' + denial('T') + '?"EACCES: Permission denied":"No such file or directory"}\n`,d=1')
    change(index, 'r.appendResult(i,ii(i))', 'r.appendResult(i)')
    change(index, 'n.appendResult(f,ii(f))', 'n.appendResult(f)')
    change(index, 't.stdout=jf(t.stdout),t.stderr=jf(t.stderr),t', 'Kf(t)!=="bytes"&&t.stdoutKind!=="text"&&(t.stdout=jf(t.stdout)),t.stderrKind!=="bytes"&&t.stderrKind!=="text"&&(t.stderr=jf(t.stderr)),t')
    # The host enters through the single, literal bash/sh command. Its first
    # nested exec is the requested shell program; only that executeScript call
    # receives the sink. Captures, pipelines, functions, eval/source and nested
    # shells retain their normal result-routing semantics. A completed outer
    # statement is delivered after accounting and redirection, then forgotten
    # by this accumulator; the shared ExecutionScope budget is never reset.
    change(index, 'async exec(t,n){let r=new jr(this.limits,n?.signal),s;', 'async exec(t,n){if(n?.ohosStatementOutput!==void 0&&(typeof n.ohosStatementOutput!=="function"||(t!=="bash"&&t!=="sh")))throw new TypeError("OHOS statement sink requires a literal bash/sh entry");let r=new jr(this.limits,n?.signal),s;')
    change(index, 'this.execInScope(t,n,r,0,n?.signal,!1,!1)', 'this.execInScope(t,n,r,0,n?.signal,!1,!1,n?.ohosStatementOutput)')
    change(index, 'async execInScope(t,n,r,s,i,o=!1,a=!0){', 'async execInScope(t,n,r,s,i,o=!1,a=!0,ohosStatementOutput){')
    change(index, 'exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D)', 'exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D,!0,ohosStatementOutput)')
    change(index, 'N=await new Nr(k,m).executeScript(b)', 'N=await new Nr(k,m).executeScript(b,s===1?ohosStatementOutput:void 0)')
    change(index, 'async executeScript(t){this.assertDefenseContext("execution");', 'async executeScript(t,ohosStatementOutput){this.assertDefenseContext("execution");')
    change(index, 'r.appendResult(i),n=i.exitCode,this.ctx.state.lastExitCode=n', 'r.appendResult(i),ohosStatementOutput&&(await ohosStatementOutput(r.build(i.exitCode)),r.ohosResetAfterDelivery()),n=i.exitCode,this.ctx.state.lastExitCode=n')
    # Keep arbitrary bytes through aggregation; return text only for an exact
    # UTF-8 round trip so existing Unicode compound-command paths retain shape.
    accumulator = 'chunks/chunk-J2OBOJ64.js'
    change(accumulator, 'import{a as i}from"./chunk-GN6CQ3J4.js";', 'import{a as i,d as ohosDecode,e as ohosEncode}from"./chunk-GN6CQ3J4.js";')
    change(accumulator, 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(s)', 's&&(t==="stdout"?this.stdoutChunks:this.stderrChunks).push(r==="text"?ohosEncode(s):s)')
    change(accumulator, 'build(t,s){return{stdout:this.stdoutChunks.join(""),', 'build(t,s){let ohosRaw=this.stdoutChunks.join(""),ohosText=ohosDecode(ohosRaw),ohosValid=ohosEncode(ohosText)===ohosRaw;return{stdout:ohosValid?ohosText:ohosRaw,')
    change(accumulator, 'exitCode:t,...s,internalOutputAccounting:', 'exitCode:t,...s,stderrKind:"bytes",stdoutKind:ohosValid?"text":"bytes",stdoutEncoding:ohosValid?void 0:"binary",internalOutputAccounting:')
    # Control-flow transfers use the accumulator's raw byte string. Decoding
    # belongs at an explicitly textual consumer, never at an error boundary.
    change(accumulator, 'get stderr(){return this.stderrChunks.join("")}', 'ohosResetAfterDelivery(){this.stdoutChunks.length=0,this.stderrChunks.length=0,this.stdoutBytes=0,this.stderrBytes=0}get stderr(){return this.stderrChunks.join("")}')
    # stderr is a byte string inside the OH interpreter. Text diagnostics enter
    # through explicit UTF-8 conversion; routing and aggregation never guess
    # encoding from byte values. No shared/npm built-in is modified.
    change(index, 'async function mn(', 'function ohosStderrBytes(t){return t.stderrKind==="bytes"?t.stderr:Ut(t.stderr)}function ohosStderrResult(t){return t.stderrKind==="bytes"?t:{...t,stderr:ohosStderrBytes(t),stderrKind:"bytes"}}function ohosOutputMetadata(t){return{stdoutKind:Kf(t),stderrKind:t.stderrKind,internalOutputAccounting:t.internalOutputAccounting}}async function mn(')
    change(index, 'let{stdout:l,stderr:c,exitCode:u}=t,d=t.stdoutKind==="bytes"||t.stdoutKind===void 0&&t.stdoutEncoding==="binary"?"binary":"utf8",h=b=>d,', 'let l=_t(t),c=ohosStderrBytes(t),u=t.exitCode,d="binary",h=b=>d,')
    change(index, 'case"file":await k(P,A,N?h(A):Du(A));break;', 'case"file":await k(P,A,"binary");break;')
    change(index, 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,N?h(A):Du(A));break;', 'case"descriptor":await vo(e,P.source.entry,P.source.descriptors,A,"binary");break;')
    # A dup keeps the prepared open-description identity. In particular,
    # 2>file 1>&2 must not append stdout and then truncate it with stderr.
    # Equal path names from two independent opens are deliberately not aliases.
    change(index, 'if(l!==""||c!==""){let b=l,v=c;', 'if(i.get(1)===i.get(2)&&["output","readwrite"].includes(i.get(1)?.kind))p=m=S(1);if(l!==""||c!==""){let b=l,v=c;')
    # Scoped file redirections have already performed their open/truncate in
    # prepare. Each independent open starts at offset zero; delivering its
    # buffered output must preserve a longer tail written by another open.
    # This is not a path-equality merge and does not change persistent FDs.
    change(index, 'A.append?await e.fs.appendFile(A.path,P,N):await e.fs.writeFile(A.path,P,N)', 'A.append?await e.fs.appendFile(A.path,P,N):await e.fs.writeFile(A.path,P,{encoding:N,ohosOverwriteAtStart:true})')
    # Keep the fixed ReadWriteFs mutation queue, canonical-path validation,
    # special-file refusal and copy-on-write policy. Empty append isolates a
    # multiply-linked inode using the existing bounded copy implementation;
    # the subsequent writable handle starts at zero without truncation. If a
    # host races in another hard link after isolation, refuse rather than
    # mutating that linked inode. No additional read permission is needed for
    # an ordinary single-link write-only file.
    change(index, 'async writeFile(t,n,r){await this.withFilesystemMutation(()=>this.writeFileUnlocked(t,n,r))}', 'async writeFile(t,n,r){await this.withFilesystemMutation(async()=>{r?.ohosOverwriteAtStart===true&&await this.appendFileUnlocked(t,new Uint8Array(),r);await this.writeFileUnlocked(t,n,r)})}')
    change(index, 'await d.truncate(0),await d.writeFile(a)', 'r?.ohosOverwriteAtStart===true||await d.truncate(0),await d.writeFile(a)')
    change(index, 'await this.replaceFile(i,a,u)', 'if(r?.ohosOverwriteAtStart===true&&u!==null)throw new Error(`EACCES: file became multiply-linked during scoped output write, ${t}`);await this.replaceFile(i,a,u)')
    # The fixed in-memory backend also serves virtual descriptor paths. It
    # implements the same private write option with its existing allocation
    # gate; arbitrary custom filesystem implementations are not advertised.
    change(index, 'async writeFile(t,n,r){this.writeFileSync(t,n,r)}', 'async writeFile(t,n,r){if(r?.ohosOverwriteAtStart===true&&await this.exists(t)){let ohosOld=await this.readFileBuffer(t),ohosNew=Ft(n,ot(r));if(ohosOld.byteLength>ohosNew.byteLength){this.assertCanAllocate(this.resolvePathWithSymlinks(t),ohosOld.byteLength);let ohosMerged=ohosOld.slice();ohosMerged.set(ohosNew);n=ohosMerged}}this.writeFileSync(t,n,r)}')
    # A scoped group/function must route a completed child command before the
    # next command can truncate the same file. Keep output open descriptions
    # as private objects: dup and copied descriptor maps share their cursor,
    # while each new Zn open receives a different object starting at zero.
    change(index, 'function Pp(e){if(e.startsWith(po))', 'function Pp(e){if(e!==null&&typeof e==="object"&&e.kind==="output")return e;if(e.startsWith(po))')
    change(index, 'case"output":return`${e.append?mo:po}${e.path}`;', 'case"output":return e;')
    change(index, 'return{entry:{kind:"output",path:i,append:n}}', 'return{entry:{kind:"output",path:i,append:n,position:0}}')
    change(index, 'm=(y,g)=>{y!==null&&y<Se&&a.set(y,g),r.policy==="persistent"&&y!==null&&y<Se&&(e.state.closedStandardFds?.delete(y),ct(e,y,g))}', 'm=(y,g)=>{y!==null&&y<Se&&(r.policy==="persistent"?(a.set(y,g),e.state.closedStandardFds?.delete(y),ct(e,y,g)):E(y,g))}')
    change(index, 'r.policy==="persistent"&&(Rt(e,b),e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(b))', '(r.policy==="persistent"||ohosSnapshotStandard(e,r,b))&&(Rt(e,b),e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(b))')
    change(index, 'r.policy==="persistent"&&(Rt(e,A.sourceFd),e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(A.sourceFd))', '(r.policy==="persistent"||ohosSnapshotStandard(e,r,A.sourceFd))&&(Rt(e,A.sourceFd),e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(A.sourceFd))')
    change(index, 'if(i.get(1)===i.get(2)&&["output","readwrite"].includes(i.get(1)?.kind))p=m=S(1);', 'i.get(1)?.kind==="output"&&(p=S(1)),i.get(2)?.kind==="output"&&(m=S(2));if(i.get(1)===i.get(2)&&["output","readwrite"].includes(i.get(1)?.kind))p=m=S(1);')
    change(index, 'if(t.kind==="output")return await e.fs.appendFile(t.path,r,s),!0;', 'if(t.kind==="output"){let ohosBytes=s==="binary"?r:Ut(r);if(t.append)await e.fs.appendFile(t.path,ohosBytes,"binary");else{let ohosAt=t.position??0;await e.fs.writeFile(t.path,ohosBytes,{encoding:"binary",ohosWritePosition:ohosAt});t.position=ohosAt+ohosBytes.length}return!0;}')
    change(index, 'n.length>0&&(t=e.executionScope.accountResult(t,"redirection"));', '(n.length>0||e.state.fileDescriptors?.has(1)||e.state.fileDescriptors?.has(2))&&(t=e.executionScope.accountResult(t,"redirection"));')
    # These are capture boundaries, not inherited file sinks. Restore the
    # exact descriptor/closed state even when the nested command throws.
    capture = ('async function ohosCaptureOutput(e,fds,run){let saved=new Map,closed=new Map;'
               'for(let fd of fds){pn(e,saved,fd);closed.set(fd,e.state.closedStandardFds?.has(fd)===true);'
               'e.state.closedStandardFds?.delete(fd);ct(e,fd,{kind:"dup-out",sourceFd:fd})}'
               'try{return await run()}finally{Fs(e,saved);for(let[fd,wasClosed]of closed)'
               'wasClosed?(e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(fd)):e.state.closedStandardFds?.delete(fd)}}')
    position = ('function ohosWritePosition(r){if(r?.ohosWritePosition!==void 0){let p=r.ohosWritePosition;'
                'if(!Number.isSafeInteger(p)||p<0)throw new RangeError("Invalid OH output write position");return p}'
                'return r?.ohosOverwriteAtStart===true?0:void 0}')
    pipe_both = ('function ohosPipeBoth(g){return{...g,redirections:[...(g.redirections??[]),'
                 '{type:"Redirection",fd:2,operator:">&",target:{type:"Word",parts:[{type:"Literal",value:"1"}]}}]}}')
    snapshot = ('function ohosSnapshotStandard(e,r,fd){pn(e,r.standardSnapshot,fd);'
                'r.standardClosedSnapshot.has(fd)||r.standardClosedSnapshot.set(fd,e.state.closedStandardFds?.has(fd)===true);return true}')
    change(index, 'async function mn(', capture + position + pipe_both + snapshot + 'async function mn(')
    # |& applies its implicit 2>&1 after the command's explicit redirects.
    # Route it through the same prepared alias, not a later stderr+stdout join.
    change(index, 'N=await n(g,s)', 'N=await(u&&!b?ohosCaptureOutput(e,[1],()=>n((t.pipeStderr?.[y]??!1)?ohosPipeBoth(g):g,s)):n(g,s))')
    change(index, 'e.state.suppressVerbose=!0;try{let h=await e.executeScript(t.body)', 'e.state.suppressVerbose=!0;try{let h=await ohosCaptureOutput(e,[1],()=>e.executeScript(t.body))')
    change(index, 'if(t.direction==="input"){let o=await Jc(e,t.body,void 0)', 'if(t.direction==="input"){let o=await ohosCaptureOutput(e,[1],()=>Jc(e,t.body,void 0))')
    # Extend the same root-serialized, copy-on-write and no-follow write path.
    # A position write uses a write-only handle and does not read a whole file.
    change(index, 'r?.ohosOverwriteAtStart===true&&await this.appendFileUnlocked(t,new Uint8Array(),r);await this.writeFileUnlocked(t,n,r)', 'ohosWritePosition(r)!==void 0&&await this.appendFileUnlocked(t,new Uint8Array(),r);await this.writeFileUnlocked(t,n,r)')
    change(index, 'async writeFile(t,n,r){await this.withFilesystemMutation(async()=>{ohosWritePosition(r)!==void 0', 'async writeFile(t,n,r){let ohosAt=ohosWritePosition(r);if(ohosAt!==void 0){n=Ft(n,ot(r));if(!Number.isSafeInteger(ohosAt+n.byteLength))throw new RangeError("OH output position overflow");r={...r,ohosWritePosition:ohosAt}}await this.withFilesystemMutation(async()=>{ohosWritePosition(r)!==void 0')
    change(index, 'r?.ohosOverwriteAtStart===true||await d.truncate(0),await d.writeFile(a);return', 'let ohosAt=ohosWritePosition(r);if(ohosAt===void 0){await d.truncate(0);await d.writeFile(a)}else{if(!Number.isSafeInteger(ohosAt+a.byteLength))throw new RangeError("OH output position overflow");let ohosDone=0;while(ohosDone<a.byteLength){let{bytesWritten:ohosCount}=await d.write(a,ohosDone,a.byteLength-ohosDone,ohosAt+ohosDone);if(ohosCount===0)throw new Error("EIO: OH output write made no progress");ohosDone+=ohosCount}}return')
    change(index, 'if(r?.ohosOverwriteAtStart===true&&u!==null)', 'if(ohosWritePosition(r)!==void 0&&u!==null)')
    change(index, 'async writeFile(t,n,r){if(r?.ohosOverwriteAtStart===true&&await this.exists(t)){let ohosOld=await this.readFileBuffer(t),ohosNew=Ft(n,ot(r));if(ohosOld.byteLength>ohosNew.byteLength){this.assertCanAllocate(this.resolvePathWithSymlinks(t),ohosOld.byteLength);let ohosMerged=ohosOld.slice();ohosMerged.set(ohosNew);n=ohosMerged}}this.writeFileSync(t,n,r)}', 'async writeFile(t,n,r){let ohosAt=ohosWritePosition(r);if(ohosAt!==void 0){let ohosOld=await this.exists(t)?await this.readFileBuffer(t):new Uint8Array,ohosNew=Ft(n,ot(r)),ohosSize=Math.max(ohosOld.byteLength,ohosAt+ohosNew.byteLength);if(!Number.isSafeInteger(ohosSize))throw new RangeError("OH output position overflow");this.assertCanAllocate(this.resolvePathWithSymlinks(t),ohosSize);let ohosMerged=new Uint8Array(ohosSize);ohosMerged.set(ohosOld);ohosMerged.set(ohosNew,ohosAt);n=ohosMerged}this.writeFileSync(t,n,r)}')
    # Live output has a stable destination identity. Routing consumes the
    # command's bytes once; compound results cannot reinterpret that identity.
    # The private WeakMap keeps collector storage out of exposed FD records.
    live = ('var ohosLiveData=new WeakMap;'
            'function ohosNewSink(fd){let s={kind:"dup-out",sourceFd:fd};ohosLiveData.set(s,{chunks:[],bytes:0});return s}'
            'function ohosCreateOutput(){return{stdout:ohosNewSink(1),stderr:ohosNewSink(2)}}'
            'function ohosDefaultEntry(e,fd){return fd===1?e.ohosOutput.stdout:e.ohosOutput.stderr}'
            'function ohosSinkFor(e,s){return ohosLiveData.has(s)?s:ohosDefaultEntry(e,s.sourceFd)}'
            'function ohosAppendSink(s,b){let d=ohosLiveData.get(s);if(!d)throw new Error("Missing OH live output owner");if(b){d.chunks.push(b);d.bytes+=b.length}}'
            'function ohosTakeSink(s){let d=ohosLiveData.get(s),b=d.chunks.join("");d.chunks=[];d.bytes=0;return b}'
            'function ohosDrainOutput(o,t){let p=ohosTakeSink(o.stdout),q=ohosTakeSink(o.stderr),a=p+_t(t),b=q+ohosStderrBytes(t),at=Qf(a),bt=Qf(b),av=Ut(at)===a,bv=Ut(bt)===b;'
            'let r={...t,stdout:av?at:a,stderr:bv?bt:b,stdoutKind:av?"text":"bytes",stderrKind:bv?"text":"bytes",internalOutputAccounting:{stdout:p.length+(t.internalOutputAccounting?.stdout??0),stderr:q.length+(t.internalOutputAccounting?.stderr??0)}};'
            'if(av)delete r.stdoutEncoding;else r.stdoutEncoding="binary";return r}'
            'function ohosCapturedOutput(s,t){let a=s.has(1)?ohosTakeSink(s.get(1)):"",b=s.has(2)?ohosTakeSink(s.get(2)):"";return{...t,stdout:a,stderr:b,stdoutKind:"bytes",stdoutEncoding:"binary",stderrKind:"bytes",internalOutputAccounting:{stdout:a.length,stderr:b.length}}}'
            'function ohosInheritDescriptors(t,s){t.fileDescriptors=s.fileDescriptors?new Map(s.fileDescriptors):void 0;t.inputFds=s.inputFds?new Set(s.inputFds):void 0;t.fdAliases=Mm(s.fdAliases);t.closedStandardFds=s.closedStandardFds?new Set(s.closedStandardFds):void 0;t.nextFd=s.nextFd}'
            'function ohosRoutingDiagnostic(e,t){let b=Ut(t);e.executionScope.appendOutput("stderr",b,"redirection diagnostic",0,"bytes");return b}')
    capture_live = ('async function ohosCaptureOutput(e,fds,run){let saved=new Map,closed=new Map,sinks=new Map;'
                    'for(let fd of fds){pn(e,saved,fd);closed.set(fd,e.state.closedStandardFds?.has(fd)===true);e.state.closedStandardFds?.delete(fd);let s=ohosNewSink(fd);sinks.set(fd,s);ct(e,fd,s)}'
                    'try{try{let t=await run();await mn(e,t,[],new Map);return ohosCapturedOutput(sinks,t)}catch(error){if(error instanceof _n){await Po(e,error,[],{targets:new Map,dupSources:new Map,standardRoutes:new Map});'
                    'let t=ohosCapturedOutput(sinks,{exitCode:error.exitCode});error.stdout=t.stdout;error.stderr=t.stderr;error.stdoutKind="bytes";error.stderrKind="bytes";error.internalOutputAccounting=t.internalOutputAccounting}throw error}}'
                    'finally{Fs(e,saved);for(let[fd,wasClosed]of closed)wasClosed?(e.state.closedStandardFds??=new Set,e.state.closedStandardFds.add(fd)):e.state.closedStandardFds?.delete(fd)}}')
    change(index, capture, capture_live)
    change(index, 'async function mn(', live + 'async function mn(')
    change(index, 'typeof e==="object"&&e.kind==="output"', 'typeof e==="object"&&(e.kind==="output"||e.kind==="dup-out")')
    change(index, 'case"dup-out":return`${yo}${e.sourceFd}`;', 'case"dup-out":return e;')
    change(index, 'Dp=(e,t,n)=>{let r=nt(e,t);', 'Dp=(e,t,n)=>{let r=nt(e,t)??(t>0&&t<3&&!e.state.closedStandardFds?.has(t)?ohosDefaultEntry(e,t):void 0);')
    change(index, 'o(1,{kind:"dup-out",sourceFd:1})', 'o(1,ohosDefaultEntry(e,1))')
    change(index, 'o(2,{kind:"dup-out",sourceFd:2})', 'o(2,ohosDefaultEntry(e,2))')
    change(index, 'if(t==="/dev/stdout")return{entry:{kind:"dup-out",sourceFd:1}};', 'if(t==="/dev/stdout")return{entry:nt(e,1)??ohosDefaultEntry(e,1)};')
    change(index, 'if(t==="/dev/stderr")return{entry:{kind:"dup-out",sourceFd:2}};', 'if(t==="/dev/stderr")return{entry:nt(e,2)??ohosDefaultEntry(e,2)};')
    change(index, '(n.length>0||e.state.fileDescriptors?.has(1)||e.state.fileDescriptors?.has(2))&&(t=e.executionScope.accountResult(t,"redirection"));', 't=e.executionScope.accountResult(t,"redirection");')
    change(index, 'n.length>0||e.state.fileDescriptors?.has(1)===!0||e.state.fileDescriptors?.has(2)===!0', '!0')
    change(index, 'p={kind:"live-stdout"},m={kind:"live-stderr"}', 'p={kind:"ohos-sink",sink:ohosDefaultEntry(e,1)},m={kind:"ohos-sink",sink:ohosDefaultEntry(e,2)}')
    change(index, 'if(b.entry.kind==="dup-out"){if(b.entry.sourceFd===1)return{kind:"live-stdout"};if(b.entry.sourceFd===2)return{kind:"live-stderr"}}', 'if(b.entry.kind==="dup-out")return{kind:"ohos-sink",sink:ohosSinkFor(e,b.entry)};')
    change(index, 'v.kind==="dup-out"?v.sourceFd===1?{kind:"live-stdout"}:v.sourceFd===2?{kind:"live-stderr"}:null:', 'v.kind==="dup-out"?{kind:"ohos-sink",sink:ohosSinkFor(e,v)}:')
    change(index, 'i.get(1)?.kind==="output"&&(p=S(1)),i.get(2)?.kind==="output"&&(m=S(2));', 'p=S(1)??p,m=S(2)??m;')
    change(index, 'case"live-stdout":l+=A;', 'case"ohos-sink":ohosAppendSink(P.sink,A);break;case"live-stdout":l+=A;')
    change(index, 'executionScope:t.executionScope,execFn:t.exec,', 'executionScope:t.executionScope,ohosOutput:t.ohosOutput,execFn:t.exec,')
    change(index, 'async execInScope(t,n,r,s,i,o=!1,a=!0,ohosStatementOutput){let l=f=>a?this.logResult(f):f,', 'async execInScope(t,n,r,s,i,o=!1,a=!0,ohosStatementOutput,ohosParent){let ohosOutput=ohosParent?.ohosOutput??ohosCreateOutput(),l=f=>{let v=ohosParent?f:ohosDrainOutput(ohosOutput,f);return a?this.logResult(v):v},')
    change(index, 'signal:u.signal,extraArgs:u.args},E=t;', 'signal:u.signal,extraArgs:u.args},E=t;ohosParent&&ohosInheritDescriptors(m,ohosParent.state);')
    change(index, 'executionScope:r,exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D,!0,ohosStatementOutput),', 'executionScope:r,ohosOutput,exec:(x,C,D=!1)=>this.execInScope(x,C,r,s+1,u.signal,D,!0,ohosStatementOutput,{state:m,ohosOutput}),')
    change(index, 'await ohosStatementOutput(r.build(i.exitCode))', 'await ohosStatementOutput(ohosDrainOutput(this.ctx.ohosOutput,r.build(i.exitCode)))')
    change(index, 'let f=await this.executePipeline(c);n.appendResult(f)', 'let f=await this.executePipeline(c);f=await mn(this.ctx,f,[],new Map);n.appendResult(f)')
    change(index, 'this.ctx.state.options.verbose&&!this.ctx.state.suppressVerbose&&t.sourceText&&n.append("stderr",`${t.sourceText}\n`);', 'this.ctx.state.options.verbose&&!this.ctx.state.suppressVerbose&&t.sourceText&&await mn(this.ctx,L("",`${t.sourceText}\n`,0),[],new Map);')

    change(index, 'if(t.stdoutKind&&(y.stdoutKind=t.stdoutKind),t.stdoutEncoding==="binary"&&(y.stdoutEncoding="binary"),', 'if(y.stdoutKind="bytes",y.stdoutEncoding="binary",y.stderrKind="bytes",')
    change(index, 'v=M(y.stdout),k=M(y.stderr),A=Math.min(v,b);', 'v=y.stdout.length,k=y.stderr.length,A=Math.min(v,b);')
    change(index, 'l=this.appendOutput("stderr",t.stderr,n,o);', 'l=this.appendOutput("stderr",t.stderr,n,o,t.stderrKind==="bytes"?"bytes":"text");')
    change(index, 'let o=await eo(this.ctx,s);return!o.stdout', 'i=ohosStderrResult(i);let o=await eo(this.ctx,s);return!o.stdout')
    change(index, 'stderr:i.stderr+o.stderr}', 'stderr:i.stderr+o.stderr,stderrKind:"bytes"}')
    change(index, 'r+=_t(a),s+=a.stderr', 'r+=_t(a),s+=ohosStderrBytes(a)')
    change(index, 's=Ut(N.stderr)+_t(N)', 's=ohosStderrBytes(N)+_t(N)')
    change(index, 'l+=N.stderr,c+=', 'l+=ohosStderrBytes(N),c+=')
    change(index, 'stderr:l+i.stderr,internalOutputAccounting:', 'stderr:l+ohosStderrBytes(i),stderrKind:"bytes",internalOutputAccounting:')
    change(index, 'append(t,n){let r=M(t)+M(n);', 'append(t,n){let r=t.length+n.length;')
    change(index, 'appendUnaccounted(t,n){this.ctx.executionScope.appendOutput("stdout",t,"control-flow"),this.ctx.executionScope.appendOutput("stderr",n,"control-flow"),this.append(t,n)}', 'appendUnaccounted(t,n){t=Ut(t),n=Ut(n);this.ctx.executionScope.appendOutput("stdout",t,"control-flow",0,"bytes"),this.ctx.executionScope.appendOutput("stderr",n,"control-flow",0,"bytes"),this.append(t,n)}')
    change(index, 'return{stdout:n,stderr:r,exitCode:t,internalOutputAccounting:{stdout:M(n),stderr:M(r)}}', 'return{stdout:n,stdoutKind:"bytes",stderr:r,stderrKind:"bytes",exitCode:t,internalOutputAccounting:{stdout:n.length,stderr:r.length}}')
    change(index, 'stderr:A+v.stderr}', 'stderr:Ut(A)+ohosStderrBytes(v),stderrKind:"bytes"}')
    change(index, 'let x=(this.ctx.state.expansionStderr||"")+o;return this.ctx.state.expansionStderr="",L("",x,cs(this.ctx.state,[]))', 'let x=(this.ctx.state.expansionStderr||"")+Ut(o);return this.ctx.state.expansionStderr="",{...L("",x,cs(this.ctx.state,[])),stderrKind:"bytes"}')
    change_many(index, 'stderr:this.ctx.state.expansionStderr+r.stderr}', 'stderr:this.ctx.state.expansionStderr+ohosStderrBytes(r),stderrKind:"bytes"}', 2)
    change(accumulator, 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0)', 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0,t.stderrKind==="bytes"?"bytes":"text")')
    change(accumulator, 't.prependOutput(this.stdout,this.stderr)', 't.prependOutput(this.stdout,this.stderr,"bytes","bytes")')
    errors = 'chunks/chunk-EFORKKSH.js'
    change(errors, 'import{a as c}from"./chunk-GN6CQ3J4.js";', 'import{a as c,e as ohosEncode}from"./chunk-GN6CQ3J4.js";')
    change(errors, 'prependOutput(t,e){this.stdout=t+this.stdout,this.stderr=e+this.stderr,this.internalOutputAccounting.stdout+=c(t),this.internalOutputAccounting.stderr+=c(e)}', 'prependOutput(t,e,k="text",s="text"){let b=k==="bytes"?e:ohosEncode(e),a=s==="bytes"?t:ohosEncode(t);this.stdout=a+(this.stdoutKind==="bytes"||this.stdoutEncoding==="binary"?this.stdout:ohosEncode(this.stdout)),this.stdoutKind="bytes",this.stderr=b+(this.stderrKind==="bytes"?this.stderr:ohosEncode(this.stderr)),this.stderrKind="bytes",this.internalOutputAccounting.stdout+=a.length,this.internalOutputAccounting.stderr+=b.length}')
    # The published bundle has a fixed set of error/loop transfer sites. Count
    # every rewrite so an upstream shape change cannot silently omit a path.
    import re
    def counted(pattern, replacement, count):
        value, actual = re.subn(pattern, replacement, texts[index])
        if actual != count:
            raise ValueError(f'fixed output transfer count differs: {pattern}: {actual} != {count}')
        texts[index] = value
    counted(r'\.prependOutput\(([a-zA-Z]+)\.stdout,\1\.stderr\)', r'.prependOutput(\1.stdout,\1.stderr,"bytes","bytes")', 6)
    counted(r'L\(([^,()]+),([a-zA-Z]+)\.stderr,([^()]+?)\)', r'({...L(\1,\2.stderr,\3),...ohosOutputMetadata(\2)})', 11)
    counted(r'\{stdout:([a-zA-Z]+)\.stdout,stderr:\1\.stderr,exitCode:([^}]+)\}', r'{stdout:\1.stdout,stderr:\1.stderr,exitCode:\2,...ohosOutputMetadata(\1)}', 9)
    counted(r'append\("stdout",([a-zA-Z]+)\.stdout,\1\.internalOutputAccounting\.stdout\)', r'append("stdout",\1.stdout,\1.internalOutputAccounting.stdout,Kf(\1))', 8)
    counted(r'append\("stdout",([a-zA-Z]+)\.stdout\)', r'append("stdout",\1.stdout,0,Kf(\1))', 1)
    counted(r'append\("stderr",([a-zA-Z]+)\.stderr,\1\.internalOutputAccounting\.stderr\)', r'append("stderr",\1.stderr,\1.internalOutputAccounting.stderr,\1.stderrKind??"text")', 8)
    counted(r'append\("stderr",([a-zA-Z]+)\.stderr\)', r'append("stderr",\1.stderr,0,\1.stderrKind??"text")', 1)
    # The older loop accumulator also receives typed command/error results.
    # Keep both streams as bytes inside it, and preserve already-accounted
    # byte counts when a multi-level break/continue crosses another loop.
    counted(r'\.append\(([a-zA-Z]+)\.stdout,\1\.stderr\)', r'.append(_t(\1),ohosStderrBytes(\1))', 10)
    counted(r't\+=e\.stdout', 't+=_t(e)', 2)
    counted(r'n\+=e\.stderr', 'n+=ohosStderrBytes(e)', 2)
    counted(r'e\.stderr=n', 'e.stderr=n,e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:t.length,stderr:n.length}', 2)
    counted(r'h\.stdout=s\.stdout,h\.stderr=s\.stderr', 'h.stdout=s.stdout,h.stderr=s.stderr,h.stdoutKind="bytes",h.stderrKind="bytes",h.internalOutputAccounting={stdout:s.stdout.length,stderr:s.stderr.length}', 2)
    counted(r'\.prependOutput\(t,n\)', '.prependOutput(t,n,"bytes","bytes")', 1)
    counted(r'stdout:([a-zA-Z]+)\.stdout,stderr:kt\(\1\.stderr\)', r'stdout:\1.stdout,stdoutKind:Kf(\1),stderr:kt(\1.stderr)', 2)
    change(index, 't.stdout=i.stdout,t.stderr=i.stderr,t.internalOutputAccounting=', 't.stdout=i.stdout,t.stdoutKind=Kf(i),t.stderr=i.stderr,t.stderrKind=i.stderrKind,t.internalOutputAccounting=')
    change(index, 'i.internalOutputAccounting??{stdout:M(i.stdout),stderr:M(i.stderr)}', 'i.internalOutputAccounting??{stdout:_t(i).length,stderr:ohosStderrBytes(i).length}')
    change(index, 'e.errorCause.stdout=e.error.stdout,e.errorCause.stderr=e.error.stderr,e.errorCause', 'e.errorCause.stdout=e.error.stdout,e.errorCause.stdoutKind=Kf(e.error),e.errorCause.stderr=e.error.stderr,e.errorCause.stderrKind=e.error.stderrKind,e.errorCause')
    # Command substitution is explicitly a textual consumer. Both a caught
    # exit and a nested exec result may now carry bytes; decode only here.
    change(index, 'c.stdout?.replace(/\\n+$/,"")??""', 'ii(c).replace(/\\n+$/,"")')
    change(index, 'u.stdout.replace(/\\n+$/,"")', 'ii(u).replace(/\\n+$/,"")')
    change_many(index, 'c.stdout.replace(/\\n+$/,"")', 'ii(c).replace(/\\n+$/,"")', 2)
    change_many(index, 'h.stdout.replace(/\\n+$/,"")', 'ii(h).replace(/\\n+$/,"")', 2)
    change(index, 'function Cr(', 'function ohosControlFlowLimit(t,n,r,s){try{cn(t,n,r,s)}catch(e){if(e instanceof $)e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:r.length,stderr:s.length};throw e}}function Cr(')
    counted(r'cn\((`[^`]+`),"iterations",([a-zA-Z]+)\.stdout,\2\.stderr\)', r'ohosControlFlowLimit(\1,"iterations",\2.stdout,\2.stderr)', 4)
    change(index, 'stderr:`${n}${s}\n`,exitCode:1', 'stderr:n+Ut(`${s}\n`),stderrKind:"bytes",exitCode:1')
    # These bytes are created after accountResult(t), so they have no prior
    # accounting credit. Include them before transfer to any live/file sink.
    change(index, 'c+=`bash: echo: write error: No space left on device\n`,', 'c+=ohosRoutingDiagnostic(e,`bash: echo: write error: No space left on device\n`),')
    change(index, 'v+=`${a?"":"bash: "}${o}: write error: Bad file descriptor\n`,', 'v+=ohosRoutingDiagnostic(e,`${a?"":"bash: "}${o}: write error: Bad file descriptor\n`),')
    # Preserve the boolean projection of the legacy returned streams before
    # live routing consumes their strings. No byte buffer, physical descriptor,
    # cursor, native builtin, or output budget is changed by this history.
    # Scoped standard redirects affect the enclosing command's return routes;
    # persistent exec and numeric dup also update the inherited logical source.
    logical = ('function ohosLogicalRoles(e){let s=e.state;if(!s.ohosLogicalRoles){let m=new Map;'
               'for(let[fd,raw]of s.fileDescriptors??[]){let v=s.inputFds?.has(fd)?null:Pp(raw);m.set(fd,v?.kind==="dup-out"?(v.sourceFd===1?1:v.sourceFd===2?2:0):0)}'
               'for(let fd of s.closedStandardFds??[])m.set(fd,0);s.ohosLogicalRoles=m}return s.ohosLogicalRoles}'
               'function ohosLogicalRole(e,fd){let m=ohosLogicalRoles(e);return m.has(fd)?m.get(fd):fd===1?1:fd===2?2:0}'
               'function ohosLogicalSet(e,fd,role){ohosLogicalRoles(e).set(fd,role)}'
               'function ohosLogicalEntry(e,t,routes){if(t?.kind==="dup-out")return routes?.get(t.sourceFd)??ohosLogicalRole(e,t.sourceFd);'
               'if(t?.kind==="output"&&t.path==="/dev/stdout")return routes?.get(1)??ohosLogicalRole(e,1);'
               'if(t?.kind==="output"&&t.path==="/dev/stderr")return routes?.get(2)??ohosLogicalRole(e,2);return 0}'
               'function ohosPreparedLogical(e,m){m.ohosLogicalRoutes=new Map([[0,0],[1,ohosLogicalRole(e,1)],[2,ohosLogicalRole(e,2)]]);return m}'
               'function ohosLogicalPush(e){ohosLogicalRoles(e);let stack=e.executionScope.ohosLogicalFrames??=[],f={stdout:false,stderr:false,stderrMark:{}};'
               'e.executionScope.ohosLogicalFrames=stack;stack.push(f);return f}'
               'function ohosLogicalCurrent(e){return e.executionScope.ohosLogicalFrames?.at(-1)}'
               'function ohosLogicalPop(e,f,captured=[]){let stack=e.executionScope.ohosLogicalFrames;if(stack.pop()!==f)throw new Error("OH logical frame order");let p=stack.at(-1);'
               'if(p){if(f.stdout&&!captured.includes(1))p.stdout=true;if(f.stderr&&!captured.includes(2))p.stderr=true,p.stderrMark={}}}'
               'function ohosLogicalRoute(e,t,routes,rawOut,rawErr){let f=ohosLogicalCurrent(e);if(!f)return;'
               'let m=routes.ohosLogicalRoutes,a=Boolean(rawOut),b=Boolean(rawErr);'
               'if(m){a=a||f.stdout;b=b||f.stderr;let x=m.get(1)??1,y=m.get(2)??2;f.stdout=a&&x===1||b&&y===1;f.stderr=a&&x===2||b&&y===2}'
               'else if(a||b){let x=ohosLogicalRole(e,1),y=ohosLogicalRole(e,2);f.stdout=f.stdout||a&&x===1||b&&y===1;f.stderr=f.stderr||a&&x===2||b&&y===2}}'
               'function ohosLogicalLoopStart(e){let frame=ohosLogicalCurrent(e);return{frame,mark:frame?.stderrMark}}'
               'function ohosLogicalLoopStderr(loop){return!!loop.frame&&loop.frame.stderrMark!==loop.mark}')
    change(index, 'function Cr(', logical + 'function Cr(')
    # A statement/command commits its projection once to its immediate parent.
    # A capture suppresses its captured stdout projection while stderr still
    # belongs to the caller. This state is separate from physical sink drains.
    change(index, 'async executeStatement(t){', 'async executeStatement(t){let f=ohosLogicalPush(this.ctx);try{return await this.ohosExecuteStatement(t)}finally{ohosLogicalPop(this.ctx,f)}}async ohosExecuteStatement(t){')
    change(index, 'async executeCommand(t,n,r=!1){', 'async executeCommand(t,n,r=!1){let f=ohosLogicalPush(this.ctx);try{return await this.ohosExecuteCommand(t,n,r)}finally{ohosLogicalPop(this.ctx,f)}}async ohosExecuteCommand(t,n,r=!1){')
    change(index, 'async function ohosCaptureOutput(e,fds,run){let saved=', 'async function ohosCaptureOutput(e,fds,run){let ohosFrame=ohosLogicalPush(e);let saved=')
    change(index, 'finally{Fs(e,saved);for(let[fd,wasClosed]of closed)', 'finally{ohosLogicalPop(e,ohosFrame,fds);Fs(e,saved);for(let[fd,wasClosed]of closed)')
    change(index, 'ct(e,fd,s)}', 'ct(e,fd,s,fd)}')
    # The prepared map carries logical return targets in parallel to its
    # existing physical targets. It never changes table size or entry shape.
    change(index, 'a=new Map([[0,o(0,{kind:"dup-in",sourceFd:0})],[1,o(1,ohosDefaultEntry(e,1))],[2,o(2,ohosDefaultEntry(e,2))]])', 'a=ohosPreparedLogical(e,new Map([[0,o(0,{kind:"dup-in",sourceFd:0})],[1,o(1,ohosDefaultEntry(e,1))],[2,o(2,ohosDefaultEntry(e,2))]]))')
    change(index, 'm=(y,g)=>{y!==null&&y<Se&&(r.policy==="persistent"?(a.set(y,g),e.state.closedStandardFds?.delete(y),ct(e,y,g)):E(y,g))}', 'm=(y,g,role=ohosLogicalEntry(e,g,a.ohosLogicalRoutes))=>{y!==null&&y<Se&&(a.ohosLogicalRoutes.set(y,role),r.policy==="persistent"?(a.set(y,g),e.state.closedStandardFds?.delete(y),ct(e,y,g,role)):E(y,g,role))}')
    change(index, 'E=(y,g)=>{a.set(y,g),pn(e,r.standardSnapshot,y),', 'E=(y,g,role=ohosLogicalEntry(e,g,a.ohosLogicalRoutes))=>{a.set(y,g),a.ohosLogicalRoutes.set(y,role),pn(e,r.standardSnapshot,y),')
    change(index, 'e.state.closedStandardFds?.delete(y),ct(e,y,g)},S=', 'e.state.closedStandardFds?.delete(y),ct(e,y,g,role,false)},S=')
    change(index, 'S=(y,g)=>{if(y<Se){let b=a.get(y);return b?.kind==="closed"?null:b?{kind:"entry",entry:b,descriptors:dn(e,y)}:{kind:"standard",fd:y}}return Dp(e,y,g)}', 'S=(y,g)=>{if(y<Se){let b=a.get(y),role=a.ohosLogicalRoutes.get(y)??0;return b?.kind==="closed"?null:b?{kind:"entry",entry:b,descriptors:dn(e,y),ohosLogicalRole:role}:{kind:"standard",fd:y,ohosLogicalRole:role}}let b=Dp(e,y,g);return b?{...b,ohosLogicalRole:ohosLogicalRole(e,y)}:b}')
    change(index, 'function ct(e,t,n){_s(e,t,Eo(n),n.kind==="input")}', 'function ct(e,t,n,role=ohosLogicalEntry(e,n),logical=true){logical&&ohosLogicalSet(e,t,role);_s(e,t,Eo(n),n.kind==="input")}')
    change(index, 'function Rt(e,t){e.state.fileDescriptors?.delete(t),', 'function Rt(e,t){ohosLogicalSet(e,t,0);e.state.fileDescriptors?.delete(t),')
    change(index, '(_s(e,t,r,e.state.inputFds?.has(n)===!0),bo(e,t,n),!0)', '(ohosLogicalSet(e,t,ohosLogicalRole(e,n)),_s(e,t,r,e.state.inputFds?.has(n)===!0),bo(e,t,n),!0)')
    change(index, 'Rt(e,n),_s(e,t,r,s);let o=', 'let ohosRole=ohosLogicalRole(e,n);Rt(e,n),ohosLogicalSet(e,t,ohosRole),_s(e,t,r,s);let o=')
    change(index, 't.set(n,{raw:Is(e,n),isInput:', 't.set(n,{ohosLogicalRole:ohosLogicalRole(e,n),raw:Is(e,n),isInput:')
    change(index, 'for(let[r,{raw:s,isInput:i,aliases:o}]of t)', 'for(let[r,{raw:s,isInput:i,aliases:o,ohosLogicalRole:role}]of t)')
    change(index, 'if(s===void 0){Rt(e,r);continue}_s(e,r,s,i);', 'if(s===void 0){Rt(e,r),ohosLogicalSet(e,r,role);continue}ohosLogicalSet(e,r,role);_s(e,r,s,i);')
    # Aliases retain their logical source at preparation, including an alias
    # saved before the loop. Ordinary files/input descriptors project to zero.
    change(index, 'let x,C;if(k){let D=P;', 'let x,C,ohosRole=0;if(k){let D=P;')
    change(index, 'C=D,V.kind==="standard"?x=', 'C=D,ohosRole=V.ohosLogicalRole,V.kind==="standard"?x=')
    change(index, 'else x&&ct(e,A,x);C?.move', 'else x&&ct(e,A,x,ohosRole);C?.move')
    change(index, 'sourceFd:C.fd});else if(x.sourceFd<Se)ct(e,A,C.entry);', 'sourceFd:C.fd},C.ohosLogicalRole);else if(x.sourceFd<Se)ct(e,A,C.entry,C.ohosLogicalRole);')
    change(index, 'a.set(b,nt(e,b)),e.state.closedStandardFds?.delete(b)', 'a.set(b,nt(e,b)),a.ohosLogicalRoutes.set(b,ohosLogicalRole(e,b)),e.state.closedStandardFds?.delete(b)')
    change(index, 'sourceFd:P.fd}):m(b,P.entry);if(g.operator==="<&"', 'sourceFd:P.fd},P.ohosLogicalRole):m(b,P.entry,P.ohosLogicalRole);if(g.operator==="<&"')
    change(index, 'a.set(b,{kind:"closed"}),(r.policy', 'a.set(b,{kind:"closed"}),a.ohosLogicalRoutes.set(b,0),(r.policy')
    change(index, 'a.set(A.sourceFd,{kind:"closed"}),(r.policy', 'a.set(A.sourceFd,{kind:"closed"}),a.ohosLogicalRoutes.set(A.sourceFd,0),(r.policy')
    # Scope copies carry only this small metadata map; real FD copying,
    # read/write cursor updates and persistent exec behavior remain untouched.
    change(index, 't.nextFd=s.nextFd}', 't.nextFd=s.nextFd;t.ohosLogicalRoles=s.ohosLogicalRoles?new Map(s.ohosLogicalRoles):void 0}')
    change(index, 'nextFd:e.nextFd,readonlyVars:e.readonlyVars', 'nextFd:e.nextFd,ohosLogicalRoles:e.ohosLogicalRoles,readonlyVars:e.readonlyVars')
    change(index, 'e.env=new Map(e.env),e.arrays=', 'e.ohosLogicalRoles=e.ohosLogicalRoles?new Map(e.ohosLogicalRoles):void 0;e.env=new Map(e.env),e.arrays=')
    # Project at the last point where the command's bytes still exist. The
    # extra delivery-only mn call has no prepared routes and does not migrate
    # the already committed projection a second time.
    change(index, 'if(l!==""||c!==""){let b=l,v=c;', 'ohosLogicalRoute(e,t,i,l,c);if(l!==""||c!==""){let b=l,v=c;')
    change(index, 'function ohosControlFlowLimit(t,n,r,s){', 'function ohosControlFlowLimit(t,n,r,s,loop){')
    change(index, 'if(e instanceof $)e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:r.length,stderr:s.length};throw e}}', 'if(e instanceof $){if(!s&&ohosLogicalLoopStderr(loop))e.stderr="";e.stdoutKind="bytes",e.stderrKind="bytes",e.internalOutputAccounting={stdout:r.length,stderr:s.length}}throw e}}')
    counted(r'ohosControlFlowLimit\((`[^`]+`),"iterations",([a-zA-Z]+)\.stdout,\2\.stderr\)', r'ohosControlFlowLimit(\1,"iterations",\2.stdout,\2.stderr,ohosLoop)', 4)
    change(index, 'e.state.loopDepth++;try{for(let o of i)', 'let ohosLoop=ohosLogicalLoopStart(e);e.state.loopDepth++;try{for(let o of i)')
    change(index, 't.init&&await J(e,t.init.expression),e.state.loopDepth++;try{', 't.init&&await J(e,t.init.expression);let ohosLoop=ohosLogicalLoopStart(e);e.state.loopDepth++;try{')
    change_many(index, 'a.owns&&(e.state.groupStdin=a.stdin),e.state.loopDepth++;try{', 'a.owns&&(e.state.groupStdin=a.stdin);let ohosLoop=ohosLogicalLoopStart(e);e.state.loopDepth++;try{', 2)
    # A loop's legacy accumulator only accepts its body and, for while /
    # until, its condition statements. Arithmetic/word expansions are not
    # appended there. Sample the same six awaits, including exceptional return,
    # without introducing another async call or changing real output delivery.
    change(index, 'f={stdout:false,stderr:false,stderrMark:{}}', 'f={stdout:false,stderr:false,stdoutMark:{},stderrMark:{}}')
    change(index, 'if(f.stdout&&!captured.includes(1))p.stdout=true;', 'if(f.stdout&&!captured.includes(1))p.stdout=true,p.stdoutMark={};')
    change(index, 'function ohosLogicalLoopStart(e){let frame=ohosLogicalCurrent(e);return{frame,mark:frame?.stderrMark}}function ohosLogicalLoopStderr(loop){return!!loop.frame&&loop.frame.stderrMark!==loop.mark}',
           'function ohosLogicalLoopStart(e){let frame=ohosLogicalCurrent(e);return{frame,priorStdout:!!frame?.stdout,priorStderr:!!frame?.stderr,stdout:false,stderr:false}}'
           'function ohosLogicalLoopMark(loop){return{stdout:loop.frame?.stdoutMark,stderr:loop.frame?.stderrMark}}'
           'function ohosLogicalLoopNote(loop,mark){if(loop.frame){loop.stdout=loop.stdout||loop.frame.stdoutMark!==mark.stdout;loop.stderr=loop.stderr||loop.frame.stderrMark!==mark.stderr}}'
           'function ohosLogicalLoopFinish(loop,acc){if(loop.frame){loop.frame.stdout=loop.priorStdout||loop.stdout||!!acc.stdout;loop.frame.stderr=loop.priorStderr||loop.stderr||!!acc.stderr}}'
           'function ohosLogicalLoopStderr(loop){return loop.stderr}')
    # Preserve any contribution made by preparation before this loop function;
    # exclude this function's word/init/update/condition arithmetic expansions.
    change_many(index, 'let ohosLoop=ohosLogicalLoopStart(e);', '', 4)
    change(index, 'async function Dm(e,t){let n=new gn(e),r=0,s=0;', 'async function Dm(e,t){let n=new gn(e),ohosLoop=ohosLogicalLoopStart(e),r=0,s=0;')
    change(index, 'let r=new gn(e),s=0,i=0;t.init&&await J(e,t.init.expression);', 'let r=new gn(e),ohosLoop=ohosLogicalLoopStart(e),s=0,i=0;t.init&&await J(e,t.init.expression);')
    change_many(index, 'let s=new gn(e),i=0,o=0,a=xf(r.stdin,n)', 'let s=new gn(e),ohosLoop=ohosLogicalLoopStart(e),i=0,o=0,a=xf(r.stdin,n)', 2)
    change(index, 'let l=await e.executeStatement(a);n.append(_t(l),ohosStderrBytes(l))',
           'let ohosMark=ohosLogicalLoopMark(ohosLoop),l;try{l=await e.executeStatement(a)}finally{ohosLogicalLoopNote(ohosLoop,ohosMark)}n.append(_t(l),ohosStderrBytes(l))')
    change(index, 'let a=await e.executeStatement(o);r.append(_t(a),ohosStderrBytes(a))',
           'let ohosMark=ohosLogicalLoopMark(ohosLoop),a;try{a=await e.executeStatement(o)}finally{ohosLogicalLoopNote(ohosLoop,ohosMark)}r.append(_t(a),ohosStderrBytes(a))')
    change_many(index, 'let p=await e.executeStatement(h);s.append(_t(p),ohosStderrBytes(p))',
           'let ohosMark=ohosLogicalLoopMark(ohosLoop),p;try{p=await e.executeStatement(h)}finally{ohosLogicalLoopNote(ohosLoop,ohosMark)}s.append(_t(p),ohosStderrBytes(p))', 2)
    change(index, 'let c=await da(e,t.condition);if(s.append(_t(c),ohosStderrBytes(c))',
           'let ohosMark=ohosLogicalLoopMark(ohosLoop),c;try{c=await da(e,t.condition)}finally{ohosLogicalLoopNote(ohosLoop,ohosMark)}if(s.append(_t(c),ohosStderrBytes(c))')
    change(index, 'let f=await e.executeStatement(u);s.append(_t(f),ohosStderrBytes(f))',
           'let ohosMark=ohosLogicalLoopMark(ohosLoop),f;try{f=await e.executeStatement(u)}finally{ohosLogicalLoopNote(ohosLoop,ohosMark)}s.append(_t(f),ohosStderrBytes(f))')
    # A finished nested loop must return its own accumulator's projection, not
    # leak excluded arithmetic-expansion history to a surrounding loop.
    change(index, 'finally{e.state.loopDepth--}return n.build(r)}', 'finally{ohosLogicalLoopFinish(ohosLoop,n);e.state.loopDepth--}return n.build(r)}')
    change(index, 'finally{e.state.loopDepth--}return r.build(s)}', 'finally{ohosLogicalLoopFinish(ohosLoop,r);e.state.loopDepth--}return r.build(s)}')
    change_many(index, 'finally{e.state.loopDepth--,a.owns&&(e.state.groupStdin=l)}return s.build(i)}',
           'finally{ohosLogicalLoopFinish(ohosLoop,s);e.state.loopDepth--,a.owns&&(e.state.groupStdin=l)}return s.build(i)}', 2)
    # A missing non-standard logical role already means zero. Do not retain
    # closed descriptor numbers as zero-valued historical map entries.
    change(index, 'function ohosLogicalSet(e,fd,role){ohosLogicalRoles(e).set(fd,role)}',
           'function ohosLogicalSet(e,fd,role){let m=ohosLogicalRoles(e);fd>=3&&role===0?m.delete(fd):m.set(fd,role)}')
    # A readwrite entry is one open-description object, with raw bytes and a
    # byte cursor. Dup, temporary redirection, and shallow subshell snapshots
    # retain its identity; rebinding a descriptor creates a different object.
    # The existing stdin interface remains decoded text, so hn converts its
    # consumption once. Readwrite progress is already shared across subshells.
    readwrite_helpers = r'''
var ohosReadwriteDecoder=new TextDecoder("utf-8",{ignoreBOM:true});
function ohosReadwriteText(e){let b=Ft(e.content.slice(e.position),"binary");return e.position===0?Mt(b):ohosReadwriteDecoder.decode(b)}
function ohosReadwriteConsumed(e,n){
 if(n<=0)return 0;
 let b=e.content,p=e.position,units=0;
 if(p===0&&b.charCodeAt(0)===239&&b.charCodeAt(1)===187&&b.charCodeAt(2)===191)p=3;
 while(p<b.length&&units<n){
  let first=b.charCodeAt(p++),need=1,low=128,high=191;
  if(first>=194&&first<=223)need=2;
  else if(first>=224&&first<=239){need=3;if(first===224)low=160;else if(first===237)high=159}
  else if(first>=240&&first<=244){need=4;if(first===240)low=144;else if(first===244)high=143}
  let accepted=1;
  for(;accepted<need&&p<b.length;accepted++){
   let next=b.charCodeAt(p),lower=accepted===1?low:128,upper=accepted===1?high:191;
   if(next<lower||next>upper)break;
   p++;
  }
  units+=need===4&&accepted===4?2:1;
 }
 return p-e.position;
}
function ohosReadCharEnd(s,count){let end=0,characters=0;while(end<s.length&&characters<count){end+=s.codePointAt(end)>65535?2:1;characters++}return{end,characters}}
'''
    change(index, 'function Ls(e,t){', readwrite_helpers + 'function Ls(e,t){')
    change(index,
           'let s=await e.fs.readFile(r);return n?{entry:{kind:"readwrite",path:r,position:0,content:s}}',
           'let s=n?await In(e.fs,r):await e.fs.readFile(r);return n?{entry:{kind:"readwrite",path:r,position:0,content:s}}')
    change(index, 'case"readwrite":return{content:n.content.slice(n.position)}',
           'case"readwrite":return{content:ohosReadwriteText(n)}')
    change(index, 'c=f.content.slice(f.position),u=0', 'c=ohosReadwriteText(f),u=0')
    change(index, 'P.entry.content.slice(P.entry.position)', 'ohosReadwriteText(P.entry)')
    change(index, 'c=P.content,u=-1', 'c=ohosReadwriteText(P),u=-1')
    change(index,
           'function Pp(e){if(e!==null&&typeof e==="object"&&(e.kind==="output"||e.kind==="dup-out"))return e;',
           'function Pp(e){if(e!==null&&typeof e==="object"&&(e.kind==="output"||e.kind==="dup-out"||e.kind==="readwrite"))return e;')
    change(index,
           'case"readwrite":return`${wo}${e.path.length}:${e.path}:${e.position}:${e.content}`;',
           'case"readwrite":return e;')
    change(index,
           'else if(r.kind==="readwrite")s={...r,position:r.position+n};else return;let i=Eo(s)',
           'else if(r.kind==="readwrite"){r.position+=ohosReadwriteConsumed(r,n);return}else return;let i=Eo(s)')
    change(index,
           'u.kind==="input"&&f?.kind==="input"?u.content.length-f.content.length:u.kind==="readwrite"&&f?.kind==="readwrite"&&u.path===f.path?f.position-u.position:0',
           'u.kind==="input"&&f?.kind==="input"?u.content.length-f.content.length:0')
    change(index,
           'let o=n.map(u=>nt(e,u)).find(u=>u?.kind==="readwrite")??t;if(o.kind!=="readwrite")return!1;let a=o.content.slice(0,o.position)+r+o.content.slice(o.position+r.length),l={...o,position:o.position+r.length,content:a};await e.fs.writeFile(o.path,a,s);let c=Eo(l);for(let u of n)Nn(e,u)&&So(e,u,c,!1);return!0}',
           'if(t.kind!=="readwrite")return!1;let ohosBytes=s==="binary"?r:Ut(r),ohosAt=t.position;await e.fs.writeFile(t.path,ohosBytes,{encoding:"binary",ohosWritePosition:ohosAt});t.position=ohosAt+ohosBytes.length;t.content=await In(e.fs,t.path);return!0}')
    change(index,
           'let a=o.find(l=>n.has(l));a!==void 0&&bo(e,r,a)',
           'let a=o.find(l=>n.has(l)&&(s?.kind!=="readwrite"||n.get(l)===s));a!==void 0&&bo(e,r,a)')
    # Text units remain the existing interface to hn. For readwrite text only,
    # -n/-N may not return one half of a supplementary scalar and then charge
    # the complete four-byte span. Other descriptor input contracts are unchanged.
    change(index, 'let b=i===""?"\\0":i,v="",k=0,A=I=>',
           'let ohosReadChars=(g?y:nt(e,r>=0?r:(!n&&e.state.groupStdin!==void 0?e.state.groupStdinSourceFd??0:0))??nt(e,0))?.kind==="readwrite";let b=i===""?"\\0":i,v="",k=0,A=I=>')
    change(index,
           'if(l>=0){let I=Math.min(l,S.length);v=S.substring(0,I),P(v),N=I,x=I>=l,C(N);',
           'if(l>=0){let ohosCut=ohosReadChars?ohosReadCharEnd(S,l):null,I=ohosCut?ohosCut.end:Math.min(l,S.length);v=S.substring(0,I),P(v),N=I,x=ohosCut?ohosCut.characters>=l:I>=l,C(N);')
    old_read_n = r'''else if(a>=0){let I=0,_=0,B=!1;for(;_<S.length&&I<a;){let ne=S[_];if(ne===b){N=_+1,B=!0;break}if(!s&&ne==="\\"&&_+1<S.length){let Y=S[_+1];if(Y===b&&b===`
`){_+=2,N=_;continue}if(Y===b){_+=2,I++,A(Y),N=_;continue}A(Y),_+=2,I++,N=_}else A(ne),_++,I++,N=_}x=I>=a||B,C(N)}'''
    new_read_n = r'''else if(a>=0){let I=0,_=0,B=!1;for(;_<S.length&&I<a;){let ne=ohosReadChars?String.fromCodePoint(S.codePointAt(_)):S[_];if(ne===b){N=_+ne.length,B=!0;break}if(!s&&ne==="\\"&&_+1<S.length){let Y=ohosReadChars?String.fromCodePoint(S.codePointAt(_+1)):S[_+1],ohosStep=1+Y.length;if(Y===b&&b===`
`){_+=ohosStep,N=_;continue}if(Y===b){_+=ohosStep,I++,A(Y),N=_;continue}A(Y),_+=ohosStep,I++,N=_}else A(ne),_+=ne.length,I++,N=_}x=I>=a||B,C(N)}'''
    change(index, old_read_n, new_read_n)


    # An explicit nonzero read -u of a readwrite description observes current
    # authorized path bytes. Keep the open-description object and byte cursor;
    # the subsequent text view and consumption use this one successful read.
    # Existing -N precedence, zero-character reads and -t0 remain unchanged.
    change(index, 'function ea(e,t,n,r=-1){', 'async function ea(e,t,n,r=-1){')
    change(index, 'if(g){let I=Ls(e,u);',
           'if(g){if(y?.kind==="readwrite"&&(l>=0?l:a)!==0){try{y.content=await In(e.fs,y.path)}catch(ohosError){return L("",`bash: read: ${u}: ${ohosError.message}\n`,1)}}let I=Ls(e,u);')

    # wc -m and -c are independent columns, including combined options and totals.
    wc = 'chunks/chunk-P5BOIHWV.js'
    change(wc, 'x(r,o,n,c,"",0)', 'x(r,o,n,c,"",0,l,e)')
    change(wc, 'let d=[],m=0,g=0,u=0;', 'let d=[],m=0,g=0,u=0,ohosBytes=0;')
    change(wc, 'u+=p.third,d.push', 'u+=p.third,ohosBytes+=p.bytes,d.push')
    change(wc, 'h=t.length>1?3:0;o&&', 'h=t.length>1?3:0;l&&(B=Math.max(B,t.length>1?ohosBytes:Math.max(...d.map(r=>r.stats.bytes))));o&&')
    change(wc, 'x(y,o,n,c,r,h)', 'x(y,o,n,c,r,h,l,e)')
    change(wc, 'x({lines:m,words:g,third:u},o,n,c,"total",h)', 'x({lines:m,words:g,third:u,bytes:ohosBytes},o,n,c,"total",h,l,e)')
    change(wc, '{lines:l,words:e,third:n}', '{lines:l,words:e,third:n,bytes:o}')
    change(wc, 'function x(a,f,s,o,n,l){', 'function x(a,f,s,o,n,l,ohosBytes,ohosChars){')
    change(wc, 'o&&e.push(String(a.third).padStart(l))', 'o&&ohosChars&&e.push(String(a.third).padStart(l)),o&&ohosBytes&&e.push(String(a.bytes).padStart(l))')

    # MountableFs routes the link location and target in the same virtual
    # namespace. ReadWriteFs confines a link to one root; another mounted
    # filesystem is not a path alias into that root.
    change(index,
           'async symlink(t,n){let{fs:r,relativePath:s}=this.routePath(n);return r.symlink(t,s)}',
           'async symlink(t,n){let{fs:r,relativePath:s}=this.routePath(n),ohosTarget=this.routePath(this.resolvePath(yt(n),t));if(ohosTarget.fs!==r)throw new Error(`EXDEV: cross-mount symlink is not supported, symlink \'${n}\'`);return r.symlink(t.startsWith("/")?ohosTarget.relativePath:t,s)}')
    # A stored absolute link inside the real root has an absolute virtual
    # first hop. Keep the existing resolved-target check before exposing it;
    # relative first hops stay byte-exact after that check; external redaction stays intact.
    change(index,
           'if(Ie(l,this.canonicalRoot)){let c=l.slice(this.canonicalRoot.length)||"/";return o==="/"?',
           'if(Ie(l,this.canonicalRoot)){if(!H.isAbsolute(s))return s;if(H.isAbsolute(s)&&Ie(s,this.canonicalRoot))return s.slice(this.canonicalRoot.length)||"/";let c=l.slice(this.canonicalRoot.length)||"/";return o==="/"?')
    change(index,
           'async readlink(t){let{fs:n,relativePath:r}=this.routePath(t);return n.readlink(r)}',
           'async readlink(t){let{fs:n,relativePath:r}=this.routePath(t),ohosTarget=await n.readlink(r);if(ohosTarget.startsWith("/")){let ohosPath=W(t);for(let ohosMount of this.mounts.keys())if(ohosPath===ohosMount||ohosPath.startsWith(`${ohosMount}/`))return ohosTarget==="/"?ohosMount:`${ohosMount}${ohosTarget}`}return ohosTarget}')

    # -u selects UTC for a naive -d input as well as its formatted output.
    # Explicit offsets and epochs retain their existing absolute-time path.
    change('chunks/chunk-5ATEFZLC.js', 'p=t!==null?b(t,l):new Date',
           'p=t!==null?b(t,i?"UTC":l):new Date')

    # Avoid one cons-string node per output byte: large valid UTF-8 output
    # otherwise exhausts the fixed Worker heap before reaching its 64 MiB cap.
    # Keep the original length checks before allocating and alter only this
    # verified OH-private module, never global built-ins or the npm package.
    codec = 'chunks/chunk-GN6CQ3J4.js'
    change(codec, 'var u=new TextDecoder', 'import{Buffer as ohosBuffer}from"node:buffer";var u=new TextDecoder')
    change(codec, 'let e=y.encode(t),o="";for(let r=0;r<e.length;r++)o+=String.fromCharCode(e[r]);return o',
           'return ohosBuffer.from(t,"utf8").toString("latin1")')
    change(codec, 'let e="";for(let o=0;o<t.length;o++)e+=String.fromCharCode(t[o]);return e',
           'return ohosBuffer.from(t).toString("latin1")')

    notice = ('/* Modified for dsh-go OHOS: permission diagnostics, typed output and statement delivery.\n'
              ' * Derived from just-bash 3.6.0; Apache-2.0. See LICENSE and PROVENANCE.json. */\n')
    return {name: (notice + text).encode('utf-8') for name, text in texts.items()}
