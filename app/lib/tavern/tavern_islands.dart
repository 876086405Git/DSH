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

final _htmlFence = RegExp(
  r'^(`{3,}|~{3,})[ \t]*html\b[^\n]*\n([\s\S]*?)\n?^\1[ \t]*$',
  multiLine: true,
  caseSensitive: false,
);
final _blockHtml = RegExp(
  r'<(style|script|div|table|details|svg|section|article|center|iframe|canvas|form|button)\b',
  caseSensitive: false,
);

/// Text that is only a little punctuation: what follows a component in the
/// same sentence (「…`</dsh-item>`。」) goes back onto the text before it.
final _trailing = RegExp(r'^[\s\p{P}]{1,3}$', unicode: true);

/// [text] cut into parts: each component tag outside an HTML block a part of
/// its own; with [islands], each ```html block an island and text around them
/// that carries block HTML an island too (as SillyTavern would show it); the
/// rest Markdown. One text part, [text] as it is, when there is nothing else.
List<TavernPart> tavernParts(String text, {bool islands = true}) {
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
      islands && _blockHtml.hasMatch(segment) ? TavernIslandPart(_htmlOf(segment)) : TavernTextPart(segment.trim()),
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
    for (final fence in _htmlFence.allMatches(text)) {
      outside(text.substring(at, fence.start));
      final html = fence.group(2)!;
      if (html.trim().isNotEmpty) parts.add(TavernIslandPart(html));
      at = fence.end;
    }
  }
  outside(text.substring(at));
  if (parts.every((p) => p is TavernTextPart)) return [TavernTextPart(text)];
  return parts;
}

/// Text with HTML in it, as a page: HTML blocks as they are, each other
/// paragraph a <p> with its line breaks and *actions* in italics.
String _htmlOf(String segment) => [
  for (final block in segment.trim().split(RegExp(r'\n[ \t]*\n')))
    if (block.trimLeft().startsWith('<'))
      block
    else
      '<p>${block.trim().replaceAllMapped(RegExp(r'\*([^*\n]+)\*'), (m) => '<em>${m[1]}</em>').replaceAll('\n', '<br>')}</p>',
].join('\n');

/// Whether [html]'s scripts read the story (a status bar drawing its
/// floor's variables): then its island is told them (tavern_island_story.dart).
bool tavernIslandReadsStory(String html) => _readsStory.hasMatch(html);

final _readsStory = RegExp(
  r'(<script\b|\son[a-z]+\s*=)[\s\S]*\b(getVariables|Mvu|getChatMessages|getCurrentMessageId|getLastMessageId|waitGlobalInitialized)\b',
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
/// [libraries] (jQuery, lodash) come first, for its scripts; [story] is
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
  String css(Color c) =>
      'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(3)})';
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
html,body{margin:0;padding:0;background:transparent;}
#dsh-island{display:flow-root;}
body{color:${css(text)};font:${fontSize}px/1.5 system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;overflow-wrap:anywhere;}
a{color:${css(accent)};}
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

/// An island's read-only helpers: 酒馆助手's getters and MVU's over
/// dshStory; a write is refused, said where it can be done.
const _storyJs = r'''
(function(){
  var d=dshStory;
  function clone(v){return v===undefined?undefined:JSON.parse(JSON.stringify(v));}
  function readOnly(){
    var e=new Error('Read only in an island: writing to the story is 整页画布\'s');
    e.code='unsupportedCapability';e.committed=false;return Promise.reject(e);
  }
  function floor(id){
    if(id===undefined||id==='latest')return d.last;
    return typeof id==='number'&&id<0?d.last+1+id:id;
  }
  function getVariables(o){
    var t=(o&&o.type)||'chat';
    if(t==='chat')return clone(d.chat)||{};
    if(t!=='message')return {};
    var f=floor(o&&o.message_id);
    return clone(f===d.messageId?d.data:f===d.last?d.latest:{})||{};
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
  function message(){return {message_id:d.messageId,name:d.name,role:d.role,is_hidden:false,message:d.message,data:clone(d.data)||{},extra:{}};}
  function quiet(){return {stop:function(){}};}
  var api={Mvu:Mvu,getVariables:getVariables,
    getCurrentMessageId:function(){return d.messageId;},getLastMessageId:function(){return d.last;},
    getChatMessages:function(r){var f=floor(typeof r==='number'?r:parseInt(String(r),10));return f===d.messageId?[message()]:[];},
    waitGlobalInitialized:function(n){return n==='Mvu'?Promise.resolve(Mvu):new Promise(function(){});},
    initializeGlobal:function(n,v){window[n]=v;},
    eventOn:quiet,eventOnce:quiet,eventMakeFirst:quiet,eventMakeLast:quiet,eventRemoveListener:function(){},
    tavern_events:{},replaceVariables:readOnly,insertOrAssignVariables:readOnly,insertVariables:readOnly,
    updateVariablesWith:readOnly,deleteVariable:readOnly};
  for(var k in api)if(window[k]===undefined)window[k]=api[k];
})();
''';
