// SillyTavern's own page, as far as preset and card scripts reach for it to
// show themselves (a preset's 酒馆助手 script that builds its own menu, for
// one): the pieces of ST's context this page truly has, and ST's places for a
// script's buttons. A piece of the canvas page's script (tavern_canvas.dart),
// spliced in after tavernCanvasHelpersJs, using what both define (res, call,
// fire, events, toastr, post, getLoadedPresetName…).

/// A host button's key in the composer's row of script buttons: this, then
/// the id the page gave it.
const tavernHostButtonPrefix = 'host:';

/// The page's script for these.
const tavernCanvasHostJs = r'''
  // ST's context, as ST's extensions use it: eventSource (this page's
  // events) and eventTypes, the events this page sends — the engine's, and
  // SETTINGS_UPDATED / OAI_PRESET_CHANGED_AFTER when the preset in use comes
  // back changed or another; chatCompletionSettings, that preset in ST's
  // shape (its oai_settings): one copy, so what a script changes in it reads
  // back, taken afresh once the preset changes and nothing is being saved;
  // saveSettingsDebounced, which writes what changed in it into the dsh
  // preset (the library's one the chat uses, or the chat's own).
  events.SETTINGS_UPDATED='SETTINGS_UPDATED';events.OAI_PRESET_CHANGED_AFTER='OAI_PRESET_CHANGED_AFTER';
  SillyTavern.eventSource={on:eventOn,once:eventOnce,removeListener:eventRemoveListener,off:eventRemoveListener,
    emit:eventEmit,makeFirst:eventMakeFirst,makeLast:eventMakeLast};
  SillyTavern.eventTypes=SillyTavern.event_types=events;
  SillyTavern.mainApi='openai';
  // stCopyOf: which preset the copy is (presetIdentity); another chosen, the
  // copy is that one's at once, an edit of the last one going on or not.
  var stCopy=null,stBase=null,stOf=null,stCopyOf=null,stTimer=0,stBusy=0;
  Object.defineProperty(SillyTavern,'chatCompletionSettings',{enumerable:true,get:function(){
    var p=res.preset;if(!p)return undefined;
    var of=presetIdentity(p);
    if(of!==stCopyOf||!stBusy&&stOf!==p.version){
      stOf=p.version;stCopyOf=of;stBase=p.raw;stCopy=clone(p.raw);stCopy.preset_settings_openai=getLoadedPresetName();
    }
    return stCopy;
  }});
  function presetDelivered(was,now){
    if(!was||!now||was.version===now.version)return;
    if((was.source||{}).loadedPresetId!==(now.source||{}).loadedPresetId){
      // Another preset: the last one's SPreset functions and tools go.
      if(window.DshSPresetPageRuntime)DshSPresetPageRuntime.resetPreset();
      fire('OAI_PRESET_CHANGED_AFTER',[]);
    }
    fire('SETTINGS_UPDATED',[]);
  }
  // Which preset an edit is of: the one its copy is.
  function presetIdentity(p){var s=(p&&p.source)||{};return JSON.stringify([p&&p.ref,s.loadedPresetId||null]);}
  // One write at a time: an edit due while one is out waits for it, then is
  // compared with what that wrote (stAgain; a later one joins it).
  var stTarget=null,stSaving=false,stAgain=false;
  function saveSettingsDebounced(){
    if(!stTimer){stBusy++;stTarget=stCopyOf;}
    clearTimeout(stTimer);stTimer=setTimeout(saveSettings,300);
  }
  // Not kept (refused, or another preset chosen meanwhile): the preset as it
  // is, read again by whoever listens, once nothing is being saved.
  function dropEdit(){stBusy--;stOf=null;fire('SETTINGS_UPDATED',[]);}
  function saveSettings(){
    stTimer=0;
    if(stSaving){if(stAgain)stBusy--;stAgain=true;return;}
    var target=stTarget;stTarget=null;
    if(presetIdentity(res.preset)!==target||stCopyOf!==target){dropEdit();return;}
    var changed={},n=0;
    for(var k in stCopy||{})if(k!=='preset_settings_openai'&&JSON.stringify(stCopy[k])!==JSON.stringify(stBase[k])){changed[k]=clone(stCopy[k]);n++;}
    if(!n){stBusy--;return;}
    // The library's preset the chat uses, unless a working copy of it is what
    // generation reads: then that.
    var src=res.preset.source||{},id=src.loadedPresetId;
    stSaving=true;
    (id&&!src.working?call('readPreset',{ref:{kind:'stored',presetId:id}}):Promise.resolve(res.preset)).then(function(s){
      return call('replacePreset',{ref:s.ref,raw:Object.assign(clone(s.raw),changed),expectedVersion:s.version});
    }).then(function(r){
      if(stCopyOf===target)stBase=Object.assign({},stBase,changed);
      if(r.ref.kind==='current'&&presetIdentity(res.preset)===target)res.preset=r;
      stSaving=false;stBusy--;
      saveQueued();
    },function(e){
      stSaving=false;
      // An edit of another preset, waiting or queued, goes on as it was.
      if(stTarget!==null&&stTarget!==target){stBusy--;saveQueued();}
      else{
        // One of this preset goes too: the preset is read again as it is.
        if(stAgain){stAgain=false;stBusy--;}
        if(stTimer){clearTimeout(stTimer);stTimer=0;stBusy--;}
        stTarget=null;
        dropEdit();
      }
      toastr.error(String(e&&e.message||e));
    });
  }
  // The edit that came due while a write was out, now (or with the next
  // one still waiting, then).
  function saveQueued(){if(stAgain){stAgain=false;if(stTimer)stBusy--;else saveSettings();}}
  SillyTavern.saveSettingsDebounced=saveSettingsDebounced;

  // ST's places for a script's buttons and menu items, out of sight here:
  // #send_form with its #qr--bar (.qr--buttons), and #extensionsMenu. What a
  // script puts there the app shows over the composer, each by its words; a
  // press there clicks it here. A panel the script opens then is its own,
  // over this page. Made when the first script runs.
  var stHost=null,pressSeq=0,pressSent='[]';
  var pressable='button,[role=button],.menu_button,.qr--button,.list-group-item,[onclick]';
  function hostAnchors(){
    if(stHost)return;
    stHost=document.createElement('div');stHost.id='dsh-st-host';stHost.style.setProperty('display','none','important');
    stHost.innerHTML='<div id="send_form"><div id="qr--bar"><div class="qr--buttons"></div></div></div><div id="extensionsMenu"></div>';
    document.body.appendChild(stHost);
    new MutationObserver(tellPressable).observe(stHost,{childList:true,subtree:true,characterData:true});
  }
  function tellPressable(){
    var list=[];
    [].forEach.call(stHost.querySelectorAll(pressable),function(el){
      if(el.parentElement.closest(pressable))return;
      var label=(el.textContent||'').replace(/\s+/g,' ').trim()||el.title||el.getAttribute('aria-label')||'';
      if(!label)return;
      if(!el.dataset.dshPress)el.dataset.dshPress=String(++pressSeq);
      list.push({id:el.dataset.dshPress,label:label});
    });
    var json=JSON.stringify(list);if(json===pressSent)return;pressSent=json;
    post({type:'hostButtons',buttons:list});
  }
  function press(id){var el=stHost&&stHost.querySelector('[data-dsh-press="'+id+'"]');if(el)el.click();}
''';
