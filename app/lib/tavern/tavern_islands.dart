// 岛屿 (docs/design/roleplay-roadmap.md §1, level 1): a message that carries
// HTML — an ```html block, or raw <style>, <div>, <table>… — shows that part
// in a sandboxed web view of its own, as tall as its content; the rest of the
// message stays native Markdown. Cards' status bars and styled panels live
// here. Whole-page canvases (level 2) are another matter. Component tags
// (<dsh-letter>…, tavern_components.dart) outside an HTML block are parts of
// their own, drawn natively.

import 'dart:convert';
import 'dart:ui' show Color;

import 'tavern_components.dart';

/// Where islands and 整页画布 are loaded from: their pages' origin, so a card's
/// localStorage works (a page with no base URL has the origin "null", which
/// has none) and is the tavern's own. `.invalid` never resolves: nothing a
/// relative URL names is fetched from anywhere.
const tavernFrameBaseUrl = 'https://tavern.dshgo.invalid/';

/// One part of a message.
sealed class TavernPart {
  const TavernPart();
}

/// Markdown, drawn natively.
final class TavernTextPart extends TavernPart {
  const TavernTextPart(this.markdown);
  final String markdown;
}

/// HTML, for an island.
final class TavernIslandPart extends TavernPart {
  const TavernIslandPart(this.html);
  final String html;
}

/// A component (`<dsh-letter>`…), drawn natively.
final class TavernComponentPart extends TavernPart {
  const TavernComponentPart(this.component);
  final TavernComponent component;
}

/// Whether an island's [html] may use the bundled library [name]: jQuery and
/// lodash always (small, and used bare); zod and YAML when the page names
/// them, imports a module (an MVU bundle reaches for them) or uses MVU.
bool tavernIslandNeeds(String name, String html) => switch (name) {
  'zod' => _wantsZod.hasMatch(html),
  'YAML' => _wantsYaml.hasMatch(html),
  _ => true,
};
final _wantsZod = RegExp(r'\bz\s*\.|\bimport\b|\bMvu\b|waitGlobalInitialized');
final _wantsYaml = RegExp(r'\bYAML\b|\bimport\b|\bMvu\b|waitGlobalInitialized');

/// A page's colours as CSS variables (`--dsh-<name>`), and the scheme its form
/// controls take: light text, a dark page; so a control a card styled without
/// a text colour (ST gives it the body's) is not black. Set again in place on a
/// theme change ([tavernPageColorsJs]): reloading the page would run a card's
/// scripts, and what they write, once more.
Map<String, String> tavernPageColors(Map<String, Color> colors) => {
  for (final MapEntry(:key, :value) in colors.entries)
    '--dsh-$key':
        'rgba(${(value.r * 255).round()},${(value.g * 255).round()},${(value.b * 255).round()},${value.a.toStringAsFixed(3)})',
  '--dsh-scheme': (colors['text']?.computeLuminance() ?? 0) > 0.5 ? 'dark' : 'light',
};

/// JavaScript that sets [colors] ([tavernPageColors]) on a loaded page.
String tavernPageColorsJs(Map<String, Color> colors) =>
    '(function(s){${tavernPageColors(colors).entries.map((e) => 's.setProperty(${jsonEncode(e.key)},${jsonEncode(e.value)});').join()}})(document.documentElement.style)';

/// A fenced code block (up to three spaces in, as Markdown allows): its
/// fence, its info string, its body. As CommonMark has it, the whole opening
/// run is the fence, and it closes on a run of the same mark at least as long.
final tavernFence = RegExp(
  r'^[ ]{0,3}(`{3,}(?!`)|~{3,}(?!~))([^\n`]*)\n([\s\S]*?)\n?^[ ]{0,3}\1(?:(?<=`)`*|(?<=~)~*)[ \t]*$',
  multiLine: true,
);

/// Whether a code block with [info] (its info string) and [body] is a page
/// to show rather than code: an ```html block, or — whatever its language,
/// or none — a whole page, as 酒馆助手 renders any code block whose text has
/// `html>`, `<head>` or `<body` in it.
bool tavernFenceIsHtml(String info, String body) =>
    info.trim().toLowerCase().startsWith(RegExp(r'html\b')) || tavernIsFrontend(body);

