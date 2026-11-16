import path from 'node:path';
const limit=64*1024*1024, chunk=1024*1024;
const failure=(code)=>Object.assign(new Error(`${code}: native workspace operation unavailable`),{code});
const encoding=value=>typeof value==='string'?value:value?.encoding??'utf8';
export class NativeGrantFs {
  #binding; #handle;
  constructor(binding,ticket){this.#binding=binding;this.#handle=binding.consume(ticket);}
  close(){if(this.#handle){this.#binding.close(this.#handle);this.#handle=null;}}
  #path(value){if(typeof value!=='string'||value.includes('\0')||value.length>4096||!value.startsWith('/'))throw failure('EINVAL');
    if(value==='/')return '';const relative=value.slice(1);if(relative.split('/').some(x=>!x||x==='.'||x==='..'))throw failure('EACCES');return relative;}
  #call(method,...args){if(!this.#handle)throw failure('ERR_WORKSPACE_LEASE');return this.#binding[method](this.#handle,...args);}
  #readBuffer(value){const relative=this.#path(value),parts=[];let size=0;
    while(true){const bytes=this.#call('read',relative,size,Math.min(chunk,limit-size+1));if(bytes.length===0)break;
      size+=bytes.length;if(size>limit)throw failure('ERR_WORKSPACE_LIMIT');parts.push(bytes);}
    return Buffer.concat(parts,size);}
  async readFileBuffer(value){return this.#readBuffer(value);}
  async #readCopyBuffer(value){return this.#readBuffer(value);}
  // Same 64 MiB resource ceiling as whole reads; never report a truncated file
  // as EOF. The caller owns this handle until iteration closes.
  async *readFileChunks(value,signal){const relative=this.#path(value);let size=0;
    while(true){signal?.throwIfAborted();
      const bytes=this.#call('read',relative,size,Math.min(chunk,limit-size+1));
      signal?.throwIfAborted();if(bytes.length===0)return;
      size+=bytes.length;if(size>limit)throw failure('ERR_WORKSPACE_LIMIT');yield bytes;}}
  // Raw bytes from the requested offset; no whole-file read or text conversion.
  async readFileWindow(value,{offset,length},signal){const relative=this.#path(value);
    if(!Number.isSafeInteger(offset)||offset<0||!Number.isSafeInteger(length)||length<0||!Number.isSafeInteger(offset+length))throw failure('EINVAL');
    const parts=[];let size=0;
    while(size<length){signal?.throwIfAborted();
      const bytes=this.#call('read',relative,offset+size,Math.min(chunk,length-size));
      signal?.throwIfAborted();if(bytes.length===0)break;
      size+=bytes.length;parts.push(bytes);}
    return Buffer.concat(parts,size);}
  async readFile(value,options){return (await this.readFileBuffer(value)).toString(encoding(options));}
  async readFileBytes(value){return (await this.readFileBuffer(value)).toString('latin1');}
  async #write(value,content,options,append,ownedCopy=false){const relative=this.#path(value);if(!relative)throw failure('EISDIR');
    const bytes=ownedCopy?content:typeof content==='string'?Buffer.from(content,encoding(options)):Buffer.from(content);if(bytes.length>limit)throw failure('ERR_WORKSPACE_LIMIT');
    const position=typeof options==='object'?(options.ohosWritePosition??(options.ohosOverwriteAtStart===true?0:undefined)):undefined;
    if(position!==undefined&&(!Number.isSafeInteger(position)||position<0||!Number.isSafeInteger(position+bytes.length)))throw failure('EINVAL');
    let offset=0,first=true;do{const part=bytes.subarray(offset,Math.min(offset+chunk,bytes.length));
      const count=this.#call('write',relative,part,(position??0)+offset,1|(append?4:first&&position===undefined?2:0));first=false;
      if(count<0||count>part.length||(part.length&&count===0))throw failure('EIO');offset+=count;
    }while(offset<bytes.length);}
  writeFile(value,content,options){return this.#write(value,content,options,false);}
  appendFile(value,content,options){return this.#write(value,content,options,true);}
  async lstat(value){const st=this.#call('stat',this.#path(value));return {isFile:st.type===1,isDirectory:st.type===2,isSymbolicLink:st.type===3,
    size:st.size,mode:st.mode,mtime:new Date(st.mtimeMs),dev:st.dev,ino:st.ino};}
  async stat(value){const st=await this.lstat(value);if(st.isSymbolicLink)throw failure('ELOOP');return st;}
  async lstatExact(value){const st=this.#call('statExact',this.#path(value));return {...st,isFile:st.type===1,isDirectory:st.type===2,isSymbolicLink:st.type===3};}
  async statExact(value){const st=await this.lstatExact(value);if(st.isSymbolicLink)throw failure('ELOOP');return st;}
  async exists(value){try{await this.lstat(value);return true;}catch(error){if(['ENOENT','ENOTDIR'].includes(error.code))return false;throw error;}}
  async readdir(value){return this.#call('readdir',this.#path(value));}
  async readdirWithFileTypes(value){const names=await this.readdir(value);return Promise.all(names.map(async name=>({name,...await this.lstat(path.posix.join(value,name))})));}
  async mkdir(value,options={}){const relative=this.#path(value);if(!relative){if(options.recursive)return;throw failure('EEXIST');}
    if(!options.recursive){this.#call('mutate','mkdir',relative);return;}
    let current='';for(const part of relative.split('/')){current+='/'+part;try{this.#call('mutate','mkdir',current.slice(1));}
      catch(error){if(error.code!=='EEXIST'||!(await this.stat(current)).isDirectory)throw error;}}}
  async createExclusive(value,options={}){if(options.directory){if(options.mode!==0o700)throw failure('ENOTSUP');return this.mkdir(value);}
    if(options.mode!==0o600)throw failure('ENOTSUP');this.#call('write',this.#path(value),Buffer.alloc(0),0,1|8);}
  async rm(value,options={},depth=0){const relative=this.#path(value);if(!relative)throw failure('EBUSY');if(depth>64)throw failure('ERR_WORKSPACE_LIMIT');
    let st;try{st=await this.lstat(value);}catch(error){if(options.force&&error.code==='ENOENT')return;throw error;}
    if(st.isDirectory&&options.recursive)for(const name of await this.readdir(value))await this.rm(path.posix.join(value,name),options,depth+1);
    this.#call('mutate','remove',relative,st.isDirectory);}
  async mv(source,dest){const from=this.#path(source),to=this.#path(dest);if(!from||!to)throw failure('EBUSY');this.#call('mutate','rename',from,to);}
  async cp(source,dest,options={},depth=0){if(depth>64)throw failure('ERR_WORKSPACE_LIMIT');const st=await this.lstat(source);
    if(st.isDirectory){if(!options.recursive)throw failure('EISDIR');await this.mkdir(dest,{recursive:true});for(const name of await this.readdir(source))await this.cp(path.posix.join(source,name),path.posix.join(dest,name),options,depth+1);}
    else if(st.isFile)await this.#write(dest,await this.#readCopyBuffer(source),undefined,false,true);else throw failure('ENOTSUP');}
  resolvePath(base,value){return path.posix.resolve(base,value);}
  getAllPaths(){return [];}
  async realpath(value){await this.stat(value);return value;}
  async readlink(){throw failure('ENOTSUP');}
  async chmod(){throw failure('ENOTSUP');}
  async utimes(){throw failure('ENOTSUP');}
  async link(){throw failure('ENOTSUP');}
  async symlink(){throw failure('ENOTSUP');}
}

// One opaque metadata domain for read observations and the private edit scope.
export function grantFileObservation(info,grant){
  if(info.schemaVersion!==1)throw failure('ERR_WORKSPACE_HOST_ABI');
  return {type:info.type===1?'file':info.type===2?'directory':info.type===3?'symlink':'other',size:Number(info.size),
    version:`ohos-grant:${grant.id}:${grant.generation}:${info.dev}:${info.ino}:${info.size}:${info.mtimeSec}:${info.mtimeNsec}:${info.ctimeSec}:${info.ctimeNsec}`};
}
