import { Readable, Writable } from 'node:stream';
import { WINDOW, CHUNK, failure } from './controller.mjs';

export class GuestOutput {
  constructor({mode,collector,label,send,onFault,onSinkClosed}) {
    this.mode=mode;this.collector=collector;this.label=label;this.send=send;this.onFault=onFault;this.onSinkClosed=onSinkClosed;
    this.received=0n;this.acked=0n;this.accepted=0n;this.queue=[];this.queuedBytes=0;this.blocked=false;this.pendingAck=null;this.eof=false;this.ended=false;this.discard=mode==='ignore';
    if(mode==='pipe'){
      const owner=this;
      this.readable=new Readable({highWaterMark:WINDOW,read(){owner.blocked=false;owner.pump();},destroy(error,callback){owner.discard=true;owner.blocked=false;owner.pump();if(!owner.ended)owner.onSinkClosed();callback(error);}});
      this.readable.on('error',()=>{});
    }
  }
  data(start,bytes){
    if(this.eof||start!==this.received||bytes.length<1||bytes.length>CHUNK||this.received+BigInt(bytes.length)-this.acked>BigInt(WINDOW))throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest output offset/credit violation');
    this.received+=BigInt(bytes.length);this.queue.push({bytes,end:this.received});this.queuedBytes+=bytes.length;this.pump();
  }
  ack(end){this.accepted=end;this.send(this.label,end,()=>{this.acked=end;});}
  pump(){
    if(this.pumping)return;this.pumping=true;
    try {
      if(!this.blocked&&this.pendingAck!==null){const end=this.pendingAck;this.pendingAck=null;this.ack(end);}
      while(!this.blocked&&this.queue.length){const {bytes,end}=this.queue.shift();this.queuedBytes-=bytes.length;
        if(this.discard){this.ack(end);continue;}
        if(this.collector){this.collector.push(Buffer.from(bytes));this.ack(end);continue;}
        if(this.readable){if(this.readable.push(Buffer.from(bytes)))this.ack(end);else{this.blocked=true;this.pendingAck=end;}continue;}
        const sink=process[this.label];
        if(sink.write(bytes))this.ack(end);else{this.blocked=true;this.pendingAck=end;sink.once('drain',()=>{this.blocked=false;this.pump();});}
      }
      if(this.eof&&!this.blocked&&!this.queue.length&&!this.ended){this.ended=true;this.readable?.push(null);}
    }catch(error){this.onFault(error);}finally{this.pumping=false;}
  }
  end(through){if(this.eof||through!==this.received)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest output EOF mismatch');this.eof=true;this.pump();}
  disposeDrain(){if(this.readable){this.readable.unpipe();this.readable.resume();}else this.pump();}
  fail(error){this.ended=true;this.queue=[];this.queuedBytes=0;this.pendingAck=null;this.readable?.destroy(error);}
}

export class GuestInput extends Writable {
  constructor({send,onFault}){super({highWaterMark:WINDOW});this.send=send;this.onFault=onFault;this.sent=0n;this.acked=0n;this.enabled=false;this.guestClosed=false;this.cancelled=false;this.pending=null;this.on('error',()=>{});}
  _write(chunk,_encoding,callback){this.pending={bytes:Buffer.from(chunk),position:0,end:this.sent+BigInt(chunk.length),callback};this.pump();}
  pump(){
    if(!this.enabled||this.cancelled||this.guestClosed||!this.pending)return;
    try{const p=this.pending;while(p.position<p.bytes.length&&this.sent-this.acked<BigInt(WINDOW)){
      const n=Math.min(CHUNK,p.bytes.length-p.position,Number(BigInt(WINDOW)-(this.sent-this.acked)));const bytes=p.bytes.subarray(p.position,p.position+n);const start=this.sent;p.position+=n;this.sent+=BigInt(n);this.send('stdin',{offset:String(start),data:bytes.toString('base64')});
    }
    if(p.position===p.bytes.length&&this.acked===p.end){this.pending=null;p.callback();}}
    catch(error){this.onFault(error);}
  }
  acknowledge(through){if(through<=this.acked||through>this.sent)throw failure('ERR_OHOS_LINUX_PROTOCOL','Guest stdin ACK exceeds actual write range');this.acked=through;this.pump();}
  enable(){this.enabled=true;this.pump();this.finishInput();}
  _final(callback){this.finalCallback=callback;this.finishInput();}
  finishInput(){if(!this.enabled||!this.finalCallback)return;const callback=this.finalCallback;this.finalCallback=null;try{this.endNow();callback();}catch(error){callback(error);this.onFault(error);}}
  endNow(){if(this.enabled&&!this.cancelled&&!this.guestClosed&&!this.endSent){this.endSent=true;this.send('stdin-end',{});}}
  _destroy(error,callback){const p=this.pending;this.pending=null;if(p)p.callback(error??failure('EPIPE','Guest stdin closed before write ACK'));try{this.endNow();}catch{}if(this.enabled)this.guestClosed=true;callback(error);}
  closeFromGuest(){this.guestClosed=true;this.destroy(failure('EPIPE','Guest closed stdin before pending bytes were accepted'));}
  stop(){this.cancelled=true;this.destroy(failure('ABORT_ERR','Guest stdin cancelled'));}
}