/// 酒馆助手's test for a front end (its isFrontend).
bool tavernIsFrontend(String code) => code.contains('html>') || code.contains('<head>') || code.contains('<body');

/// Elements whose text a blank line does not end: style and script (their
/// CSS and code), pre and textarea (their text as written), and comments.
final _rawBound = RegExp(
  r'<(style|script|pre|textarea)\b[^>]*>|</(style|script|pre|textarea)\s*>|<!--|-->',
  caseSensitive: false,
);

/// [text]'s blocks, as blank lines part them; never inside a style, script,
/// pre, textarea or comment, whose blank lines are its own.
List<String> tavernHtmlBlocks(String text) {
  final blocks = <String>[];
  String? open;
  var at = 0;
  // The blank line kept as written, its spaces too, where it is the block's own.
  String? gap;
  void each(String block) {
    if (open != null) {
      blocks.last = '${blocks.last}$gap$block';
    } else {
      blocks.add(block);
    }
    for (final m in _rawBound.allMatches(block)) {
      final tag = m[0]!;
      if (open == null) {
        if (tag == '<!--') {
          open = '-->';
        } else if (m[1] != null) {
          open = m[1]!.toLowerCase();
        }
      } else if (open == '-->' ? tag == '-->' : m[2]?.toLowerCase() == open) {
        open = null;
      }
    }
  }

  for (final blank in RegExp(r'\n[ \t]*\n').allMatches(text)) {
    each(text.substring(at, blank.start));
    gap = blank[0];
    at = blank.end;
  }
  each(text.substring(at));
  return blocks;
}

final _blockHtml = RegExp(
  r'<(style|script|div|table|details|svg|section|article|center|iframe|canvas|form|button)\b',
  caseSensitive: false,
);

/// Text that is only a little punctuation: what follows a component in the
/// same sentence (「…`</dsh-item>`。」) goes back onto the text before it.
final _trailing = RegExp(r'^[\s\p{P}]{1,3}$', unicode: true);

/// [text] cut into parts: each component tag outside an HTML block a part of
/// its own; with [islands], each ```html block (or code block holding a
/// whole page, [tavernFenceIsHtml]) an island and text around them that
/// carries block HTML an island too (as SillyTavern would show it); the rest
/// Markdown. One text part, [text] as it is, when there is nothing else.
List<TavernPart> tavernParts(String text, {bool islands = true}) {
  final source = text.replaceAll('\r\n', '\n');
  final parts = <TavernPart>[];
  void prose(String segment) {
    if (segment.trim().isEmpty) return;
    // 「她递给你<dsh-item …>…</dsh-item>。」: the 。 ends 她递给你, not a
    // paragraph of its own under the card.
    if (_trailing.hasMatch(segment) && parts.length >= 2 && parts.last is TavernComponentPart) {
      if (parts[parts.length - 2] case TavernTextPart(:final markdown)) {
        parts[parts.length - 2] = TavernTextPart(markdown + segment.trim());
        return;
      }
    }
    parts.add(
      // HTML in a code block is code, not a reason for a page.
      islands && _blockHtml.hasMatch(segment.replaceAll(tavernFence, ''))
          ? TavernIslandPart(_htmlOf(segment))
          : TavernTextPart(segment.trim()),
    );
  }

  void outside(String segment) {
    for (final piece in tavernSplitComponents(segment)) {
      switch (piece) {
        case TavernComponent component:
          parts.add(TavernComponentPart(component));
        case String words:
          prose(words);
      }
    }
  }

  var at = 0;
  if (islands) {
    for (final fence in tavernFence.allMatches(source)) {
      final html = fence[3]!;
      // Other code stays in the text, Markdown's to draw.
      if (!tavernFenceIsHtml(fence[2]!, html)) continue;
      outside(source.substring(at, fence.start));
      if (html.trim().isNotEmpty) parts.add(TavernIslandPart(html));
      at = fence.end;
    }
  }
  outside(source.substring(at));
  if (parts.every((p) => p is TavernTextPart)) return [TavernTextPart(text)];
  return parts;
}

