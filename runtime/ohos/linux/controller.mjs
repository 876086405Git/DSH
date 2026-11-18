import { EventEmitter } from 'node:events';
export const WINDOW = 65536;
export const CHUNK = 4096;
export const failure = (code, message) => Object.assign(new Error(message), { code });
export function offset(value) {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(value)) throw failure('ERR_OHOS_LINUX_PROTOCOL', 'Invalid byte offset');
  const n = BigInt(value); if (n > 18446744073709551615n) throw failure('ERR_OHOS_LINUX_PROTOCOL', 'Byte offset overflow'); return n;
}
// Private transport framing. Every listener is attached before the VM can emit
// the first agent frame. Ordinary boot text is bounded and never a READY signal.
export class LinuxController extends EventEmitter {
  constructor(socket, epoch) {
    super();
    if (!/^[a-f0-9]{64}$/.test(epoch)) throw new TypeError('A fixed private 32-byte epoch is required');
    this.socket=socket;this.epoch=epoch;this.sequence=0;this.buffer=Buffer.alloc(0);this.queue=[];this.queuedBytes=0;this.blocked=false;this.failed=false;this.agentClosed=false;
    socket.on('data', bytes=>this.receive(bytes));
    socket.on('drain',()=>{this.blocked=false;this.flush();});
    socket.on('error',error=>this.break(error));
    socket.on('end',()=>{if(!this.agentClosed)this.break(failure('ERR_OHOS_LINUX_TRANSPORT','Guest transport ended before closed'));});
    socket.on('close',()=>{if(!this.agentClosed)this.break(failure('ERR_OHOS_LINUX_TRANSPORT','Guest transport closed without release'));});
  }
  receive(bytes) {
    if(this.failed)return;
    try {
      this.buffer=Buffer.concat([this.buffer,bytes]);
      for(;;){const index=this.buffer.indexOf(10);if(index<0)break;if(index>131071)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest control line exceeds bound');
        let line=this.buffer.subarray(0,index);this.buffer=this.buffer.subarray(index+1);
        if(line.at(-1)===13)line=line.subarray(0,-1);
        if(!line.subarray(0,6).equals(Buffer.from('DSHG1 ')))continue;
        const frame=JSON.parse(line.subarray(6).toString('utf8'));
        if(!frame||frame.v!==1||frame.epoch!==this.epoch||!Number.isSafeInteger(frame.seq)||frame.seq!==this.sequence+1||typeof frame.kind!=='string')throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest epoch/sequence/version mismatch');
        this.sequence=frame.seq;this.emit('frame',frame);
        if(this.failed)return;
      }
      if(this.buffer.length>131071)throw failure('ERR_OHOS_LINUX_PROTOCOL','Unterminated guest control line exceeds bound');
    } catch(error){this.break(error);}
  }
  send(op, fields={}, sent=()=>{}) {
    if(this.failed)throw failure('ERR_OHOS_LINUX_TRANSPORT','Guest transport is quarantined');
    const bytes=Buffer.from(JSON.stringify({v:1,epoch:this.epoch,op,...fields})+'\n');
    if(bytes.length>65536||this.queuedBytes+bytes.length>262144)throw failure('ERR_OHOS_LINUX_PROTOCOL','Host control queue exceeds bound');
    this.queue.push({bytes,sent});this.queuedBytes+=bytes.length;this.flush();
  }
  flush(){
    if(this.failed||this.flushing)return;this.flushing=true;
    try{while(!this.blocked&&this.queue.length){const {bytes,sent}=this.queue.shift();this.queuedBytes-=bytes.length;const accepted=this.socket.write(bytes);sent();if(!accepted)this.blocked=true;}}
    catch(error){this.break(error);}finally{this.flushing=false;}
  }
  break(error){if(this.failed)return;this.failed=true;this.queue=[];this.queuedBytes=0;this.buffer=Buffer.alloc(0);this.emit('fault',error);this.socket.destroy();}
}
