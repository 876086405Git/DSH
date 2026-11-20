// 酒馆助手's interfaces that stage 4 of the engine answers
// (STAGE4-APP-INTEGRATION): world books and their bindings, world info
// settings, presets, regexes to write, a script's buttons, the character's
// card and picture, the synchronous macro and regex helpers, initializeGlobal,
// and MVU's Mvu as a local module the engine's native MVU answers. A piece of
// the canvas page's script (tavern_canvas.dart), spliced in where its own
// helpers are defined, so it uses theirs: call, track, attempt, clone, msgs,
// getVariables, replaceVariables, card, cardId, callerScript…
//
// What the page knows of the engine's resources (resourceRefs: book
// directory and bindings, world info settings, the preset in use and the
// preset library, regexes, the character's card) is the snapshot's, then each
// delivery's (adoptResources). Synchronous getters read that; anything else
// asks the engine, reading the version it then writes with.

/// The page's script for these interfaces; [mvu] says whether the card uses
/// MVU (its scripts import MagVarUpdate, or it says so in its extensions).
String tavernCanvasHelpersJs({required bool mvu}) => 'var mvuWanted=$mvu;$_js';

const _js = r'''
  var res={},ctx=null,storedPresets={},presetsLoading=null;
  function adoptResources(r,context){
    if(context)ctx=context;
    if(!r||!Object.keys(r).length)return;
    var before=(res.presetLibrary||{}).version,was=res.preset;
    res=r;
    presetDelivered(was,r.preset);
    if(card&&r.characterData&&r.characterData.data)card=r.characterData.data;
    if(r.regex)regexes=regexBuckets(r.regex);
    if((r.presetLibrary||{}).version!==before)storedPresets={};
  }
  function chatIdNow(){return ctx&&ctx.chatId||SillyTavern.getCurrentChatId()||null;}
  function share(name,f){dsh.scripts[name]=f;if(!window[name])window[name]=f;if(shared.indexOf(name)<0)shared.push(name);}
  function refused(code,message){var e=new Error(message);e.code=code;e.committed=false;return e;}

  // initializeGlobal / waitGlobalInitialized: what one script shares with
  // the others (MVU shares Mvu so), on this page and in every script's frame.
  var globals={},globalWaiters={};
  function initializeGlobal(name,value){
    name=String(name);globals[name]=value;window[name]=value;
    if(shared.indexOf(name)<0)shared.push(name);
    [].forEach.call(document.querySelectorAll('iframe[data-script]'),function(f){try{f.contentWindow[name]=value;}catch(e){}});
    var waiting=globalWaiters[name]||[];delete globalWaiters[name];
    waiting.forEach(function(ok){ok(value);});
  }
  function waitGlobalInitialized(name){
    name=String(name);
    if(Object.prototype.hasOwnProperty.call(globals,name))return Promise.resolve(globals[name]);
    return new Promise(function(ok){(globalWaiters[name]||(globalWaiters[name]=[])).push(ok);});
  }
  share('initializeGlobal',initializeGlobal);share('waitGlobalInitialized',waitGlobalInitialized);
  // The bundled zod and YAML, as 酒馆助手 gives them: on every script's frame,
  // and what waitGlobalInitialized('z') waits for.
  ['z','YAML'].forEach(function(n){if(window[n]!==undefined)initializeGlobal(n,window[n]);});

  // MVU (MagVarUpdate) as a local module: the engine keeps the variables
  // ([initvar], <UpdateVariable>, its four events); Mvu reads and writes
  // them as MVU's own does. A card's import of MagVarUpdate is this.
  var MVU_EVENTS={VARIABLE_INITIALIZED:'mag_variable_initialized',VARIABLE_UPDATE_STARTED:'mag_variable_update_started',
    COMMAND_PARSED:'mag_command_parsed',VARIABLE_UPDATE_ENDED:'mag_variable_update_ended'};
  var mvuImport=/import\s*(?:[\w*{}\s,]+from\s*)?(['"])[^'"\n]*MagVarUpdate[^'"\n]*\1\s*;?/g;
  function withoutMvuImport(code){return mvuWanted?String(code).replace(mvuImport,'/* MagVarUpdate: built in */'):code;}
  function isMvuSrc(src){return mvuWanted&&/MagVarUpdate/i.test(String(src||''));}
  function reportIssues(list){if(list&&list.length)post({type:'issues',issues:list});}
  function isVwd(v){return Array.isArray(v)&&v.length===2&&typeof v[1]==='string';}
  function message(o){return o||{type:'chat'};}
  var Mvu={
    events:MVU_EVENTS,
    getMvuData:function(o){return getVariables(message(o));},
    replaceMvuData:function(data,o){return dsh.scripts.replaceVariables(data,message(o)).then(function(){});},
    // A candidate only: nothing is saved until replaceMvuData.
    parseMessage:function(text,old){
      return track(call('parseMvuMessage',{message:String(text),previousData:old||{}}).then(function(r){reportIssues(r.issues);return r.data;}));
    },
    getCurrentMvuData:function(){return getVariables({type:'message',message_id:getCurrentMessageId()});},
    replaceCurrentMvuData:function(data){
      return dsh.scripts.replaceVariables(data,{type:'message',message_id:getCurrentMessageId()}).then(function(){});
    },
    // The engine reads [initvar] itself, when MVU starts for a chat.
    reloadInitVar:function(){return Promise.resolve(false);},
    setMvuVariable:function(data,path,value){
      var s=steps(path),at=data.stat_data||(data.stat_data={});
      for(var i=0;i<s.length-1;i++){if(at[s[i]]===null||typeof at[s[i]]!=='object')at[s[i]]={};at=at[s[i]];}
      var last=s[s.length-1];
      if(isVwd(at[last]))at[last][0]=value;else at[last]=value;
      return Promise.resolve(true);
    },
    getMvuVariable:function(data,path,o){
      o=o||{};var v=dig((data||{})[(o.category||'stat')+'_data'],steps(path));
      if(v===undefined)v=o.default_value;
      return isVwd(v)?v[0]:v;
    },
    getRecordFromMvuData:function(data,category){return (data||{})[(category||'stat')+'_data']||{};}
  };
  // Turned on for this chat before the card's scripts run, then shared;
  // what the engine says went wrong is told.
  function mvuStart(){
    if(!mvuWanted)return Promise.resolve();
    // Not kept for an event's answer: the engine's MVU events it starts
    // come back here, and their answers would wait on it.
    return ask('setMvuEnabled',{enabled:true}).then(function(r){reportIssues(r.issues);},function(e){
      reportIssues([{code:e.code||'mvu_update_failed',message:String(e.message||e)}]);
    }).then(function(){initializeGlobal('Mvu',Mvu);});
  }
  // An MVU event's answer carries what its listeners made of the candidate.
  function mvuFeedback(d){
    var a=d.args||[];
    if(!/^mag_(variable_initialized|variable_update_started|command_parsed|variable_update_ended)$/.test(d.name||''))return null;
    if(!a[0]||typeof a[0]!=='object')return null;
    var fb={data:a[0]};
    if(d.name==='mag_command_parsed'&&Array.isArray(a[1]))fb.commands=a[1];
    if(d.name==='mag_variable_update_ended'&&a[1]&&typeof a[1]==='object')fb.beforeData=a[1];
    return fb;
  }

  // Macros, at once (substitudeMacros, as 酒馆助手 spells it): from this
  // page's copy. {{get_message_variable::path}} and
  // {{format_message_variable::path}} read the message the caller is in (or
  // the latest); a path that is not there leaves the macro as written.
  function dig(v,path){
    if(!path)return undefined;
    for(var i=0;i<path.length;i++){
      if(v===null||typeof v!=='object'||!Object.prototype.hasOwnProperty.call(v,path[i]))return undefined;
      v=v[path[i]];
    }
    return v;
  }
  function macroPath(p){
    var out=[],ok=true;
    String(p).trim().split('.').forEach(function(seg){
      var m=/^([^\[\]]*)((?:\[\d+\])*)$/.exec(seg);
      if(!m||(m[1]===''&&!m[2])){ok=false;return;}
      if(m[1]!=='')out.push(m[1]);
      m[2].replace(/\[(\d+)\]/g,function(all,n){out.push(+n);return all;});
    });
    return ok&&out.length?out:null;
  }
  function messageVariables(){
    var id;try{id=getCurrentMessageId();}catch(e){id=msgs.length-1;}
    var m=msgs[id];return m&&m.data&&typeof m.data==='object'?m.data:{};
  }
  function noDollar(v){
    if(Array.isArray(v))return v.map(noDollar);
    if(v&&typeof v==='object'){var o={};for(var k in v)if(k.charAt(0)!=='$')o[k]=noDollar(v[k]);return o;}
    return v;
  }
  function yamlScalar(v){
    if(v===null||v===undefined)return 'null';
    if(typeof v==='number'||typeof v==='boolean')return String(v);
    var s=String(v);
    if(s===''||/^\s|\s$|^[-?:,\[\]{}#&*!|>'"%@`]|: | #|\n|^(true|false|null|yes|no|on|off|~)$|^[-+.]?\d/i.test(s))return JSON.stringify(s);
    return s;
  }
  function yamlValue(v){
    if(Array.isArray(v))return v.length?null:'[]';
    if(v&&typeof v==='object')return Object.keys(v).length?null:'{}';
    return yamlScalar(v);
  }
  function yamlLines(v,pad){
    var lines=[],list=Array.isArray(v);
    function put(head,x){
      var flat=yamlValue(x);
      if(flat!==null){lines.push(head+(list?'':' ')+flat);return;}
      if(list&&!Array.isArray(x)){
        var sub=yamlLines(x,pad+'  ');sub[0]=head+sub[0].slice(pad.length+2);
        lines.push.apply(lines,sub);
      }else{lines.push(head.replace(/ $/,''));lines.push.apply(lines,yamlLines(x,pad+'  '));}
    }
    if(list)v.forEach(function(x){put(pad+'- ',x);});
    else Object.keys(v).forEach(function(k){put(pad+(/^[^\s\-?:,\[\]{}#&*!|>'"%@`][^:#\n]*$/.test(k)&&!/\s$/.test(k)?k:JSON.stringify(k))+':',v[k]);});
    return lines;
  }
  function toYaml(v){var flat=yamlValue(v);return (flat!==null?flat:yamlLines(v,'').join('\n')).replace(/\s+$/,'');}
  function substitudeMacros(text){
    var chat=getVariables({type:'chat'}),global=null;
    return String(text).replace(/\{\{([^{}]*)\}\}/g,function(all,inner){
      var at=inner.indexOf('::'),name=(at<0?inner:inner.slice(0,at)).trim().toLowerCase(),arg=at<0?'':inner.slice(at+2);
      if(name==='user')return getCurrentPersonaName()||'';
      if(name==='char')return getCurrentCharacterName()||'';
      if(name==='lastmessageid')return String(msgs.length-1);
      if(name==='getvar'){var c=chat[arg.trim()];return c===undefined?'':typeof c==='object'?JSON.stringify(c):String(c);}
      if(name==='getglobalvar'){
        if(!global)global=getVariables({type:'global'});
        var g=global[arg.trim()];return g===undefined?'':typeof g==='object'?JSON.stringify(g):String(g);
      }
      if(name==='get_message_variable'||name==='format_message_variable'){
        var v=dig(messageVariables(),macroPath(arg));
        if(v===undefined)return all;
        if(name==='format_message_variable')return toYaml(noDollar(v));
        if(typeof v==='string')return v;
        return v===null?'null':JSON.stringify(v);
      }
      return all;
    });
  }
  share('substitudeMacros',substitudeMacros);

  // formatAsTavernRegexedString(text, source, destination, {depth}): the
  // regexes in play for this chat, as the engine last told this page, the
  // way ST runs them for display or for the prompt.
  var placements={user_input:1,ai_output:2,slash_command:3,world_info:5,reasoning:6};
  function regexFrom(s){
    var m=/^\/([\s\S]+)\/([dgimsuvy]*)$/.exec(String(s));
    try{return m?new RegExp(m[1],m[2]):new RegExp(String(s));}catch(e){return null;}
  }
  function trimmed(s,trims){
    [].concat(trims||[]).forEach(function(t){if(t)s=s.split(substitudeMacros(t)).join('');});
    return s;
  }
  function formatAsTavernRegexedString(text,source,destination,o){
    var place=placements[source],depth=o&&typeof o.depth==='number'?o.depth:null,out=String(text);
    if(!place)throw new TypeError('source is one of '+Object.keys(placements).join(', '));
    if(destination!=='display'&&destination!=='prompt')throw new TypeError('destination is display or prompt');
    ((res.regex||{}).rules||[]).forEach(function(rule){
      var x=rule.raw||{},pl=[].concat(x.placement||[]),legacy=pl.indexOf(0)>=0;
      if(!rule.effective||(!legacy&&pl.indexOf(place)<0))return;
      if(!legacy&&(destination==='display'?!x.markdownOnly:!x.promptOnly))return;
      if(depth!==null&&((typeof x.minDepth==='number'&&x.minDepth>=-1&&depth<x.minDepth)||
        (typeof x.maxDepth==='number'&&x.maxDepth>=0&&depth>x.maxDepth)))return;
      var find=regexFrom(x.substituteRegex?substitudeMacros(x.findRegex||''):x.findRegex||'');
      if(!find)return;
      var replace=String(x.replaceString||'').replace(/\{\{match\}\}/gi,'$0');
      out=out.replace(find,function(){
        var args=[].slice.call(arguments),groups=typeof args[args.length-1]==='object'?args[args.length-1]:{};
        return substitudeMacros(replace.replace(/\$(\d+)|\$<([^>]+)>/g,function(all,n,name){
          var m=n!==undefined?args[+n]:(groups||{})[name];
          return m?trimmed(String(m),x.trimStrings):'';
        }));
      });
    });
    return out;
  }
  share('formatAsTavernRegexedString',formatAsTavernRegexedString);

  // getTavernRegexes' copy: the engine's regexes for this context by source,
  // in 酒馆助手's shape (its ST fields renamed). ST's old placement 0 is
  // everywhere, for display and for the prompt, as the engine runs it.
  var regexPlaces={1:'user_input',2:'ai_output',3:'slash_command',5:'world_info',6:'reasoning'};
  function helperRegex(rule){
    var x=rule.raw||{},pl=[].concat(x.placement||[]),legacy=pl.indexOf(0)>=0,src={};
    for(var k in regexPlaces)src[regexPlaces[k]]=legacy||pl.indexOf(+k)>=0;
    var out={id:x.id||rule.stId,script_name:x.scriptName||'',enabled:!!rule.enabled,run_on_edit:!!x.runOnEdit,
      find_regex:x.findRegex||'',trim_strings:[].concat(x.trimStrings||[]).join('\n'),replace_string:x.replaceString||'',
      source:src,destination:{display:legacy||!!x.markdownOnly,prompt:legacy||!!x.promptOnly},
      min_depth:typeof x.minDepth==='number'?x.minDepth:null,max_depth:typeof x.maxDepth==='number'?x.maxDepth:null};
    if(rule.source!=='preset')out.scope=rule.source;
    return out;
  }
  function regexBuckets(view){
    var b={global:[],preset:[],character:[],chat:[]};
    (view.rules||[]).forEach(function(r){if(b[r.source])b[r.source].push(helperRegex(r));});
    return b;
  }
  // Written back (replaceTavernRegexes): each to the source it is kept in —
  // global ones to the library entry or the settings list they came from,
  // new ones to the settings list; the character's to its card; the
  // preset's to the preset in use.
  function rawRegex(h,old){
    var x=Object.assign({},old||{});
    if(h.id!==undefined)x.id=String(h.id);
    if(h.script_name!==undefined)x.scriptName=String(h.script_name);
    if(h.enabled!==undefined)x.disabled=!h.enabled;
    if(h.run_on_edit!==undefined)x.runOnEdit=!!h.run_on_edit;
    if(h.find_regex!==undefined)x.findRegex=String(h.find_regex);
    if(h.replace_string!==undefined)x.replaceString=String(h.replace_string);
    if(h.trim_strings!==undefined)x.trimStrings=String(h.trim_strings).split('\n').filter(function(s){return s;});
    if(h.source){x.placement=[];for(var k in regexPlaces)if(h.source[regexPlaces[k]])x.placement.push(+k);}
    if(h.destination){x.markdownOnly=!!h.destination.display;x.promptOnly=!!h.destination.prompt;}
    if(h.min_depth!==undefined)x.minDepth=h.min_depth;
    if(h.max_depth!==undefined)x.maxDepth=h.max_depth;
    return x;
  }
  function regexTarget(type){
    if(type==='character'){if(!cardId)throw refused('noContext','This chat has no one character');return {kind:'character',characterId:cardId};}
    if(type==='preset')return {kind:'preset',preset:{kind:'current'}};
    throw new TypeError('type is global, character or preset');
  }
  function writeRegexes(target,list){
    return call('readTavernRegexesForWrite',{target:target}).then(function(s){
      var byId={};s.items.forEach(function(i){if(i.raw&&i.raw.id!=null)byId[i.raw.id]=i;});
      return call('replaceTavernRegexes',{target:target,expectedVersion:s.version,items:list.map(function(h){
        var old=byId[h.id];return {engineId:old?old.engineId:undefined,raw:rawRegex(h,old&&old.raw)};
      })});
    });
  }
  function replaceTavernRegexes(list,o){return attempt(function(){
    o=o||{};list=[].concat(list||[]);
    var type=o.type||o.scope||'global';
    if(type==='all')return Promise.reject(refused('unsupportedOption','Give type: global, character or preset'));
    if(type!=='global')return writeRegexes(regexTarget(type),list).then(function(){});
    // Global ones live in two places; each keeps its own.
    return Promise.all([call('readTavernRegexesForWrite',{target:{kind:'globalLibrary'}}),
      call('readTavernRegexesForWrite',{target:{kind:'globalInline'}})]).then(function(both){
      var inLibrary={};both[0].items.forEach(function(i){if(i.raw&&i.raw.id!=null)inLibrary[i.raw.id]=i;});
      var inline={};both[1].items.forEach(function(i){if(i.raw&&i.raw.id!=null)inline[i.raw.id]=i;});
      var library=list.filter(function(h){return inLibrary[h.id];});
      var rest=list.filter(function(h){return !inLibrary[h.id];});
      return call('replaceTavernRegexes',{target:{kind:'globalLibrary'},expectedVersion:both[0].version,items:library.map(function(h){
        var old=inLibrary[h.id];return {engineId:old.engineId,raw:rawRegex(h,old.raw)};
      })}).then(function(){
        return call('replaceTavernRegexes',{target:{kind:'globalInline'},expectedVersion:both[1].version,items:rest.map(function(h){
          var old=inline[h.id];return {raw:rawRegex(h,old&&old.raw)};
        })});
      });
    }).then(function(){});
  });}
  function updateTavernRegexesWith(updater,o){return attempt(function(){
    var type=(o&&(o.type||o.scope))||'global';
    var now=getTavernRegexes({type:type});
    return Promise.resolve(updater(now)).then(function(n){n=n===undefined?now:n;return replaceTavernRegexes(n,o).then(function(){return n;});});
  });}
  share('replaceTavernRegexes',watched(replaceTavernRegexes));share('updateTavernRegexesWith',watched(updateTavernRegexesWith));

  // A script's buttons (the app shows them over the composer): kept on its
  // owner, by its key; a press is the event getButtonEvent names.
  // buttonWrites: a script's writes still out; listMoved: the list changed
  // under one, so a refused write falls back to the list, not to before.
  // buttonGen: bumped when a script's frame is taken down, so a write from
  // before then settles against nothing of its successor's.
  var buttons={},buttonWrites={},listMoved={},buttonGen={};
  function buttonScript(id){
    var s=id==null?callerScript():scriptById(String(id));
    if(!s)throw new Error('Buttons are a script\'s own: called from one, or by its script_id');
    if(!buttons[s.key])buttons[s.key]=clone(s.buttonList||[]);
    return s;
  }
  function tellButtons(key){
    post({type:'buttons',key:key,names:buttons[key].filter(function(b){return b.visible;}).map(function(b){return b.name;})});
  }
  function asButtons(list){
    return [].concat(list||[]).map(function(b){return typeof b==='string'?{name:b,visible:true}:{name:String(b.name),visible:b.visible!==false};});
  }
  function getScriptButtons(id){return clone(buttons[buttonScript(id).key]);}
  function setButtons(s,list){
    var before=buttons[s.key],mine=buttons[s.key]=list;tellButtons(s.key);
    buttonWrites[s.key]=(buttonWrites[s.key]||0)+1;
    var gen=buttonGen[s.key]||0;
    function settled(){if((buttonGen[s.key]||0)!==gen||--buttonWrites[s.key])return false;var moved=listMoved[s.key];delete listMoved[s.key];return moved;}
    return call('replaceScriptButtons',{asScript:s.key,buttons:list}).then(function(r){
      settled();
      if(buttons[s.key]===mine){buttons[s.key]=r.buttons;tellButtons(s.key);}
    },function(e){
      var moved=settled(),f=frames[s.key];
      // Not kept: the ones that were back, or the list's if it moved since.
      if(buttons[s.key]===mine){buttons[s.key]=moved&&f?clone(f.buttonList||[]):before;tellButtons(s.key);}
      throw e;
    });
  }
  // The list's buttons for a script changed (another page, the library):
  // taken as they now are, and told to the composer, unless a write of its
  // own is still out (its answer decides).
  function listButtons(key,list){
    if(!buttons[key])return;
    if(buttonWrites[key]){listMoved[key]=true;return;}
    buttons[key]=clone(list||[]);tellButtons(key);
  }
  function replaceScriptButtons(a,b){return attempt(function(){
    var s=b===undefined?buttonScript():buttonScript(a);return setButtons(s,asButtons(b===undefined?a:b));
  });}
  function appendInexistentScriptButtons(a,b){return attempt(function(){
    var s=b===undefined?buttonScript():buttonScript(a),now=buttons[s.key].slice(),have={};
    now.forEach(function(x){have[x.name]=true;});
    asButtons(b===undefined?a:b).forEach(function(x){if(!have[x.name]){have[x.name]=true;now.push(x);}});
    return setButtons(s,now);
  });}
  function updateScriptButtonsWith(updater,id){return attempt(function(){
    var s=buttonScript(id),now=clone(buttons[s.key]);
    return Promise.resolve(updater(now)).then(function(n){
      var list=asButtons(n===undefined?now:n);return setButtons(s,list).then(function(){return clone(buttons[s.key]);});
    });
  });}
  share('getScriptButtons',getScriptButtons);share('replaceScriptButtons',watched(replaceScriptButtons));
  share('appendInexistentScriptButtons',watched(appendInexistentScriptButtons));
  share('updateScriptButtonsWith',watched(updateScriptButtonsWith));

  // World books. A book is named as the engine's directory names it; the
  // engine resolves a name (or a stable handle) to the one book, and says
  // when more than one goes by it. Entries are read whole, changed here, and
  // written back whole with the version read: each keeps its uid, whether it
  // is off, and whatever fields this page does not know. Standalone books
  // keep ST's world shape (entries by uid), a card's own its card_book shape.
  var POS=['before_character_definition','after_character_definition','before_author_note','after_author_note','at_depth',
    'before_example_messages','after_example_messages','outlet'];
  var ROLES=['system','user','assistant'],LOGIC=['and_any','not_all','not_any','and_all'];
  var CARD_EXT={depth:'depth',role:'role',probability:'probability',useProbability:'useProbability',selectiveLogic:'selectiveLogic',
    excludeRecursion:'exclude_recursion',preventRecursion:'prevent_recursion',delayUntilRecursion:'delay_until_recursion',
    scanDepth:'scan_depth',caseSensitive:'case_sensitive',matchWholeWords:'match_whole_words',useGroupScoring:'use_group_scoring',
    automationId:'automation_id',group:'group',groupOverride:'group_override',groupWeight:'group_weight',sticky:'sticky',
    cooldown:'cooldown',delay:'delay',displayIndex:'display_index',vectorized:'vectorized'};
  var FRESH={key:[],keysecondary:[],comment:'',content:'',constant:false,vectorized:false,selective:true,selectiveLogic:0,
    addMemo:true,order:100,position:0,disable:false,excludeRecursion:false,preventRecursion:false,delayUntilRecursion:false,
    probability:100,useProbability:true,depth:4,group:'',groupOverride:false,groupWeight:100,scanDepth:null,caseSensitive:null,
    matchWholeWords:null,useGroupScoring:null,automationId:'',role:0,sticky:0,cooldown:0,delay:0};
  function fromCardEntry(e){
    var x=e.extensions||{},f={uid:e.id,key:e.keys||[],keysecondary:e.secondary_keys||[],comment:e.comment||e.name||'',
      content:e.content||'',constant:!!e.constant,selective:e.selective!==false,order:e.insertion_order,disable:e.enabled===false,
      position:x.position!=null?x.position:(e.position==='after_char'?1:0)};
    for(var k in CARD_EXT)if(x[CARD_EXT[k]]!==undefined)f[k]=x[CARD_EXT[k]];
    return f;
  }
  function toCardEntry(raw,f){
    var e=Object.assign({},raw||{}),x=Object.assign({},e.extensions||{});
    e.id=f.uid;e.keys=f.key;e.secondary_keys=f.keysecondary;e.comment=f.comment;e.content=f.content;
    e.constant=f.constant;e.selective=f.selective;e.insertion_order=f.order;e.enabled=!f.disable;
    e.position=f.position===1?'after_char':'before_char';x.position=f.position;
    for(var k in CARD_EXT)if(f[k]!==undefined)x[CARD_EXT[k]]=f[k];
    e.extensions=x;
    return e;
  }
  function entriesOf(book){
    var list=book&&book.entries;
    if(Array.isArray(list))return list.map(function(e){return {raw:e,flat:fromCardEntry(e)};});
    var out=[];
    for(var k in list||{}){var e=list[k];out.push({raw:e,flat:Object.assign({},e,{uid:e.uid!=null?e.uid:+k})});}
    return out;
  }
  function toHelperEntry(f){
    return {uid:f.uid,name:f.comment||'',enabled:!f.disable,
      strategy:{type:f.constant?'constant':f.vectorized?'vectorized':'selective',keys:[].concat(f.key||[]),
        keys_secondary:{logic:LOGIC[f.selectiveLogic|0]||'and_any',keys:[].concat(f.keysecondary||[])},
        scan_depth:f.scanDepth==null?'same_as_global':f.scanDepth},
      position:{type:POS[f.position|0]||POS[0],role:ROLES[f.role|0]||'system',depth:f.depth==null?4:f.depth,order:f.order==null?100:f.order},
      content:f.content||'',probability:f.useProbability===false||f.probability==null?100:f.probability,
      recursion:{prevent_incoming:!!f.excludeRecursion,prevent_outgoing:!!f.preventRecursion,
        delay_until:f.delayUntilRecursion?(f.delayUntilRecursion===true?1:f.delayUntilRecursion):null},
      effect:{sticky:f.sticky||null,cooldown:f.cooldown||null,delay:f.delay||null}};
  }
  function keyText(k){return String(k);}
  function fromHelperEntry(h,f){
    f=Object.assign({},f||FRESH);
    if(h.uid!=null)f.uid=h.uid;
    if(h.name!==undefined)f.comment=String(h.name);
    if(h.enabled!==undefined)f.disable=!h.enabled;
    var s=h.strategy;
    if(s){
      if(s.type){f.constant=s.type==='constant';f.vectorized=s.type==='vectorized';}
      if(s.keys)f.key=[].concat(s.keys).map(keyText);
      var k2=s.keys_secondary;
      if(k2){if(LOGIC.indexOf(k2.logic)>=0)f.selectiveLogic=LOGIC.indexOf(k2.logic);if(k2.keys)f.keysecondary=[].concat(k2.keys).map(keyText);}
      if(s.scan_depth!==undefined)f.scanDepth=s.scan_depth==='same_as_global'?null:s.scan_depth;
    }
    var p=h.position;
    if(p){
      if(POS.indexOf(p.type)>=0)f.position=POS.indexOf(p.type);
      if(ROLES.indexOf(p.role)>=0)f.role=ROLES.indexOf(p.role);
      if(p.depth!=null)f.depth=p.depth;
      if(p.order!=null)f.order=p.order;
    }
    if(h.content!==undefined)f.content=String(h.content);
    if(h.probability!=null){f.probability=h.probability;f.useProbability=true;}
    var r=h.recursion;
    if(r){
      if(r.prevent_incoming!==undefined)f.excludeRecursion=!!r.prevent_incoming;
      if(r.prevent_outgoing!==undefined)f.preventRecursion=!!r.prevent_outgoing;
      if(r.delay_until!==undefined)f.delayUntilRecursion=r.delay_until==null?false:r.delay_until;
    }
    var e=h.effect;
    if(e)['sticky','cooldown','delay'].forEach(function(k){if(e[k]!==undefined)f[k]=e[k]||0;});
    return f;
  }
  // 酒馆助手's older lorebook entries (getLorebookEntries and kin).
  function toOldEntry(f){
    var h=toHelperEntry(f),pos=h.position.type;
    if(pos==='at_depth')pos='at_depth_as_'+h.position.role;
    function same(v){return v==null?'same_as_global':v;}
    return {uid:f.uid,display_index:f.displayIndex==null?f.uid:f.displayIndex,comment:h.name,enabled:h.enabled,
      type:h.strategy.type,position:pos,depth:f.position===4?h.position.depth:null,order:h.position.order,
      probability:h.probability,keys:h.strategy.keys,logic:h.strategy.keys_secondary.logic,filters:h.strategy.keys_secondary.keys,
      scan_depth:same(f.scanDepth),case_sensitive:same(f.caseSensitive),match_whole_words:same(f.matchWholeWords),
      use_group_scoring:same(f.useGroupScoring),automation_id:f.automationId||null,exclude_recursion:!!f.excludeRecursion,
      prevent_recursion:!!f.preventRecursion,delay_until_recursion:!!f.delayUntilRecursion,content:h.content,group:f.group||'',
      group_prioritized:!!f.groupOverride,group_weight:f.groupWeight==null?100:f.groupWeight,
      sticky:f.sticky||null,cooldown:f.cooldown||null,delay:f.delay||null};
  }
  function fromOldEntry(o,f){
    var pos=o.position,role;
    if(pos&&pos.indexOf('at_depth_as_')===0){role=pos.slice(12);pos='at_depth';}
    f=fromHelperEntry({uid:o.uid,name:o.comment,enabled:o.enabled,content:o.content,probability:o.probability,
      strategy:{type:o.type,keys:o.keys,keys_secondary:{logic:o.logic,keys:o.filters},scan_depth:o.scan_depth},
      position:{type:pos,role:role,depth:o.depth,order:o.order}},f);
    function same(v,k){if(v!==undefined)f[k]=v==='same_as_global'?null:v;}
    same(o.case_sensitive,'caseSensitive');same(o.match_whole_words,'matchWholeWords');same(o.use_group_scoring,'useGroupScoring');
    if(o.automation_id!==undefined)f.automationId=o.automation_id||'';
    if(o.exclude_recursion!==undefined)f.excludeRecursion=!!o.exclude_recursion;
    if(o.prevent_recursion!==undefined)f.preventRecursion=!!o.prevent_recursion;
    if(o.delay_until_recursion!==undefined)f.delayUntilRecursion=!!o.delay_until_recursion;
    if(o.group!==undefined)f.group=o.group;
    if(o.group_prioritized!==undefined)f.groupOverride=!!o.group_prioritized;
    if(o.group_weight!==undefined)f.groupWeight=o.group_weight;
    ['sticky','cooldown','delay'].forEach(function(k){if(o[k]!==undefined)f[k]=o[k]||0;});
    if(o.display_index!==undefined)f.displayIndex=o.display_index;
    return f;
  }
  function readBookNamed(name){
    return call('resolveBook',{nameOrHandle:String(name)}).then(function(ref){return call('readBook',{ref:ref});});
  }
  function writeBook(snap,flats){
    var book=clone(snap.book),raws={};
    entriesOf(snap.book).forEach(function(x){raws[x.flat.uid]=x.raw;});
    if(Array.isArray(book.entries))book.entries=flats.map(function(f){return toCardEntry(raws[f.uid],f);});
    else{book.entries={};flats.forEach(function(f){book.entries[String(f.uid)]=Object.assign({},raws[f.uid]||{},f);});}
    return call('replaceBook',{ref:snap.ref,book:book,expectedVersion:snap.version});
  }
  function nextUid(flats){var n=-1;flats.forEach(function(f){if(typeof f.uid==='number'&&f.uid>n)n=f.uid;});return n+1;}
  // Entries given (new or old shape) over the book's own: matched by uid,
  // the rest new.
  function merged(snap,given,from){
    var flats=entriesOf(snap.book).map(function(x){return x.flat;}),byUid={};
    flats.forEach(function(f){byUid[f.uid]=f;});
    var uid=nextUid(flats);
    return given.map(function(h){
      var f=from(h,h.uid!=null&&byUid[h.uid]?byUid[h.uid]:null);
      if(f.uid==null||(h.uid!=null&&!byUid[h.uid]&&f.uid in byUid))f.uid=uid++;
      return f;
    });
  }
  function bookNameOf(ref){
    var d=(res.bookDirectory||{}).books||[];
    for(var i=0;i<d.length;i++){var r=d[i].ref;if(r.kind===ref.kind&&r.bookId===ref.bookId&&r.characterId===ref.characterId)return d[i].name||d[i].displayName;}
    return null;
  }
  function bookExists(name){return getWorldbookNames().indexOf(String(name))>=0;}
  function getWorldbookNames(){
    return ((res.bookDirectory||{}).books||[]).filter(function(b){return b.readable!==false;}).map(function(b){return b.name||b.displayName;});
  }
  function bindingsOf(scope,targetId){
    var l=res.bookBindings||[];
    for(var i=0;i<l.length;i++)if(l[i].scope===scope&&(scope==='global'||l[i].targetId===targetId))return l[i];
    return null;
  }
  function names(refs){return [].concat(refs||[]).map(bookNameOf).filter(function(n){return n!=null;});}
  function charTarget(name){
    if(cardId&&isCurrent(name==null?'current':name))return cardId;
    throw refused('notFound','Not this chat\'s character: '+name);
  }
  function chatTarget(name){
    var id=chatIdNow();
    if(id&&(name==null||name==='current'||name===id))return id;
    throw refused('notFound','Not this chat: '+name);
  }
  function getGlobalWorldbookNames(){var b=bindingsOf('global');return b?names(b.additional):[];}
  function getCharWorldbookNames(name){
    var b=bindingsOf('character',charTarget(name));
    return {primary:b&&b.primary?bookNameOf(b.primary):null,additional:b?names(b.additional):[]};
  }
  function getChatWorldbookName(name){var b=bindingsOf('chat',chatTarget(name));return b&&b.primary?bookNameOf(b.primary):null;}
  function refOf(name){return name==null?Promise.resolve(null):call('resolveBook',{nameOrHandle:String(name)});}
  // A binding changed: read for its version, the names resolved, written.
  function rebind(scope,targetId,edit){
    return call('readBookBindings',{target:{scope:scope,targetId:targetId}}).then(function(cur){
      var want=edit(cur);
      return Promise.all([want.primary===undefined?Promise.resolve(cur.primary):refOf(want.primary)]
        .concat(want.additional===undefined?cur.additional.map(function(r){return Promise.resolve(r);}):want.additional.map(refOf)))
        .then(function(refs){
          return call('updateBookBindings',{expectedVersion:cur.version,
            edit:{scope:scope,targetId:targetId,primary:refs[0],additional:refs.slice(1).filter(Boolean)}});
        });
    }).then(function(){});
  }
  function rebindGlobalWorldbooks(list){return attempt(function(){return rebind('global',null,function(){return {primary:null,additional:[].concat(list||[])};});});}
  function rebindCharWorldbooks(name,b){return attempt(function(){
    b=b||{};return rebind('character',charTarget(name),function(){return {primary:b.primary,additional:b.additional==null?undefined:[].concat(b.additional)};});
  });}
  function rebindChatWorldbook(name,book){return attempt(function(){return rebind('chat',chatTarget(name),function(){return {primary:book==null?null:book};});});}
  function getWorldbook(name){return attempt(function(){
    return readBookNamed(name).then(function(s){return entriesOf(s.book).map(function(x){return toHelperEntry(x.flat);});});
  });}
  function replaceWorldbook(name,entries){return attempt(function(){
    return readBookNamed(name).then(function(s){return writeBook(s,merged(s,[].concat(entries||[]),fromHelperEntry));}).then(function(){});
  });}
  // Written with the version it was read at: changed meanwhile, refused.
  function updateWorldbookWith(name,updater){return attempt(function(){
    return readBookNamed(name).then(function(s){
      var now=entriesOf(s.book).map(function(x){return toHelperEntry(x.flat);});
      return Promise.resolve(updater(now)).then(function(n){
        return writeBook(s,merged(s,[].concat(n===undefined?now:n),fromHelperEntry));
      }).then(function(w){return entriesOf(w.book).map(function(x){return toHelperEntry(x.flat);});});
    });
  });}
  function createWorldbookEntries(name,fresh){return attempt(function(){
    return readBookNamed(name).then(function(s){
      var flats=entriesOf(s.book).map(function(x){return x.flat;}),uid=nextUid(flats);
      var added=[].concat(fresh||[]).map(function(h){var f=fromHelperEntry(Object.assign({},h,{uid:undefined}),null);f.uid=uid++;return f;});
      return writeBook(s,flats.concat(added)).then(function(){
        return {worldbook:flats.concat(added).map(toHelperEntry),new_entries:added.map(toHelperEntry)};
      });
    });
  });}
  function deleteWorldbookEntries(name,predicate){return attempt(function(){
    return readBookNamed(name).then(function(s){
      var flats=entriesOf(s.book).map(function(x){return x.flat;}),kept=[],gone=[];
      flats.forEach(function(f){(predicate(toHelperEntry(f))?gone:kept).push(f);});
      return writeBook(s,kept).then(function(){return {worldbook:kept.map(toHelperEntry),deleted_entries:gone.map(toHelperEntry)};});
    });
  });}
  function rawBook(entries,from){
    var book={entries:{}},uid=0;
    [].concat(entries||[]).forEach(function(h){var f=from(Object.assign({},h,{uid:undefined}),null);f.uid=uid++;book.entries[String(f.uid)]=f;});
    return book;
  }
  function createWorldbook(name,entries){return attempt(function(){
    if(bookExists(name))return Promise.resolve(false);
    return call('createBook',{name:String(name),raw:rawBook(entries,fromHelperEntry)}).then(function(){return true;});
  });}
  function createOrReplaceWorldbook(name,entries){return attempt(function(){
    return bookExists(name)?replaceWorldbook(name,entries||[]).then(function(){return false;}):createWorldbook(name,entries);
  });}
  function deleteWorldbook(name){return attempt(function(){
    if(!bookExists(name))return Promise.resolve(false);
    return readBookNamed(name).then(function(s){return call('deleteBook',{ref:s.ref,expectedVersion:s.version});}).then(function(){return true;});
  });}
  function getOrCreateChatWorldbook(chat,name){return attempt(function(){
    var id=chatTarget(chat),now=getChatWorldbookName(id);
    if(now)return Promise.resolve(now);
    var book=name==null?'Chat Book '+id:String(name);
    return (bookExists(book)?Promise.resolve():call('createBook',{name:book,raw:{entries:{}}}))
      .then(function(){return rebindChatWorldbook(id,book);}).then(function(){return book;});
  });}
  function getLorebookSettings(){return clone((res.worldInfoSettings||{}).value||{});}
  // selected_global_lorebooks are which books are on globally: a binding.
  function setLorebookSettings(patch){return attempt(function(){
    var p=Object.assign({},patch||{}),g=p.selected_global_lorebooks,steps=[];
    delete p.selected_global_lorebooks;
    if(Object.keys(p).length)steps.push(call('updateWorldInfoSettings',{patch:p,expectedVersion:(res.worldInfoSettings||{}).version||null}));
    if(g!==undefined)steps.push(rebindGlobalWorldbooks([].concat(g||[])));
    return Promise.all(steps).then(function(){});
  });}
  [['getWorldbookNames',getWorldbookNames],['getGlobalWorldbookNames',getGlobalWorldbookNames],
   ['getCharWorldbookNames',getCharWorldbookNames],['getChatWorldbookName',getChatWorldbookName],
   ['getLorebookSettings',getLorebookSettings],
   ['rebindGlobalWorldbooks',watched(rebindGlobalWorldbooks)],['rebindCharWorldbooks',watched(rebindCharWorldbooks)],
   ['rebindChatWorldbook',watched(rebindChatWorldbook)],['getWorldbook',watched(getWorldbook)],
   ['replaceWorldbook',watched(replaceWorldbook)],['updateWorldbookWith',watched(updateWorldbookWith)],
   ['createWorldbookEntries',watched(createWorldbookEntries)],['deleteWorldbookEntries',watched(deleteWorldbookEntries)],
   ['createWorldbook',watched(createWorldbook)],['createOrReplaceWorldbook',watched(createOrReplaceWorldbook)],
   ['deleteWorldbook',watched(deleteWorldbook)],['getOrCreateChatWorldbook',watched(getOrCreateChatWorldbook)],
   ['setLorebookSettings',watched(setLorebookSettings)]].forEach(function(f){share(f[0],f[1]);});
  // The older names.
  function getCharLorebooks(o){var b=getCharWorldbookNames(o&&o.name);return {primary:b.primary,additional:b.additional};}
  function getLorebookEntries(name){return attempt(function(){
    return readBookNamed(name).then(function(s){return entriesOf(s.book).map(function(x){return toOldEntry(x.flat);});});
  });}
  function setLorebookEntries(name,entries){return attempt(function(){
    return readBookNamed(name).then(function(s){
      var flats=entriesOf(s.book).map(function(x){return x.flat;}),byUid={};
      flats.forEach(function(f,i){byUid[f.uid]=i;});
      [].concat(entries||[]).forEach(function(o){if(o.uid in byUid)flats[byUid[o.uid]]=fromOldEntry(o,flats[byUid[o.uid]]);});
      return writeBook(s,flats);
    }).then(function(){});
  });}
  function createLorebookEntries(name,fresh){return attempt(function(){
    return readBookNamed(name).then(function(s){
      var flats=entriesOf(s.book).map(function(x){return x.flat;}),uid=nextUid(flats),ids=[];
      var added=[].concat(fresh||[]).map(function(o){var f=fromOldEntry(Object.assign({},o,{uid:undefined}),null);f.uid=uid++;ids.push(f.uid);return f;});
      return writeBook(s,flats.concat(added)).then(function(){return ids;});
    });
  });}
  function deleteLorebookEntries(name,uids){return attempt(function(){
    var gone=[].concat(uids||[]);
    return readBookNamed(name).then(function(s){
      return writeBook(s,entriesOf(s.book).map(function(x){return x.flat;}).filter(function(f){return gone.indexOf(f.uid)<0;}));
    }).then(function(){});
  });}
  [['getLorebooks',getWorldbookNames],['getCharLorebooks',getCharLorebooks],
   ['getCurrentCharPrimaryLorebook',function(){return getCharWorldbookNames('current').primary;}],
   ['getChatLorebook',function(){return getChatWorldbookName('current');}],
   ['setChatLorebook',watched(function(name){return rebindChatWorldbook('current',name);})],
   ['getOrCreateChatLorebook',watched(function(name){return getOrCreateChatWorldbook('current',name);})],
   ['getLorebookEntries',watched(getLorebookEntries)],['setLorebookEntries',watched(setLorebookEntries)],
   ['createLorebookEntries',watched(createLorebookEntries)],['deleteLorebookEntries',watched(deleteLorebookEntries)],
   ['createLorebook',watched(function(name){return createWorldbook(name,[]);})],['deleteLorebook',watched(deleteWorldbook)]]
    .forEach(function(f){share(f[0],f[1]);});

  // Presets (酒馆助手's 预设 pages): 'in_use' is the chat's preset as it is
  // being used (written, it stays so until the chat is opened afresh); by
  // name, the one kept in the library. In 酒馆助手's shape — settings,
  // prompts in order, the prompts not in use, extensions — made from the
  // ST preset and written back over it, what it does not show kept.
  var SETTINGS={max_context:'openai_max_context',max_completion_tokens:'openai_max_tokens',reply_count:'n',
    should_stream:'stream_openai',temperature:'temperature',frequency_penalty:'frequency_penalty',
    presence_penalty:'presence_penalty',repetition_penalty:'repetition_penalty',min_p:'min_p',top_a:'top_a',top_k:'top_k',
    top_p:'top_p',seed:'seed',squash_system_messages:'squash_system_messages',reasoning_effort:'reasoning_effort',
    request_thoughts:'show_thoughts',request_images:'request_images',enable_function_calling:'function_calling',
    enable_web_search:'enable_web_search',allow_sending_images:'image_inlining',wrap_user_messages_in_quotes:'wrap_in_quotes'};
  function promptOrder(raw){
    var po=raw.prompt_order||[],pick=null;
    po.forEach(function(x){if(x&&x.character_id===100001)pick=x;});
    return pick||po[po.length-1]||null;
  }
  function helperPrompt(p,enabled){
    var out={id:p.identifier,name:p.name||p.identifier,enabled:enabled!==false,role:p.role||'system',
      position:p.injection_position===1?{type:'in_chat',depth:p.injection_depth==null?4:p.injection_depth,
        order:p.injection_order==null?100:p.injection_order}:{type:'relative'}};
    if(!p.marker)out.content=p.content||'';
    return out;
  }
  function helperPreset(raw){
    var settings={};for(var k in SETTINGS)if(raw[SETTINGS[k]]!==undefined)settings[k]=clone(raw[SETTINGS[k]]);
    var byId={},used={},prompts=[],order=promptOrder(raw);
    (raw.prompts||[]).forEach(function(p){if(p&&p.identifier)byId[p.identifier]=p;});
    ((order&&order.order)||[]).forEach(function(o){var p=byId[o.identifier];if(p&&!used[o.identifier]){used[o.identifier]=true;prompts.push(helperPrompt(p,o.enabled));}});
    var unused=(raw.prompts||[]).filter(function(p){return p&&!used[p.identifier];}).map(function(p){return helperPrompt(p,false);});
    return {settings:settings,prompts:prompts,prompts_unused:unused,extensions:clone(raw.extensions||{})};
  }
  // The prompts are written back only when they changed: a preset that
  // keeps ST's default order (no prompt_order) keeps it through a change of
  // its settings.
  function samePrompts(raw,h){
    var was=helperPreset(raw);
    return JSON.stringify([was.prompts,was.prompts_unused])===JSON.stringify([h.prompts,h.prompts_unused||[]]);
  }
  function rawPreset(raw,h){
    var out=clone(raw);
    for(var k in h.settings||{})if(SETTINGS[k])out[SETTINGS[k]]=clone(h.settings[k]);
    if(h.prompts&&!samePrompts(raw,h)){
      var byId={};(out.prompts||[]).forEach(function(p){if(p&&p.identifier)byId[p.identifier]=p;});
      out.prompts=[].concat(h.prompts,h.prompts_unused||[]).map(function(x){
        var p=Object.assign({},byId[x.id]||{identifier:x.id,system_prompt:false,marker:false}),pos=x.position||{};
        if(x.name!==undefined)p.name=x.name;
        if(x.role)p.role=x.role;
        if(x.content!==undefined)p.content=x.content;
        p.injection_position=pos.type==='in_chat'?1:0;
        if(pos.type==='in_chat'){p.injection_depth=pos.depth;p.injection_order=pos.order;}
        return p;
      });
      var list=h.prompts.map(function(x){return {identifier:x.id,enabled:x.enabled!==false};}),order=promptOrder(out);
      if(order)order.order=list;else out.prompt_order=[{character_id:100001,order:list}];
    }
    if(h.extensions&&JSON.stringify(h.extensions)!==JSON.stringify(raw.extensions||{}))out.extensions=clone(h.extensions);
    return out;
  }
  function presetId(name){
    var l=(res.presetLibrary||{}).presets||[];
    for(var i=0;i<l.length;i++)if(l[i].name===name)return l[i].id;
    for(var j=0;j<l.length;j++)if(l[j].id===name)return l[j].id;
    return null;
  }
  function inUse(name){return name==null||name==='in_use';}
  function preloadPresets(){
    if(presetsLoading)return presetsLoading;
    var token=(res.presetLibrary||{}).version;
    presetsLoading=Promise.all(((res.presetLibrary||{}).presets||[]).map(function(p){
      return call('readPreset',{ref:{kind:'stored',presetId:p.id}}).then(function(s){return s;},function(){return null;});
    })).then(function(list){
      presetsLoading=null;
      if((res.presetLibrary||{}).version!==token)return;
      list.forEach(function(s){if(s)storedPresets[s.ref.presetId]=s;});
    });
    return presetsLoading;
  }
  function presetNow(name){
    if(inUse(name)){if(!res.preset)throw refused('noContext','The preset in use is not read yet');return res.preset;}
    var id=presetId(name);
    if(!id)throw refused('notFound','No such preset: '+name);
    if(!storedPresets[id]){preloadPresets();throw refused('busy','The preset '+name+' is still being read; try once more');}
    return storedPresets[id];
  }
  function presetRead(name){
    if(inUse(name))return Promise.resolve(presetNow(name));
    var id=presetId(name);
    if(!id)return Promise.reject(refused('notFound','No such preset: '+name));
    return call('readPreset',{ref:{kind:'stored',presetId:id}});
  }
  function getPresetNames(){return ((res.presetLibrary||{}).presets||[]).map(function(p){return p.name;});}
  function getLoadedPresetName(){
    var id=((res.preset||{}).source||{}).loadedPresetId,l=(res.presetLibrary||{}).presets||[];
    for(var i=0;i<l.length;i++)if(l[i].id===id)return l[i].name;
    return 'in_use';
  }
  function getPreset(name){return helperPreset(presetNow(name).raw);}
  // Written with the version it was read at: changed meanwhile, refused.
  function writePreset(s,preset){
    return call('replacePreset',{ref:s.ref,raw:rawPreset(s.raw,preset||{}),expectedVersion:s.version}).then(function(r){
      if(r.ref.kind==='stored')storedPresets[r.ref.presetId]=r;else res.preset=r;
    });
  }
  function replacePreset(name,preset){return attempt(function(){
    return presetRead(name).then(function(s){return writePreset(s,preset);});
  });}
  function updatePresetWith(name,updater){return attempt(function(){
    return presetRead(name).then(function(s){
      var now=helperPreset(s.raw);
      return Promise.resolve(updater(now)).then(function(n){n=n===undefined?now:n;return writePreset(s,n).then(function(){return n;});});
    });
  });}
  function setPreset(name,partial){return updatePresetWith(name,function(p){
    partial=partial||{};
    if(partial.settings)Object.assign(p.settings,partial.settings);
    ['prompts','prompts_unused','extensions'].forEach(function(k){if(partial[k]!==undefined)p[k]=partial[k];});
    return p;
  });}
  [['getPresetNames',getPresetNames],['getLoadedPresetName',getLoadedPresetName],['getPreset',getPreset],
   ['replacePreset',watched(replacePreset)],['updatePresetWith',watched(updatePresetWith)],['setPreset',watched(setPreset)]]
    .forEach(function(f){share(f[0],f[1]);});

  // The chat's character written (酒馆助手's replaceCharacter /
  // updateCharacterWith): its card first, then a picture given as a Blob.
  // Those are two writes; the card kept and the picture not is said so.
  function base64Of(blob){
    return new Promise(function(ok,no){
      var r=new FileReader();r.onload=function(){ok(String(r.result).split(',')[1]||'');};r.onerror=function(){no(r.error);};
      r.readAsDataURL(blob);
    });
  }
  function replaceCharacter(name,c,o){return attempt(function(){
    if(!isCurrent(name===undefined?'current':name))throw refused('notFound','No such character here: '+name);
    c=c||{};
    var cd=res.characterData||{},data=clone(cd.data||card||{});
    if(c.version!==undefined)data.character_version=c.version;
    ['creator','creator_notes','description'].forEach(function(k){if(c[k]!==undefined)data[k]=c[k];});
    if(c.first_messages){data.first_mes=c.first_messages[0]||'';data.alternate_greetings=c.first_messages.slice(1);}
    if(c.extensions)data.extensions=clone(c.extensions);
    if(c.worldbook!==undefined){data.extensions=data.extensions||{};data.extensions.world=c.worldbook||'';}
    var first=call('replaceCharacterData',{characterId:cardId,data:data,expectedVersion:cd.version||null});
    if(typeof Blob==='undefined'||!(c.avatar instanceof Blob))return first.then(function(){});
    return first.then(function(){
      return Promise.all([base64Of(c.avatar),call('readCharacterAvatar',{characterId:cardId})]).then(function(x){
        return call('replaceCharacterAvatar',{characterId:cardId,bytes:x[0],expectedVersion:x[1].version});
      }).then(function(){},function(e){
        var w=new Error('The card was saved; its picture was not: '+String(e&&e.message||e));
        w.code=e&&e.code||'storage';w.committed=true;w.cause=e;throw w;
      });
    });
  });}
  function updateCharacterWith(name,updater){return attempt(function(){
    return getCharacter(name).then(function(c){
      return Promise.resolve(updater(c)).then(function(n){n=n===undefined?c:n;return replaceCharacter(name,n).then(function(){return n;});});
    });
  });}
  share('replaceCharacter',watched(replaceCharacter));share('updateCharacterWith',watched(updateCharacterWith));
''';

/// The engine's MVU issues ({code, message, …}) as a notice's words, one a
/// line, each said once: an update that did not finish as [unfinished] (its
/// reply is kept), any other as the engine words it.
String tavernMvuIssueText(List<Object?> issues, {required String unfinished}) => {
  for (final issue in issues)
    if (issue is Map)
      switch (issue['code']) {
        'mvu_base_unavailable' || 'mvu_update_failed' => unfinished,
        final code => '${issue['message'] ?? code}',
      },
}.join('\n');