/// Text with HTML in it, as a page: HTML blocks as they are, code blocks as
/// code, each other paragraph a <p> with its line breaks and *actions* in
/// italics.
String _htmlOf(String segment) {
  final out = <String>[];
  void blocks(String text) {
    for (final block in tavernHtmlBlocks(text.trim())) {
      if (block.trim().isEmpty) continue;
      out.add(
        block.trimLeft().startsWith('<')
            ? block
            : '<p>${block.trim().replaceAllMapped(RegExp(r'\*([^*\n]+)\*'), (m) => '<em>${m[1]}</em>').replaceAll('\n', '<br>')}</p>',
      );
    }
  }

  var at = 0;
  for (final fence in tavernFence.allMatches(segment)) {
    blocks(segment.substring(at, fence.start));
    final code = fence[3]!.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    out.add('<pre><code>$code</code></pre>');
    at = fence.end;
  }
  blocks(segment.substring(at));
  return out.join('\n');
}

/// Whether [html]'s scripts read the story or use 酒馆助手's interfaces (a
/// status bar drawing its floor's variables, a notice by toastr): then its
/// island is told the story and given them (tavern_island_story.dart).
bool tavernIslandReadsStory(String html) => _readsStory.hasMatch(html);

final _readsStory = RegExp(
  r'(<script\b|\son[a-z]+\s*=)[\s\S]*\b(getVariables|getAllVariables|Mvu|getChatMessages|getCurrentMessageId|'
  r'getLastMessageId|waitGlobalInitialized|initializeGlobal|SillyTavern|getContext|toastr|eventOn|eventOnce)\b',
  caseSensitive: false,
);

/// Whether [html] carries a script of its own, or an inline handler.
bool tavernIslandHasScript(String html) => _script.hasMatch(html);

final _script = RegExp(r'<script\b|\son[a-z]+\s*=', caseSensitive: false);

/// The page an island loads: [html] in the story's colours and size on a
/// see-through ground, and a small script of ours (allowed by [nonce]) that
/// reports the content's height to the `TavernIsland` channel. [noScripts]
/// keeps the card's own scripts from running; [offline] keeps the page from
/// loading anything off the network (only what is inline or data:).
/// [libraries] (jQuery, lodash, zod, YAML) come first, for its scripts; [story] is
/// what they may read of the story (TavernIslandStory.forMessage): read
/// only, as 酒馆助手's and MVU's getters give it. Neither when scripts do not
/// run.
String tavernIslandDocument(
  String html, {
  required Color text,
  required Color accent,
  required double fontSize,
  required String nonce,
  bool noScripts = false,
  bool offline = false,
  List<String> libraries = const [],
  Map<String, Object?>? story,
}) {
  final preload = noScripts
      ? ''
      : [
          for (final code in libraries) '<script nonce="$nonce">${code.replaceAll('</script', r'<\/script')}</script>',
          if (story != null)
            '<script nonce="$nonce">var dshStory=${jsonEncode(story).replaceAll('<', r'\u003c')};$_storyJs</script>',
        ].join('\n');
  final policy = noScripts || offline
      ? [
          if (offline) "default-src 'none'",
          if (offline) 'img-src data: blob:',
          if (offline) 'media-src data: blob:',
          if (offline) 'font-src data:',
          if (offline) "style-src 'unsafe-inline' data:",
          // With scripts on, no nonce: next to one, 'unsafe-inline' counts for
          // nothing and a card's own scripts and handlers would be refused.
          if (noScripts) "script-src 'nonce-$nonce'" else "script-src 'unsafe-inline' 'unsafe-eval'",
          if (noScripts) "script-src-attr 'none'",
        ].join('; ')
      : null;
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
${policy == null ? '' : '<meta http-equiv="Content-Security-Policy" content="$policy">'}
<style>
:root{${tavernPageColors({'text': text, 'accent': accent}).entries.map((e) => '${e.key}:${e.value};').join()}}
html,body{margin:0;padding:0;background:transparent;}
#dsh-island{display:flow-root;}
body{color:var(--dsh-text);font:${fontSize}px/1.5 system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;overflow-wrap:anywhere;}
a{color:var(--dsh-accent);}
button,input,select,textarea{color-scheme:var(--dsh-scheme);}
img,video,svg{max-width:100%;height:auto;}
p{margin:0 0 .6em;}
</style></head>
<body>$preload<div id="dsh-island">
$html
</div>
<script nonce="$nonce">
(function(){
  var last=0;
  function report(){
    var h=Math.ceil(document.getElementById('dsh-island').getBoundingClientRect().height);
    if(h!==last&&window.TavernIsland){last=h;TavernIsland.postMessage(String(h));}
  }
  if(window.ResizeObserver){new ResizeObserver(report).observe(document.getElementById('dsh-island'));}
  window.addEventListener('load',report);
  document.addEventListener('toggle',report,true);
  setTimeout(report,0);setTimeout(report,300);setTimeout(report,1200);
})();
</script></body></html>''';
}

/// An island's helpers over dshStory, as 酒馆助手's pages have them: its
/// getters (variables, floors, SillyTavern's context) and MVU's, its events
/// (MVU's update events fire when the app tells the page the story moved,
/// window.dshStoryUpdate; others are kept and never fire), its globals, and
/// toastr as the app's own notice. A write is refused, said where it can be
/// done.
const _storyJs = r'''
(function(){
  var d=dshStory;
  function clone(v){return v===undefined?undefined:JSON.parse(JSON.stringify(v));}
  function refusal(){
    var e=new Error('Read only in an island: writing to the story is 整页画布\'s');
    e.code='unsupportedCapability';e.committed=false;return e;
  }
  function readOnly(){return Promise.reject(refusal());}
  function readOnlyNow(){throw refusal();}
  function floor(id){
    if(id===undefined||id==='latest')return d.last;
    return typeof id==='number'&&id<0?d.last+1+id:id;
  }
  function floorData(f){
    if(f===d.messageId)return d.data;
    if(f===d.last)return d.latest;
    var x=d.floors&&d.floors[f];return x?x.data:{};
  }
  function getVariables(o){
    var t=(o&&o.type)||'chat';
    if(t==='chat')return clone(d.chat)||{};
    if(t==='global')return clone(d.global)||{};
    if(t==='character')return clone(d.character)||{};
    if(t!=='message')return {};
    return clone(floorData(floor(o&&o.message_id)))||{};
  }
  // 酒馆助手's getAllVariables: the global ones, the character's, the chat's,
  // then this floor's, each over the one before. Arrays are replaced, not
  // merged by index, as 酒馆助手 does since 3.5.1.
  function plain(v){return !!v&&typeof v==='object'&&!Array.isArray(v);}
  function merge(a,b){
    if(!plain(a)||!plain(b))return b===undefined?a:b;
    for(var k in b)a[k]=merge(a[k],b[k]);
    return a;
  }
  function getAllVariables(){
    return [d.character,d.chat,d.data].reduce(function(a,v){return merge(a,clone(v)||{});},clone(d.global)||{});
  }
  function steps(p){var out=[];String(p).replace(/[^.[\]]+|\[(\d+)\]/g,function(m,i){out.push(i===undefined?m:+i);return m;});return out;}
  function vwd(v){return Array.isArray(v)&&v.length===2&&typeof v[1]==='string'?v[0]:v;}
  var Mvu={
    events:{VARIABLE_INITIALIZED:'mag_variable_initialized',VARIABLE_UPDATE_STARTED:'mag_variable_update_started',
      COMMAND_PARSED:'mag_command_parsed',VARIABLE_UPDATE_ENDED:'mag_variable_update_ended'},
    getMvuData:function(o){return getVariables(o||{type:'chat'});},
    getCurrentMvuData:function(){return clone(d.data)||{};},
    getMvuVariable:function(data,p,o){
      o=o||{};var v=(data||{})[(o.category||'stat')+'_data'];
      steps(p).forEach(function(k){v=v==null?undefined:v[k];});
      return vwd(v===undefined?o.default_value:v);
    },
    getRecordFromMvuData:function(data,c){return (data||{})[(c||'stat')+'_data']||{};},
    replaceMvuData:readOnly,replaceCurrentMvuData:readOnly,parseMessage:readOnly,setMvuVariable:readOnly,
    reloadInitVar:function(){return Promise.resolve(false);}
  };
  // The floors this page has (its own, the first, the latest), as
  // getChatMessages gives them: a number, 'n', 'a-b' (negatives from the
  // end); floors it does not have are not in what it gives.
  function getChatMessages(range,o){
    o=o||{};
    var a,b;
    if(typeof range==='number'){a=b=range;}
    else{
      var m=/^\s*(-?\d+)\s*(?:-\s*(-?\d+)\s*)?$/.exec(String(range));
      if(!m)throw new Error('getChatMessages: not a floor or a range: '+range);
      a=parseInt(m[1],10);b=m[2]===undefined?a:parseInt(m[2],10);
    }
    a=floor(a);b=floor(b);
    if(a>b){var t=a;a=b;b=t;}
    var role=o.role||'all',hide=o.hide_state||'all',out=[];
    for(var f=Math.max(a,0);f<=b;f++){
      var x=d.floors&&d.floors[f];
      if(!x||(role!=='all'&&x.role!==role))continue;
      if((hide==='hidden'&&!x.is_hidden)||(hide==='unhidden'&&x.is_hidden))continue;
      var r={message_id:f,name:x.name,role:x.role,is_hidden:!!x.is_hidden,message:x.message,data:clone(x.data)||{},extra:{}};
      if(o.include_swipes){r.swipe_id=0;r.swipes=[x.message];r.swipes_data=[clone(x.data)||{}];}
      out.push(r);
    }
    return out;
  }
  // SillyTavern's context, as far as this page knows the story: the chat as
  // ST keeps it (the floors above, the rest holes), the two names, the
  // character (by its id here, not ST's list index), the chat's variables.
  function stMessage(x){
    return {name:x.name,is_user:x.role==='user',is_system:!!x.is_hidden,mes:x.message,extra:{},swipe_id:0,
      swipes:[x.message],variables:[clone(x.data)||{}]};
  }
  var context={
    getContext:function(){return context;},
    getCurrentChatId:function(){return d.chatId||undefined;},
    variables:{
      local:{get:function(n){return (d.chat||{})[n];},set:readOnlyNow},
      global:{get:function(n){return (d.global||{})[n];},set:readOnlyNow}
    }
  };
  Object.defineProperties(context,{
    chat:{enumerable:true,get:function(){
      var c=[];c.length=d.last+1;
      for(var k in d.floors||{})c[+k]=stMessage(d.floors[k]);
      return c;
    }},
    chatId:{enumerable:true,get:function(){return d.chatId||undefined;}},
    name1:{enumerable:true,get:function(){return d.name1||undefined;}},
    name2:{enumerable:true,get:function(){return d.name2||undefined;}},
    characterId:{enumerable:true,get:function(){return d.characterId==null?undefined:d.characterId;}},
    chatMetadata:{enumerable:true,get:function(){return {variables:clone(d.chat)||{}};}}
  });
  // Events: kept by name; MVU's update events fire when the story moves.
  var listeners={};
  function eventOn(name,fn){(listeners[name]||(listeners[name]=[])).push(fn);return {stop:function(){eventRemoveListener(name,fn);}};}
  function eventMakeFirst(name,fn){(listeners[name]||(listeners[name]=[])).unshift(fn);return {stop:function(){eventRemoveListener(name,fn);}};}
  function eventOnce(name,fn){
    function once(){eventRemoveListener(name,once);return fn.apply(this,arguments);}
    return eventOn(name,once);
  }
  function eventRemoveListener(name,fn){var l=listeners[name],i=l?l.indexOf(fn):-1;if(i>=0)l.splice(i,1);}
  function eventEmit(name){
    var args=[].slice.call(arguments,1);
    return (listeners[name]||[]).slice().reduce(function(p,fn){
      return p.then(function(){return fn.apply(null,args);});
    },Promise.resolve()).then(function(){});
  }
  // The app's newer story (its own floor unchanged): read from now on, and
  // MVU's update told when the variables moved.
  window.dshStoryUpdate=function(next){
    var was=JSON.stringify([d.latest,d.chat,d.global,d.character]),before=clone(d.latest)||{};
    d=next;
    if(JSON.stringify([d.latest,d.chat,d.global,d.character])===was)return;
    eventEmit(Mvu.events.VARIABLE_UPDATE_STARTED,clone(d.latest)||{},before)
      .then(function(){return eventEmit(Mvu.events.VARIABLE_UPDATE_ENDED,clone(d.latest)||{},before);});
  };
  // Globals: what initializeGlobal shares, and what this page has (Mvu, z,
  // YAML); waiting for any other waits until it is shared.
  var globals={Mvu:Mvu},waiters={};
  ['z','YAML'].forEach(function(n){if(window[n]!==undefined)globals[n]=window[n];});
  function initializeGlobal(n,v){
    n=String(n);globals[n]=v;window[n]=v;
    var w=waiters[n]||[];delete waiters[n];w.forEach(function(ok){ok(v);});
  }
  function waitGlobalInitialized(n){
    n=String(n);
    if(Object.prototype.hasOwnProperty.call(globals,n))return Promise.resolve(globals[n]);
    return new Promise(function(ok){(waiters[n]||(waiters[n]=[])).push(ok);});
  }
  // toastr: the app's own notice, as on the canvas (its text only).
  function plainText(s){
    if(s==null)return '';
    var x=new DOMParser().parseFromString(String(s),'text/html');
    if(!x.body)return '';
    [].forEach.call(x.body.querySelectorAll('script,style,template,noscript'),function(e){e.remove();});
    [].forEach.call(x.body.querySelectorAll('br,p,div,li,tr,h1,h2,h3,h4,h5,h6'),function(e){e.before(' ');e.after(' ');});
    return String(x.body.textContent).replace(/\s+/g,' ').trim();
  }
  function post(o){window.TavernIsland.postMessage(JSON.stringify(o));}
  var toastSeq=0;
  function toast(level){
    return function(message,title){
      var m=plainText(message),t=plainText(title),id=++toastSeq;
      if(m||t)post({type:'toast',level:level,title:t,message:m,id:id});
      var shown=window.jQuery?jQuery():undefined;
      if(shown)shown.dshToast=id;
      return shown;
    };
  }
  function clearToast(shown){
    if(shown==null)post({type:'toastClear',id:null});
    else if(shown.dshToast)post({type:'toastClear',id:shown.dshToast});
  }
  var toastr={options:{},info:toast('info'),success:toast('success'),warning:toast('warning'),error:toast('error'),
    clear:clearToast,remove:clearToast,subscribe:function(){}};
  var api={Mvu:Mvu,getVariables:getVariables,getAllVariables:getAllVariables,
    getCurrentMessageId:function(){return d.messageId;},getLastMessageId:function(){return d.last;},
    getChatMessages:getChatMessages,SillyTavern:context,toastr:toastr,
    waitGlobalInitialized:waitGlobalInitialized,initializeGlobal:initializeGlobal,
    eventOn:eventOn,eventOnce:eventOnce,eventMakeFirst:eventMakeFirst,eventMakeLast:eventOn,
    eventRemoveListener:eventRemoveListener,eventEmit:eventEmit,
    tavern_events:{},replaceVariables:readOnly,insertOrAssignVariables:readOnly,insertVariables:readOnly,
    updateVariablesWith:readOnly,deleteVariable:readOnly};
  for(var k in api)if(window[k]===undefined)window[k]=api[k];
})();
''';
