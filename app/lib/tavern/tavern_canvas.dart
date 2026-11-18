// 整页画布 (docs/design/roleplay-ui.md §3, roleplay-compat.md §6.3; the
// roadmap's level 2): the whole story in one web page, its DOM built the way
// SillyTavern builds it (#chat > .mes[mesid] > .mes_block > .mes_text), so a
// card's CSS that reaches across messages (#chat .mes …) takes, and ST's own
// colour variables (--SmartThemeQuoteColor …) carry the story's colours.
// Messages arrive as JSON through our script; the page itself is loaded once.
// A card's scripts run in it, with 酒馆助手's helpers (variables, messages,
// events, floors, toastr) answered through dsh.call. Component
// tags (<dsh-letter>…, roleplay-ui §5) are Web Components here, with parts
// and --dsh-* variables a card's CSS may restyle.

import 'dart:convert';
import 'dart:ui' show Color;

import 'package:dsh_tavern/dsh_tavern.dart' show PersonaSelection, TavernPersona;

import 'tavern_canvas_helpers.dart';
import 'tavern_card_scripts.dart' show tavernUsesMvu;

/// One message on the canvas.
final class TavernCanvasEntry {
  const TavernCanvasEntry({
    required this.mesid,
    required this.nodeId,
    required this.name,
    required this.html,
    this.isUser = false,
    this.isSystem = false,
  });

  /// Its place in the shown path, as ST numbers messages.
  final int mesid;
  final String nodeId;
  final String name;
  final String html;
  final bool isUser;
  final bool isSystem;

  Map<String, Object?> toJson() => {
    'mesid': mesid,
    'node': nodeId,
    'name': name,
    'html': html,
    'user': isUser,
    'system': isSystem,
  };
}

/// The words the canvas's components say, in the reader's language:
/// letterFrom and phoneFrom carry `{from}`, rollCheck `{skill}`.
final class TavernCanvasLabels {
  const TavernCanvasLabels({
    this.letter = 'A letter',
    this.letterFrom = 'A letter from {from}',
    this.taken = 'Got',
    this.clue = 'Clue',
    this.phone = 'A message',
    this.phoneFrom = 'Message from {from}',
    this.roll = 'Roll',
    this.rollCheck = 'Check: {skill}',
    this.success = 'Success',
    this.failure = 'Failure',
    this.game = "A mini-game goes here; it can't be played here yet",
    this.replied = '{name} replied',
  });

  final String letter, letterFrom, taken, clue, phone, phoneFrom, roll, rollCheck, success, failure, game;

  /// Said to a screen reader when a reply that was being written is in.
  final String replied;

  Map<String, String> toJson() => {
    'letter': letter,
    'letterFrom': letterFrom,
    'taken': taken,
    'clue': clue,
    'phone': phone,
    'phoneFrom': phoneFrom,
    'roll': roll,
    'rollCheck': rollCheck,
    'success': success,
    'failure': failure,
    'game': game,
    'replied': replied,
  };
}

/// [value] as JSON written inside our <script>: every `<` escaped, so no
/// `</script`, `<!--` or `<script` in a card's text can end or derail it.
String _inScript(Object? value) => jsonEncode(value).replaceAll('<', r'\u003c');

/// [entries] as our script's render() takes them.

String tavernCanvasJson(List<TavernCanvasEntry> entries) => jsonEncode([for (final e in entries) e.toJson()]);

String _escape(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

final _tagOrText = RegExp(r'<[^<>]*>|[^<]+|<');

/// What is said, as ST marks it: the quote marks kept, inside a <q>.
final _said = RegExp('"[^"\\n]*"|\u201C[^\u201D\\n]*\u201D|\u00AB[^\u00BB\\n]*\u00BB|「[^」\\n]*」|『[^』\\n]*』|＂[^＂\\n]*＂');
final _strong = RegExp(r'\*\*(?!\s)([^*\n]+?)(?<!\s)\*\*');
final _em = RegExp(r'(?<![*\w])\*(?![\s*])([^*\n]+?)(?<!\s)\*(?![*\w])');
final _emUnderscore = RegExp(r'(?<![\w_])_(?![\s_])([^_\n]+?)(?<!\s)_(?![\w_])');
final _code = RegExp(r'`([^`\n]+)`');

/// Markdown's inline marks in [text], leaving HTML tags (and what their
/// attributes say) as written.
String _inline(String text) {
  final out = StringBuffer();
  for (final m in _tagOrText.allMatches(text)) {
    final piece = m[0]!;
    if (piece.startsWith('<') && piece.length > 1) {
      out.write(piece);
      continue;
    }
    // Code first: nothing inside it is formatted.
    var at = 0;
    for (final c in _code.allMatches(piece)) {
      out.write(_words(piece.substring(at, c.start)));
      out.write('<code>${_escape(c[1]!)}</code>');
      at = c.end;
    }
    out.write(_words(piece.substring(at)));
  }
  return out.toString();
}

String _words(String text) => text
    .replaceAllMapped(_strong, (m) => '<strong>${m[1]}</strong>')
    .replaceAllMapped(_em, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_emUnderscore, (m) => '<em>${m[1]}</em>')
    .replaceAllMapped(_said, (m) => '<q>${m[0]}</q>');

final _fence = RegExp(r'^(`{3,}|~{3,})[ \t]*([\w-]*)[^\n]*\n([\s\S]*?)\n?^\1[ \t]*$', multiLine: true);
final _blockTag = RegExp(
  r'^<(div|p|style|script|table|details|section|article|center|ul|ol|blockquote|pre|h[1-6]|hr|img|svg|iframe|form|figure|dsh-[a-z-]+)\b',
  caseSensitive: false,
);
final _heading = RegExp(r'^(#{1,6})\s+(.*)$');

/// A message's text as the canvas shows it: paragraphs with their line
/// breaks, Markdown's emphasis, what is said in <q>, ```html blocks and block
/// HTML as written, other code blocks escaped.
String tavernStoryHtml(String text) {
  final source = text.replaceAll('\r\n', '\n');
  final out = <String>[];
  void prose(String segment) {
    for (final block in segment.split(RegExp(r'\n[ \t]*\n'))) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      if (_blockTag.hasMatch(trimmed)) {
        out.add(trimmed);
      } else if (_heading.firstMatch(trimmed) case final h? when !trimmed.contains('\n')) {
        final level = h[1]!.length;
        out.add('<h$level>${_inline(h[2]!)}</h$level>');
      } else if (trimmed.split('\n').every((l) => l.trimLeft().startsWith('>'))) {
        final inner = [for (final l in trimmed.split('\n')) l.trimLeft().substring(1).trimLeft()].join('\n');
        out.add('<blockquote><p>${_inline(inner).replaceAll('\n', '<br>')}</p></blockquote>');
      } else {
        out.add('<p>${_inline(trimmed).replaceAll('\n', '<br>')}</p>');
      }
    }
  }

  var at = 0;
  for (final f in _fence.allMatches(source)) {
    prose(source.substring(at, f.start));
    final lang = f[2]!.toLowerCase();
    final body = f[3]!;
    out.add(
      lang == 'html'
          ? body
          : '<pre><code${lang.isEmpty ? '' : ' class="language-$lang"'}>${_escape(body)}</code></pre>',
    );
    at = f.end;
  }
  prose(source.substring(at));
  return out.join('\n');
}

String _css(Color c) =>
    'rgba(${(c.r * 255).round()},${(c.g * 255).round()},${(c.b * 255).round()},${c.a.toStringAsFixed(3)})';

/// How many of the latest messages the canvas always lays out; older ones
/// are skipped while off screen (CSS content-visibility).
const tavernCanvasNear = 20;

/// The user's personas as the page is told them (dsh.setPersonas): each one's
/// id, name, description and its position (ST's own numbers); which this
/// chat uses, and which is the default.
Map<String, Object?> tavernCanvasPersonas(List<TavernPersona> personas, PersonaSelection? selection) => {
  'list': [
    for (final p in personas)
      {'id': p.id, 'name': p.name, 'description': p.description, 'position': p.descriptionPosition},
  ],
  'current': selection?.persona?.id,
  'default': selection?.defaultPersonaId,
};

/// The most of a card's toastr notice shown, in characters: its title, its
/// text.
const tavernToastTitleMax = 60;
const tavernToastMax = 300;

/// What a card script's toastr call shows (the page posts {type:'toast',
/// level, title, message}, already plain text): the title over the text, each
/// cut when long, up longer the more there is to read and longer still for a
/// warning or an error. Null when there is nothing to show.
({String title, String message, Duration duration})? tavernToast(Map<Object?, Object?> data) {
  String field(String key, int max) {
    final text = switch (data[key]) {
      final String s => s.trim(),
      _ => '',
    };
    final runes = text.runes.toList();
    return runes.length > max ? '${String.fromCharCodes(runes.take(max))}…' : text;
  }

  final title = field('title', tavernToastTitleMax);
  final message = field('message', tavernToastMax);
  if (title.isEmpty && message.isEmpty) return null;
  final serious = data['level'] == 'warning' || data['level'] == 'error';
  final length = title.runes.length + message.runes.length;
  final ms = (1500 + length * 60).clamp(serious ? 4000 : 2000, serious ? 8000 : 6000);
  return (title: title, message: message, duration: Duration(milliseconds: ms));
}

/// The page the canvas loads once: ST's structure and colour variables, the
/// story's size and colours, and our script (allowed by [nonce]) that draws
/// what render()/stream() hand it and reports a long press on a message to
/// the `DshTavern` channel. [noScripts] and [offline] are 酒馆设置 › 安全's
/// choices, as for islands. [libraries] are put in first, for card scripts.
/// [themeCss] (an ST theme's custom CSS) comes after our styles, so it wins
/// where both say something, as it does in ST. [cardScripts] ({id, name,
/// content}, tavern_card_scripts.dart) are the card's own scripts, each run
/// in a hidden frame once the story is drawn; not when scripts do not run.
/// [card] (its fields) and [characterId] are the chat's character, for the
/// scripts that ask about it; none for a group.
String tavernCanvasDocument({
  required Color text,
  required Color accent,
  required Color muted,
  required Color quote,
  required Color emphasis,
  required Color userTint,
  required double fontSize,
  required double lineHeight,
  required String nonce,
  String userLabel = '',
  TavernCanvasLabels labels = const TavernCanvasLabels(),
  bool noScripts = false,
  bool offline = false,
  List<String> libraries = const [],
  String themeCss = '',
  List<Map<String, Object?>> cardScripts = const [],
  Map<String, Object?>? card,
  String? characterId,
}) {
  // The card and its scripts go in as JSON (see [_inScript]).
  final cardJson = noScripts || card == null ? 'null' : _inScript(card);
  final cardIdJson = noScripts ? 'null' : _inScript(characterId);
  final cardScriptsJson = noScripts ? '[]' : _inScript(cardScripts);
  // MVU's variables, kept by the engine, for a card that uses them.
  final mvu = !noScripts && tavernUsesMvu(card);
  // The libraries card scripts expect on the page (jQuery, lodash), ours and
  // so under the page's nonce; not there when card scripts do not run.
  final preload = noScripts
      ? ''
      : [for (final code in libraries) '<script nonce="$nonce">${code.replaceAll('</script', r'<\/script')}</script>']
            .join('\n');
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
:root{
  --dsh-text:${_css(text)};--dsh-accent:${_css(accent)};--dsh-muted:${_css(muted)};--dsh-user:${_css(userTint)};
  --SmartThemeBodyColor:var(--dsh-text);--SmartThemeQuoteColor:${_css(quote)};--SmartThemeEmColor:${_css(emphasis)};
  --SmartThemeUnderlineColor:var(--dsh-accent);--SmartThemeBorderColor:var(--dsh-muted);
  --mainFontSize:${fontSize}px;
}
html,body{margin:0;padding:0;background:transparent;}
body{color:var(--dsh-text);font:var(--mainFontSize)/$lineHeight system-ui,-apple-system,"Noto Sans CJK SC",sans-serif;overflow-wrap:anywhere;-webkit-text-size-adjust:100%;}
#chat{display:flex;flex-direction:column;gap:14px;padding:12px 16px 24px;}
.mes{display:flex;flex-direction:column;}
.mes.far{content-visibility:auto;contain-intrinsic-size:auto 160px;}
.mes .ch_name{font-size:.82em;font-weight:600;color:var(--dsh-accent);margin-bottom:2px;}
.mes[is_user="true"] .ch_name{color:var(--dsh-muted);}
.mes[is_user="true"] .mes_text{background:var(--dsh-user);border-radius:16px;padding:8px 12px;align-self:flex-end;max-width:85%;box-sizing:border-box;}
.mes[is_user="true"] .mes_block{align-items:flex-end;}
.mes[is_system="true"] .mes_text{color:var(--dsh-muted);font-style:italic;}
.mes_block{display:flex;flex-direction:column;}
.mes_text p{margin:0 0 .6em;}
.mes_text p:last-child{margin-bottom:0;}
.mes_text q{color:var(--SmartThemeQuoteColor);quotes:none;}
.mes_text q::before,.mes_text q::after{content:none;}
.mes_text em{color:var(--SmartThemeEmColor);}
.mes_text a{color:var(--dsh-accent);}
.mes_text img,.mes_text video,.mes_text svg{max-width:100%;height:auto;}
.mes_text pre{white-space:pre-wrap;}
.mes[data-streaming] .mes_text>:last-child::after,.mes[data-streaming] .mes_text:empty::after{content:"\\25CF" / "";color:var(--dsh-muted);margin-left:3px;font-size:.6em;vertical-align:middle;}
#dsh-live{position:absolute;width:1px;height:1px;margin:-1px;padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0;}
</style>
${themeCss.trim().isEmpty ? '' : '<style id="st-theme-css">${themeCss.replaceAll(RegExp('</style', caseSensitive: false), r'<\/style')}</style>'}
</head>
<body><div id="chat"></div><div id="dsh-live" aria-live="polite" aria-atomic="true"></div>
$preload
<script nonce="$nonce">
(function(){
  var chat=document.getElementById('chat');
  var userLabel=${_inScript(userLabel)};
  // A card's scripts: off with 酒馆设置 › 安全 › 不运行卡的脚本 (the page's
  // policy would refuse them too). Never given this page's own nonce.
  var runScripts=${!noScripts},running=Promise.resolve();
  function inert(s){var t=(s.getAttribute('type')||'').trim().toLowerCase();return t!==''&&!/^(text|application)[/](java|ecma)script\$|^module\$/.test(t);}
  // innerHTML leaves <script> inert: each is rebuilt in place, one after
  // another in document order (and after any earlier message's), an
  // external one loaded before the next runs. An inline one is named after
  // its message (sourceURL dsh-mes-<n>.js), so whatever it defines can tell
  // which message it belongs to from the stack, however late it runs: in a
  // timer, a handler, after an await.
  var marks=[];
  function mark(m){return marks.push(typeof WeakRef==='function'?new WeakRef(m):{deref:function(){return m;}})-1;}
  function runIn(els){
    els.forEach(function(m){
      [].slice.call(m.querySelectorAll('script')).forEach(function(old){
        running=running.then(function(){return new Promise(function(done){
          if(!m.isConnected||!old.parentNode||inert(old)){done();return;}
          // MagVarUpdate is built in (Mvu): not fetched.
          if(isMvuSrc(old.getAttribute('src'))){old.remove();done();return;}
          var s=document.createElement('script');
          for(var a=0;a<old.attributes.length;a++){var at=old.attributes[a];if(at.name!=='nonce')s.setAttribute(at.name,at.value);}
          // Once run, it leaves the message (a started script runs on): the
          // message's text is its words, as in ST, not the code.
          var gone=function(){s.remove();};
          if(old.hasAttribute('src')){s.async=false;s.onload=s.onerror=function(){gone();done();};old.parentNode.replaceChild(s,old);}
          else if((s.getAttribute('type')||'').trim().toLowerCase()==='module'){
            s.text=withoutMvuImport(old.text)+'\\n//# sourceURL=dsh-mes-'+mark(m)+'.js';s.onload=s.onerror=gone;old.parentNode.replaceChild(s,old);done();
          }
          else{s.text=old.text+'\\n//# sourceURL=dsh-mes-'+mark(m)+'.js';old.parentNode.replaceChild(s,old);gone();done();}
        });});
      });
    });
  }
  function nearBottom(){return window.innerHeight+window.scrollY>=document.body.scrollHeight-80;}
  function toBottom(){window.scrollTo(0,document.body.scrollHeight);}
  function sig(e){return JSON.stringify([e.name||'',!!e.user,!!e.system,e.html||'']);}
  function mes(e){
    var m=document.createElement('div');
    m.className='mes';
    m.setAttribute('mesid',String(e.mesid));
    m.setAttribute('ch_name',e.name||'');
    m.setAttribute('is_user',e.user?'true':'false');
    m.setAttribute('is_system',e.system?'true':'false');
    m.dataset.node=e.node||'';
    var block=document.createElement('div');block.className='mes_block';
    var name=document.createElement('div');name.className='ch_name';
    var nameText=document.createElement('span');nameText.className='name_text';
    nameText.textContent=e.user?(userLabel||e.name||''):(e.name||'');
    // To a screen reader, one article each, in order, named by who speaks.
    m.setAttribute('role','article');
    m.setAttribute('aria-label',nameText.textContent);
    name.appendChild(nameText);
    var text=document.createElement('div');text.className='mes_text';
    text.innerHTML=e.html||'';
    block.appendChild(name);block.appendChild(text);m.appendChild(block);
    return m;
  }
  var stream=null,writing=false;
  // What a screen reader is told without moving there (#dsh-live): emptied
  // first, so the same words twice are said twice.
  function say(text){
    var live=document.getElementById('dsh-live');if(!live)return;
    live.textContent='';setTimeout(function(){live.textContent=text;},60);
  }
  // dsh.call(method, params): a Promise of what the engine answers (the
  // result, or an Error carrying code/committed/fieldPath).
  var calls={},callSeq=0;
  // Asked, not kept for any event's answer: what starts the engine's own
  // events (setMvuEnabled) must not have their answers wait on it.
  function ask(method,params){
    return new Promise(function(ok,no){
      var id=++callSeq;calls[id]={ok:ok,no:no};
      post({type:'call',id:id,method:method,params:params===undefined?{}:params});
    });
  }
  function call(method,params){
    var p=ask(method,params);
    // Kept until answered: an event's answer waits for the writes its
    // handlers started.
    inflight.push(p);
    var gone=function(){var at=inflight.indexOf(p);if(at>=0)inflight.splice(at,1);};
    p.then(gone,gone);
    return p;
  }
  window.dsh={
    call:function(method,params){return track(call(method,params));},
    answer:function(r){
      var c=r&&calls[r.id];if(!c)return;delete calls[r.id];
      if(r.ok){c.ok(r.result);return;}
      var x=r.error||{};var e=new Error(x.message||x.code||'failed');
      e.code=x.code;e.committed=!!x.committed;e.fieldPath=x.fieldPath==null?null:x.fieldPath;
      c.no(e);
    },
    render:function(list){
      var stay=nearBottom()||!chat.firstChild;
      if(stream){stream.remove();stream=null;}
      var replied=writing;writing=false;
      // A message drawn as it was is kept, not drawn again: its HTML (and
      // anything a card put in it) stays as it is.
      var kept={},fresh=[];
      for(var c=chat.firstElementChild;c;c=c.nextElementSibling){if(c.dataset.node)kept[c.dataset.node]=c;}
      for(var i=0;i<list.length;i++){
        var e=list[i],key=sig(e),m=kept[e.node||''];
        if(m&&m._dsh===key){delete kept[e.node];m.setAttribute('mesid',String(e.mesid));}
        else{m=mes(e);m._dsh=key;fresh.push(m);}
        // Only the latest few are always laid out; older ones are skipped
        // while off screen.
        m.classList.toggle('far',i<list.length-$tavernCanvasNear);
        var at=chat.children[i];
        if(at!==m)chat.insertBefore(m,at||null);
      }
      while(chat.children.length>list.length)chat.lastElementChild.remove();
      lastList=list;
      if(loaded)renumber();
      // A newly drawn message's scripts run, once the page has the engine's
      // snapshot for their getters (or has been told it cannot).
      var scripted=fresh.filter(function(m){return m.querySelector('script');});
      if(runScripts&&scripted.length){
        // One the page's copy has not got yet (just written, its delivery
        // still on the way) is read afresh first, so its scripts find it.
        if(loaded&&scripted.some(function(m){return floorOf(m.dataset.node)<0;}))reload();
        var go=function(){runIn(scripted);};dsh.scripts.ready().then(go,go);
      }
      // A reply that was being written is in: said once, by who (a screen
      // reader goes to it from there), not read out as it was written.
      var last=chat.lastElementChild;
      if(replied&&last&&fresh.indexOf(last)>=0&&last.getAttribute('is_user')!=='true')say(fill(L.replied,'name',last.getAttribute('aria-label')||''));
      // The card's own scripts start once the story is drawn, its snapshot in.
      if(runScripts&&!scriptsStarted&&(cardScripts.length||mvuWanted)){
        scriptsStarted=true;
        var start=function(){runCardScripts();};dsh.scripts.ready().then(start,start);
      }
      if(stay)toBottom();
    },
    stream:function(name,html){
      var stay=nearBottom();
      if(html===null){if(stream){stream.remove();stream=null;}return;}
      writing=true;
      if(!stream){stream=mes({mesid:chat.children.length,node:'',name:name,html:'',user:false,system:false});stream.dataset.streaming='1';stream.setAttribute('aria-busy','true');chat.appendChild(stream);}
      else if(stream.getAttribute('ch_name')!==(name||'')){stream.setAttribute('ch_name',name||'');stream.setAttribute('aria-label',name||'');stream.querySelector('.name_text').textContent=name||'';}
      stream.querySelector('.mes_text').innerHTML=html;
      if(stay)toBottom();
    }
  };
  // Card scripts' synchronous getters (酒馆助手's shape, P2 §4.3): a copy of
  // what the engine had at the snapshot, written through with dsh.call. A
  // write reads back at once, then settles to what the engine kept, or back
  // to that if it was refused; only the latest write to a scope counts.
  var vars={},msgs=[],loading=null;
  function clone(v){return v===undefined?undefined:JSON.parse(JSON.stringify(v));}
  function slot(o){
    var type=(o&&o.type)||'chat';
    if(type==='message'){
      var id=o&&o.message_id;
      if(id===undefined||id==='latest'||id===-1)return {key:'message'};
      if(typeof id!=='number'||id%1!==0)throw new TypeError('message_id is a message number');
      if(id<0)id=msgs.length+id;
      return {key:'message:'+id,target:{scope:'message',messageId:id},id:id};
    }
    if(type==='global'||type==='chat'||type==='character')return {key:type,target:{scope:type}};
    // A card script's own: the script asking (or the one script_id names).
    if(type==='script'){
      var s=o&&o.script_id!=null?scriptById(String(o.script_id)):callerScript();
      if(!s)throw new TypeError('Script variables are asked for from a card script, or by its script_id');
      return {key:'script:'+s.id,target:{scope:'script',scriptOwner:{kind:'character',scriptId:s.id}}};
    }
    throw new TypeError('Variables of type '+type+' are not kept on this page');
  }
  function varKey(t){return t.scope==='script'?'script:'+((t.scriptOwner||{}).scriptId||''):t.scope;}
  function kept(s){
    var e=vars[s.key];
    if(e)return e;
    var m=s.id===undefined?null:msgs[s.id];
    return vars[s.key]={target:s.target||{scope:'message'},version:null,value:m&&m.data?m.data:{},seq:0};
  }
  function getVariables(o){var e=kept(slot(o));return clone(e.pending!==undefined?e.pending:e.value);}
  function replaceVariables(variables,o){
    var e=kept(slot(o)),mine=++e.seq;
    e.pending=clone(variables)||{};
    return call('replaceVariables',{target:e.target,value:variables}).then(function(r){
      e.value=r.value;e.version=r.version;
      if(e.seq===mine)e.pending=undefined;
      return clone(r.value);
    },function(x){if(e.seq===mine)e.pending=undefined;throw x;});
  }
  // The engine's deliveries (cache): held until the snapshot is in, then
  // only those after its lastSeq; variables update in place (a write still
  // in flight stays on top), a message rewritten in place is replaced, and
  // anything else about the path — a message gone or moved, a revision this
  // copy did not come from — is read afresh as a new snapshot.
  var loaded=false,lastSeq=0,pathRev=null,held=[];
  function sameRef(a,b){return !!a&&!!b&&a.chatId===b.chatId&&a.nodeId===b.nodeId;}
  function setVar(v){
    var t=v.target||{};
    if(t.scope!=='message'){var k=varKey(t),e=vars[k]||(vars[k]={seq:0});e.target=t;e.version=v.version;e.value=v.value;return;}
    var latest=vars.message;
    if(latest&&latest.target&&sameRef(latest.target.messageRef,t.messageRef)){latest.version=v.version;latest.value=v.value;}
    for(var i=0;i<msgs.length;i++)if(sameRef(msgs[i].ref,t.messageRef)){
      msgs[i].data=v.value;var at=vars['message:'+i];if(at){at.version=v.version;at.value=v.value;}
    }
  }
  function reload(){loaded=false;loading=null;dsh.scripts.ready().catch(function(){});}
  function apply(d){
    if(typeof d.seq!=='number'||d.seq<=lastSeq)return;
    lastSeq=d.seq;
    var x=d.delta;if(!x)return;
    (x.variables||[]).forEach(setVar);
    // The engine's resources (books, presets, regexes…) changed, the path
    // or not.
    adoptResources(x.resourceRefs);
    if(x.baseRevision===x.newRevision)return;
    var moved=(x.removedRefs||[]).length||Object.keys(x.indexChanges||{}).length||x.baseRevision!==pathRev;
    var up=x.upsertMessages||[];
    for(var u=0;!moved&&u<up.length;u++){
      var found=-1;for(var i=0;i<msgs.length;i++)if(sameRef(msgs[i].ref,up[u].ref))found=i;
      if(found<0)moved=true;else msgs[found]=up[u];
    }
    if(moved){reload();return;}
    pathRev=x.newRevision;
  }
  dsh.scripts={
    ready:function(){
      if(!loading)loading=call('snapshot').then(function(s){
        msgs=s.messages||[];
        for(var k in vars)if(k.indexOf('message:')===0&&vars[k].pending===undefined)delete vars[k];
        (s.variables||[]).forEach(function(v){
          var k=varKey(v.target),e=vars[k]||(vars[k]={seq:0});
          e.target=v.target;e.version=v.version;e.value=v.value;
        });
        adoptResources(s.resourceRefs,s.context);
        lastSeq=s.lastSeq||0;pathRev=s.pathRevision||null;loaded=true;
        renumber();
        var waiting=held;held=[];waiting.forEach(apply);
        // The library's presets, for getPreset by name, on the way.
        preloadPresets();
        return true;
      },function(x){loading=null;throw x;});
      return loading;
    },
    deliver:function(d){
      if(!d)return;
      if(d.kind==='lifecycle'){lifecycle(d);return;}
      if(d.kind==='invoke'){invoke(d);return;}
      if(d.kind==='generation'){generationEvent(d);return;}
      // A script's button pressed in the app: the event getButtonEvent names.
      if(d.kind==='button'){fire(evName('dsh_button__'+d.scriptId+'__'+d.name),[]);return;}
      if(d.kind!=='cache')return;
      // Not asked for yet: a snapshot taken later covers what was dropped.
      if(!loaded){if(!loading&&held.length>=200)held=[];held.push(d);return;}
      apply(d);
    },
    getVariables:getVariables,
    replaceVariables:watched(replaceVariables)
  };
  if(!window.getVariables)window.getVariables=getVariables;
  if(!window.replaceVariables)window.replaceVariables=dsh.scripts.replaceVariables;
  // The rest of 酒馆助手's variable writes, as its public page describes them
  // (read, change, replace): each a Promise of what the engine kept, failed
  // if the engine refused. The page leaves merge depth open; here objects
  // merge all the way down and arrays and other values are replaced whole.
  function plain(v){return v!==null&&typeof v==='object'&&!Array.isArray(v);}
  function assignDeep(into,from){for(var k in from){if(plain(into[k])&&plain(from[k]))assignDeep(into[k],from[k]);else into[k]=clone(from[k]);}return into;}
  function insertDeep(into,from){for(var k in from){if(!(k in into))into[k]=clone(from[k]);else if(plain(into[k])&&plain(from[k]))insertDeep(into[k],from[k]);}return into;}
  function steps(path){
    var out=[];String(path).replace(/[^.[\\]]+|\\[(\\d+)\\]/g,function(m,i){out.push(i===undefined?m:Number(i));return m;});
    if(!out.length)throw new TypeError('An empty variable path');
    return out;
  }
  function updateVariablesWith(updater,o){
    return attempt(function(){
      var v=getVariables(o),r=updater(v);
      var keep=function(n){return replaceVariables(n===undefined?v:n,o);};
      return r&&typeof r.then==='function'?r.then(keep):keep(r);
    });
  }
  function insertOrAssignVariables(vars,o){return attempt(function(){return replaceVariables(assignDeep(getVariables(o),vars||{}),o);});}
  function insertVariables(vars,o){return attempt(function(){return replaceVariables(insertDeep(getVariables(o),vars||{}),o);});}
  function deleteVariable(path,o){
    return attempt(function(){
      var v=getVariables(o),s=steps(path),at=v;
      for(var i=0;i<s.length-1;i++){if(at===null||typeof at!=='object'||!(s[i] in at))return Promise.resolve({variables:v,delete_occurred:false});at=at[s[i]];}
      var last=s[s.length-1];
      if(at===null||typeof at!=='object'||!(last in at))return Promise.resolve({variables:v,delete_occurred:false});
      if(Array.isArray(at)&&typeof last==='number')at.splice(last,1);else delete at[last];
      return replaceVariables(v,o).then(function(kept){return {variables:kept,delete_occurred:true};});
    });
  }
  [['updateVariablesWith',updateVariablesWith],['insertOrAssignVariables',insertOrAssignVariables],
   ['insertVariables',insertVariables],['deleteVariable',deleteVariable]].forEach(function(f){
    var w=watched(f[1]);dsh.scripts[f[0]]=w;if(!window[f[0]])window[f[0]]=w;
  });
  // getChatMessages(range, option) as 酒馆助手's public page gives it:
  // synchronous, from this page's copy; floors numbered along the whole
  // chosen path before any filter; a floor number, 'a-b', negative from the
  // end, or {{lastMessageId}}; only floors that exist, ascending. A floor
  // whose data is not an object reads data: null, not {}.
  function floor(s){
    var t=String(s).trim().replace(/\\{\\{lastMessageId\\}\\}/g,String(msgs.length-1));
    if(!/^-?\\d+\$/.test(t))throw new RangeError('Not a floor: '+s);
    var n=parseInt(t,10);return n<0?msgs.length+n:n;
  }
  function getChatMessages(range,o){
    o=o||{};
    var a,b;
    if(typeof range==='number'){if(range%1!==0)throw new RangeError('Not a floor: '+range);a=b=range<0?msgs.length+range:range;}
    else{
      var r=String(range).trim().replace(/\\{\\{lastMessageId\\}\\}/g,String(msgs.length-1));
      var m=/^(-?\\d+)\\s*-\\s*(-?\\d+)\$/.exec(r);
      if(m){a=floor(m[1]);b=floor(m[2]);}else{a=b=floor(r);}
    }
    var role=o.role||'all',hide=o.hide_state||'all',swipes=!!o.include_swipes;
    var out=[];
    for(var i=0;i<msgs.length;i++){
      var x=msgs[i],id=x.messageId===undefined?i:x.messageId;
      if(id<a||id>b)continue;
      if(role!=='all'&&x.role!==role)continue;
      if(hide==='hidden'&&!x.hidden)continue;
      if(hide==='unhidden'&&x.hidden)continue;
      var base={message_id:id,name:x.name,role:x.role,is_hidden:!!x.hidden};
      if(swipes){
        var ss=x.swipes&&x.swipes.length?x.swipes:[{text:x.message,data:x.data,info:{}}];
        base.swipe_id=x.swipeId||0;
        base.swipes=ss.map(function(s){return s.text;});
        base.swipes_data=ss.map(function(s){return s.data===undefined?{}:s.data;});
        base.swipes_info=ss.map(function(s){return s.info||{};});
      }else{
        base.message=x.message;base.data=x.data===undefined?{}:x.data;base.extra=x.extra||{};
      }
      out.push(clone(base));
    }
    return out;
  }
  dsh.scripts.getChatMessages=getChatMessages;
  if(!window.getChatMessages)window.getChatMessages=getChatMessages;
  // Floors (酒馆助手's getLastMessageId, getCurrentMessageId, getIframeName and
  // getMessageId, as its public page gives them), numbered as
  // getChatMessages numbers them; a message is found by its node, a swipe's
  // too. The page leaves an empty chat open: -1 here, as {{lastMessageId}}.
  function floorOf(node){
    for(var i=0;i<msgs.length;i++){
      var x=msgs[i],id=x.messageId===undefined?i:x.messageId;
      if(x.ref&&x.ref.nodeId===node)return id;
      var ss=x.swipes||[];
      for(var j=0;j<ss.length;j++)if(ss[j].ref&&ss[j].ref.nodeId===node)return id;
    }
    return -1;
  }
  function getLastMessageId(){return msgs.length-1;}
  // ST numbers .mes[mesid] by floor, and cards find a floor so: once this
  // page has the path, its messages carry their true floors (a long chat is
  // drawn from partway along).
  function renumber(){
    for(var c=chat.firstElementChild;c;c=c.nextElementSibling){
      if(!c.dataset.node)continue;
      var f=floorOf(c.dataset.node);if(f>=0)c.setAttribute('mesid',String(f));
    }
  }
  // Displayed messages (酒馆助手's 渲染楼层 page).
  var lastList=[];
  function displayed(id){
    if(typeof id!=='number'||id%1!==0)throw new TypeError('message_id is a floor number');
    for(var c=chat.firstElementChild;c;c=c.nextElementSibling){
      if(c.dataset.node&&!c.dataset.streaming&&c.getAttribute('mesid')===String(id))return c;
    }
    return null;
  }
  // The floor's shown text (.mes_text), as jQuery; none when it is not shown.
  function retrieveDisplayedMessage(id){
    var m=displayed(id),t=m&&m.querySelector('.mes_text');
    return window.jQuery?jQuery(t?[t]:[]):t;
  }
  // The floor drawn again as it was given (a card's changes to it gone, its
  // scripts run anew); with \$mes, its words shown in that floor's place
  // instead, nothing kept. A floor not shown: nothing.
  function renderOneMessage(id,\$mes){
    return attempt(function(){
      var m=displayed(id),e=null;
      if(!m)return Promise.resolve();
      for(var i=0;i<lastList.length;i++)if(lastList[i].node===m.dataset.node)e=lastList[i];
      if(!e)return Promise.resolve();
      var fresh=mes(e);fresh._dsh=sig(e);fresh.className=m.className;fresh.setAttribute('mesid',m.getAttribute('mesid'));
      var target=\$mes&&(\$mes.jquery?\$mes[0]:\$mes);
      if(target&&target!==m){
        var t=target.classList&&target.classList.contains('mes_text')?target:target.querySelector&&target.querySelector('.mes_text');
        if(t){
          t.innerHTML=fresh.querySelector('.mes_text').innerHTML;
          [].forEach.call(t.querySelectorAll('script'),function(x){if(!inert(x))x.remove();});
        }
        return Promise.resolve();
      }
      m.parentNode.replaceChild(fresh,m);
      if(runScripts&&fresh.querySelector('script')){var go=function(){runIn([fresh]);};return dsh.scripts.ready().then(go,go);}
      return Promise.resolve();
    });
  }
  [['retrieveDisplayedMessage',retrieveDisplayedMessage],['renderOneMessage',renderOneMessage]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
  // SillyTavern (酒馆助手's 访问酒馆接口 page: the context ST gives its
  // extensions): what this page can truly give — the chat as ST keeps it
  // (name, is_user, is_system for a hidden one, mes, its swipes and their
  // variables), fresh from this page's copy at each reading; getContext();
  // the chat's id. The rest of ST's interface is not here, rather than faked.
  function stMessage(x){
    var ss=x.swipes&&x.swipes.length?x.swipes:null;
    var out={name:x.name,is_user:x.role==='user',is_system:!!x.hidden,mes:x.message,extra:x.extra||{},
      swipe_id:x.swipeId||0,variables:ss?ss.map(function(s){return s.data||{};}):[x.data||{}]};
    if(ss)out.swipes=ss.map(function(s){return s.text;});
    return clone(out);
  }
  var SillyTavern={
    getContext:function(){return SillyTavern;},
    getCurrentChatId:function(){var m=msgs[0];return m&&m.ref?m.ref.chatId:undefined;}
  };
  // A Slash script, run by the engine in this chat (酒馆助手's 触发 /STScript
  // page): its pipe, or undefined when it stopped at /abort; a failure is
  // thrown.
  function triggerSlash(command){
    return call('triggerSlash',{source:String(command)}).then(function(r){
      return r&&r.completion==='aborted'?undefined:r?r.pipe:undefined;
    });
  }
  // ST's own runner, as that page shows it: never throws, says how it went.
  SillyTavern.executeSlashCommandsWithOptions=function(command){
    var out={interrupt:false,pipe:'',isBreak:false,isAborted:false,isQuietlyAborted:false,abortReason:'',
      isError:false,errorMessage:''};
    return call('triggerSlash',{source:String(command)}).then(function(r){
      out.pipe=r&&typeof r.pipe==='string'?r.pipe:'';
      out.isAborted=!!r&&r.completion==='aborted';
      return out;
    },function(e){out.isError=true;out.errorMessage=String(e&&e.message||e);return out;});
  };
  Object.defineProperty(SillyTavern,'chat',{get:function(){return msgs.map(stMessage);},enumerable:true});
  Object.defineProperty(SillyTavern,'chatId',{get:function(){return SillyTavern.getCurrentChatId();},enumerable:true});
  // The chat's character card (酒馆助手's 获取角色卡 pages): this chat's own
  // card, by 'current', its name or its id; another character's is not on
  // this page, and is not found (getCharacter throws, getCharData gives
  // null), as the page says of one missing. A group has no one card.
  var card=$cardJson,cardId=$cardIdJson;
  function isCurrent(n){return !!card&&(n==null||n==='current'||n===card.name||n===cardId);}
  function getCurrentCharacterName(){return card?card.name||null:null;}
  function getCurrentCharacterId(){return card?cardId:null;}
  function getCharacter(n){
    return attempt(function(){
      if(!isCurrent(n===undefined?'current':n))throw new Error('No such character here: '+n);
      var x=card.extensions||{};
      return Promise.resolve(clone({name:card.name,version:card.character_version||'',creator:card.creator||'',
        creator_notes:card.creator_notes||'',description:card.description||'',worldbook:x.world||null,
        first_messages:[card.first_mes||''].concat(card.alternate_greetings||[]),extensions:x}));
    });
  }
  // The older v1 shape: its own fields, and the card's whole data under data.
  function getCharData(n){
    if(!isCurrent(n))return Promise.resolve(null);
    var x=card.extensions||{};
    return Promise.resolve(clone({name:card.name,description:card.description||'',personality:card.personality||'',
      scenario:card.scenario||'',first_mes:card.first_mes||'',mes_example:card.mes_example||'',
      creator_notes:card.creator_notes||'',tags:card.tags||[],talkativeness:x.talkativeness!=null?x.talkativeness:0.5,
      fav:x.fav!=null?x.fav:false,data:card}));
  }
  // The chat's regexes (酒馆助手's 获取正则 page), which getTavernRegexes
  // hands out at once: the engine's, as of the snapshot and kept current by
  // its deliveries (adoptResources); another character's or preset's are not
  // on this page, and come back empty.
  var regexes=null;
  function getTavernRegexes(option){
    var o=option||{},name=o.name;
    if(o.type!=='global'&&o.type!=='character'&&o.type!=='preset')
      throw new Error('getTavernRegexes: type is global, character or preset');
    if(!regexes)throw new Error('getTavernRegexes: the regexes are not read yet');
    if(o.type==='global')return clone(regexes.global||[]);
    if(o.type==='character')return name==null||name==='current'||isCurrent(name)?clone(regexes.character||[]):[];
    return name==null||name==='in_use'?clone(regexes.preset||[]):[];
  }
  // Its picture, as the app has it (a data: URL the page can show); null for
  // another character's, or a card that has none.
  function getCharAvatarPath(n){
    if(!isCurrent(n))return Promise.resolve(null);
    return call('characterAvatar',{}).then(function(r){return r||null;},function(){return null;});
  }
  Object.defineProperty(SillyTavern,'name2',{get:function(){return getCurrentCharacterName()||undefined;},enumerable:true});
  [['triggerSlash',triggerSlash],['getCurrentCharacterName',getCurrentCharacterName],
   ['getCurrentCharacterId',getCurrentCharacterId],
   ['getCharacter',watched(getCharacter)],['getCharData',getCharData],
   ['getCharAvatarPath',getCharAvatarPath],['getTavernRegexes',getTavernRegexes]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
  // The user's personas (酒馆助手's 获取用户人设 page), as the app tells this
  // page (dsh.setPersonas) and keeps telling it as they change. A persona
  // carries what is kept of it here — id, name, description, position (ST's
  // numbers), whether it is the default; nothing more is made up.
  var personas={list:[],current:null,'default':null};
  dsh.setPersonas=function(p){personas=p&&Array.isArray(p.list)?p:{list:[],current:null,'default':null};};
  function getPersonaNames(){return personas.list.map(function(p){return p.name;});}
  function getPersonaIds(){return personas.list.map(function(p){return p.id;});}
  function personaById(id){for(var i=0;i<personas.list.length;i++)if(personas.list[i].id===id)return personas.list[i];return null;}
  function getCurrentPersonaId(){return personaById(personas.current)?personas.current:null;}
  function getCurrentPersonaName(){var p=personaById(personas.current);return p?p.name:null;}
  // By 'current', its id, or a name only one persona has: the persona, null,
  // or false for a name more than one has.
  function personaFor(key){
    var p=key==='current'?personaById(personas.current):personaById(key);
    if(p)return p;
    var named=personas.list.filter(function(x){return x.name===key;});
    return named.length>1?false:named[0]||null;
  }
  function getPersona(which){
    var key=which===undefined?'current':String(which);
    var p=personaFor(key);
    if(p===false)throw new Error('More than one persona is called '+key);
    if(!p)throw new Error('No such persona: '+key);
    return clone({avatar_id:p.id,name:p.name,title:'',description:p.description||'',position:p.position,
      is_default:p.id===personas['default']});
  }
  // Their pictures, as the app sends them (dsh.setPersonaAvatar: a data: URL,
  // or null for none), each once until it changes; asked for, one is there
  // at once, or null — never a throw.
  var personaAvatars={};
  dsh.setPersonaAvatar=function(id,url){if(url)personaAvatars[id]=url;else delete personaAvatars[id];};
  function getPersonaAvatarPath(which){
    var p=personaFor(which===undefined?'current':String(which));
    return p&&personaAvatars[p.id]||null;
  }
  Object.defineProperty(SillyTavern,'name1',{get:function(){return getCurrentPersonaName()||undefined;},enumerable:true});
  [['getPersonaNames',getPersonaNames],['getPersonaIds',getPersonaIds],['getCurrentPersonaName',getCurrentPersonaName],
   ['getCurrentPersonaId',getCurrentPersonaId],['getPersona',getPersona],
   ['getPersonaAvatarPath',getPersonaAvatarPath]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
  // Its two players (酒馆助手's 播放音频 pages): 'bgm' music and 'ambient'
  // sounds, each a list, a track it is on and settings. The lists and the
  // settings belong to the chat — the app keeps them ({type:'audio'} out,
  // dsh.setAudioState in); what is playing goes with the page.
  var audio={},audioModes=['repeat_one','repeat_all','shuffle','play_one_and_stop'];
  function channel(type){
    if(type!=='bgm'&&type!=='ambient')throw new Error('No such audio type: '+type);
    return audio[type]||(audio[type]={list:[],settings:{enabled:true,mode:'repeat_all',muted:false,volume:100},
      el:null,current:null,touched:false});
  }
  // A track without a title is called by its file's name.
  function audioTitle(a){
    if(a.title!=null&&String(a.title)!=='')return String(a.title);
    var path=String(a.url).split(/[?#]/)[0],name=path.slice(path.lastIndexOf('/')+1);
    try{name=decodeURIComponent(name);}catch(e){}
    var dot=name.lastIndexOf('.');return dot>0?name.slice(0,dot):name;
  }
  function audioItems(list){
    if(!Array.isArray(list))throw new Error('Not a list of audio');
    return list.filter(function(a){return a&&typeof a.url==='string'&&a.url!=='';})
      .map(function(a){return {title:audioTitle(a),url:a.url};});
  }
  function audioSettle(o,s){
    s=s||{};
    if(typeof s.enabled==='boolean')o.enabled=s.enabled;
    if(audioModes.indexOf(s.mode)>=0)o.mode=s.mode;
    if(typeof s.muted==='boolean')o.muted=s.muted;
    if(typeof s.volume==='number'&&isFinite(s.volume))o.volume=Math.max(0,Math.min(100,s.volume));
  }
  function audioSaved(c){
    c.touched=true;
    var out={};
    ['bgm','ambient'].forEach(function(t){var x=channel(t);out[t]={list:clone(x.list),settings:clone(x.settings)};});
    post({type:'audio',state:out});
    audioReport();
  }
  // What the players are doing, for the app's own player (its panel): said
  // once for each run of changes.
  var audioReported=false;
  function audioReport(){
    if(audioReported)return;audioReported=true;
    setTimeout(function(){
      audioReported=false;
      var now={};
      ['bgm','ambient'].forEach(function(t){
        var c=channel(t),n=getCurrentAudio(t);
        now[t]={title:n.title,playing:n.playing,tracks:c.list.length,settings:clone(c.settings)};
      });
      post({type:'audioNow',now:now});
    },0);
  }
  function audioApply(c){
    var el=c.el;if(!el)return;
    el.volume=c.settings.volume/100;el.muted=c.settings.muted;el.loop=c.settings.mode==='repeat_one';
    if(!c.settings.enabled&&!el.paused)el.pause();
  }
  function audioStart(c,item){
    c.current=item;
    if(!c.el){
      c.el=new Audio();c.el.preload='auto';
      c.el.addEventListener('ended',function(){audioReport();audioNext(c);});
      c.el.addEventListener('play',audioReport);c.el.addEventListener('pause',audioReport);
    }
    if(c.el.dataset.url!==item.url){c.el.dataset.url=item.url;c.el.src=item.url;}
    audioApply(c);
    // Asked to play while the app is out of sight: it waits to be back.
    if(audioHidden)c.suspended=c.settings.enabled;
    else if(c.settings.enabled){var p=c.el.play();if(p&&p.catch)p.catch(function(){});}
    audioReport();
  }
  // A track ended (one on repeat loops instead): the next, or another at
  // random, or none.
  function audioNext(c,asked){
    var n=c.list.length,mode=c.settings.mode;
    if(!n||!c.settings.enabled||!asked&&mode==='play_one_and_stop')return;
    var at=-1;
    for(var i=0;i<n;i++)if(c.current&&c.list[i].url===c.current.url){at=i;break;}
    var next=(at+1)%n;
    if(mode==='shuffle'&&n>1){do{next=Math.floor(Math.random()*n);}while(next===at);}
    audioStart(c,c.list[next]);
  }
  function playAudio(type,a){
    var c=channel(type),item=audioItems([a])[0];
    if(!item)throw new Error('playAudio: no url');
    for(var i=0;i<c.list.length;i++)if(c.list[i].url===item.url)return audioStart(c,c.list[i]);
    c.list.push(item);audioSaved(c);audioStart(c,item);
  }
  function pauseAudio(type){var c=channel(type);c.suspended=false;if(c.el)c.el.pause();}
  function getCurrentAudio(type){
    var c=channel(type),el=c.el,src=c.current?c.current.url:'',title='';
    for(var i=0;i<c.list.length;i++)if(c.list[i].url===src){title=c.list[i].title;break;}
    var at=el&&isFinite(el.duration)&&el.duration>0?el.currentTime/el.duration*100:0;
    return {src:src,title:title,playing:!!el&&!el.paused&&!el.ended,progress:Math.max(0,Math.min(100,at))};
  }
  function getAudioList(type){return clone(channel(type).list);}
  function replaceAudioList(type,list){var c=channel(type);c.list=audioItems(list);audioSaved(c);}
  // Not a second of one already there by its title or its url.
  function appendAudioList(type,list){
    var c=channel(type);
    audioItems(list).forEach(function(a){
      if(!c.list.some(function(x){return x.url===a.url||x.title===a.title;}))c.list.push(a);
    });
    audioSaved(c);
  }
  function getAudioSettings(type){return clone(channel(type).settings);}
  function setAudioSettings(type,s){var c=channel(type);audioSettle(c.settings,s);audioApply(c);audioSaved(c);}
  // The chat's own, as the app kept them; a player the scripts already set
  // up before they came keeps theirs.
  dsh.setAudioState=function(state){
    ['bgm','ambient'].forEach(function(t){
      var c=channel(t),s=state&&state[t];
      if(!s||c.touched)return;
      try{c.list=audioItems(s.list||[]);}catch(e){}
      audioSettle(c.settings,s.settings);audioApply(c);
    });
    audioReport();
  };
  // The app out of sight: what is playing stops, and goes on when it is back
  // (the person did not pause it). A player paused by then stays paused.
  var audioHidden=false;
  dsh.audioSuspend=function(on){
    audioHidden=!!on;
    ['bgm','ambient'].forEach(function(t){
      var c=channel(t),el=c.el;if(!el)return;
      if(on){if(!el.paused&&!el.ended){c.suspended=true;el.pause();}}
      else if(c.suspended){c.suspended=false;if(c.settings.enabled){var p=el.play();if(p&&p.catch)p.catch(function(){});}}
    });
  };
  // The app's player: play or pause ({type, action:'toggle'}), or settings
  // the person chose ({type, settings}), kept like a script's.
  dsh.audioControl=function(cmd){
    var c=channel(cmd&&cmd.type);
    // The person's own tracks: not twice by their link (two with the same
    // file name are still two).
    if(cmd.append){
      var added=audioItems(cmd.append).filter(function(a){return !c.list.some(function(x){return x.url===a.url;});});
      if(added.length){c.list=c.list.concat(added);audioSaved(c);}
    }
    if(cmd.settings)setAudioSettings(cmd.type,cmd.settings);
    if(cmd.action==='toggle'){
      c.suspended=false;
      if(c.el&&!c.el.paused)c.el.pause();
      else if(c.current)audioStart(c,c.current);
      else if(c.list.length)audioStart(c,c.list[0]);
    }else if(cmd.action==='next')audioNext(c,true);
    audioReport();
  };
  [['playAudio',playAudio],['pauseAudio',pauseAudio],['getCurrentAudio',getCurrentAudio],['getAudioList',getAudioList],
   ['replaceAudioList',replaceAudioList],['appendAudioList',appendAudioList],['getAudioSettings',getAudioSettings],
   ['setAudioSettings',setAudioSettings]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
  dsh.scripts.SillyTavern=SillyTavern;
  if(!window.SillyTavern)window.SillyTavern=SillyTavern;
  // The message the caller is in: the nearest named script on the stack;
  // else a src script while it first runs; else an inline handler's event.
  function callerMessage(){
    var limit=Error.stackTraceLimit;Error.stackTraceLimit=200;
    var stack=String(new Error().stack||'');Error.stackTraceLimit=limit;
    var k=/dsh-mes-(\\d+)\\.js/.exec(stack),m=k&&marks[+k[1]]?marks[+k[1]].deref():null;
    if(!m&&document.currentScript)m=owner(document.currentScript);
    if(!m&&window.event&&window.event.target)m=owner(window.event.target);
    return m&&m.isConnected&&m.dataset.node?m:null;
  }
  // Outside a message it throws, as the public page says.
  function getCurrentMessageId(){
    var m=callerMessage(),id=m?floorOf(m.dataset.node):-1;
    if(id<0)throw new Error('getCurrentMessageId: not called from a message on this page');
    return id;
  }
  function getIframeName(){
    var s=callerScript();
    return s?'TH-script--'+s.name+'--'+s.id:'TH-message--'+getCurrentMessageId()+'--0';
  }
  function getMessageId(name){
    var r=/^TH-message--(\\d+)--\\d+\$/.exec(String(name));
    if(!r)throw new Error('Not a message interface name: '+name);
    return parseInt(r[1],10);
  }
  [['getLastMessageId',getLastMessageId],['getCurrentMessageId',getCurrentMessageId],
   ['getIframeName',getIframeName],['getMessageId',getMessageId]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
  // toastr, which 酒馆助手's pages have (toastr.error(content, title)): the
  // app's own notice, not drawn here. Content may be HTML; its text is what
  // shows (parsed apart from the page: nothing in it loads or runs). Each
  // call is numbered; clear and remove put away the one a call showed (what
  // it returned), or with nothing given whichever is up; another element is
  // not one of ours, and nothing goes.
  function plainText(s){
    if(s==null)return '';
    var d=new DOMParser().parseFromString(String(s),'text/html');
    if(!d.body)return '';
    [].forEach.call(d.body.querySelectorAll('script,style,template,noscript'),function(e){e.remove();});
    [].forEach.call(d.body.querySelectorAll('br,p,div,li,tr,h1,h2,h3,h4,h5,h6'),function(e){e.before(' ');e.after(' ');});
    return String(d.body.textContent).replace(/\\s+/g,' ').trim();
  }
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
  dsh.scripts.toastr=toastr;
  if(!window.toastr)window.toastr=toastr;
  // Writing messages (酒馆助手's set/create/delete/rotateChatMessages, as its
  // public pages give them): each a Promise of nothing. The page's own field
  // names are the engine's but for four; every other field goes as written,
  // and one the engine does not know is refused there, not dropped here.
  // Done means the engine kept it and this page's copy has caught up.
  var renames={is_hidden:'hidden',swipe_id:'swipeId',swipes_data:'swipesData',swipes_info:'swipesInfo'};
  function attempt(f){try{return f();}catch(e){return Promise.reject(e);}}
  function renamed(m){var x={};for(var k in m)if(k!=='message_id')x[renames[k]||k]=m[k];return x;}
  function refreshOf(o){return {refresh:(o&&o.refresh)||'affected'};}
  function caughtUp(p){return p.then(function(){if(!loaded&&loading)return loading.then(function(){},function(){});});}
  function setChatMessages(list,o){return attempt(function(){
    var patches=[].concat(list||[]).map(function(m){
      if(!m||typeof m.message_id!=='number')throw new TypeError('each message names its message_id');
      return {messageId:m.message_id,fields:renamed(m)};
    });
    return caughtUp(call('setChatMessages',{patches:patches,options:refreshOf(o)}));
  });}
  function createChatMessages(list,o){return attempt(function(){
    var at=o&&o.insert_before;
    return caughtUp(call('createChatMessages',{messages:[].concat(list||[]).map(renamed),
      insertBefore:at===undefined||at==='end'?null:at,options:refreshOf(o)}));
  });}
  function deleteChatMessages(ids,o){return attempt(function(){
    return caughtUp(call('deleteChatMessages',{messageIds:[].concat(ids||[]),options:refreshOf(o)}));
  });}
  function rotateChatMessages(begin,middle,end,o){return attempt(function(){
    return caughtUp(call('rotateChatMessages',{begin:begin,middle:middle,end:end,options:refreshOf(o)}));
  });}
  [['setChatMessages',setChatMessages],['createChatMessages',createChatMessages],
   ['deleteChatMessages',deleteChatMessages],['rotateChatMessages',rotateChatMessages]].forEach(function(f){
    var w=watched(f[1]);dsh.scripts[f[0]]=w;if(!window[f[0]])window[f[0]]=w;
  });
  // Events (酒馆助手's eventOn and kin). The engine's events come with its
  // own names (MESSAGE_RECEIVED…); tavern_events gives them, and a name in
  // lower case is the same event (ST writes chat_id_changed for
  // CHAT_CHANGED). An event from the engine is answered once its handlers
  // are done and every engine call made meanwhile has come back.
  var on={},inflight=[];
  function evName(n){var u=String(n).toUpperCase();return u==='CHAT_ID_CHANGED'?'CHAT_CHANGED':u;}
  // A listener already there for the event is not added again (酒馆助手's
  // 监听和发送事件 page); first and last move it to that end.
  function listen(n,fn,once,where){
    if(typeof fn!=='function')throw new TypeError('a listener is a function');
    var k=evName(n),list=on[k]||(on[k]=[]);
    var at=-1;for(var i=0;i<list.length;i++)if(list[i].fn===fn)at=i;
    if(at>=0&&!where)return {stop:function(){eventRemoveListener(n,fn);}};
    var h=at>=0?list.splice(at,1)[0]:{fn:fn,once:once,owner:listenerOwner()};
    if(where==='first')list.unshift(h);else list.push(h);
    return {stop:function(){eventRemoveListener(n,fn);}};
  }
  // Whose a listener is: a card script's (each its own frame there), or this
  // page's; clearing reaches only the caller's own, as one frame's would.
  function listenerOwner(){var s=callerScript();return s?'script:'+s.id:'page';}
  function others(h){return h.owner!==listenerOwner();}
  function eventOn(n,fn){return listen(n,fn,false);}
  function eventOnce(n,fn){return listen(n,fn,true);}
  function eventMakeFirst(n,fn){return listen(n,fn,false,'first');}
  function eventMakeLast(n,fn){return listen(n,fn,false,'last');}
  function eventRemoveListener(n,fn){var k=evName(n);on[k]=(on[k]||[]).filter(function(h){return h.fn!==fn;});}
  function eventClearEvent(n){var k=evName(n);on[k]=(on[k]||[]).filter(others);}
  function eventClearListener(fn){for(var k in on)on[k]=on[k].filter(function(h){return h.fn!==fn;});}
  function eventClearAll(){for(var k in on)on[k]=on[k].filter(others);}
  function fire(k,args){
    var hs=(on[k]||[]).slice();
    on[k]=(on[k]||[]).filter(function(h){return !h.once;});
    return Promise.all(hs.map(function(h){
      return new Promise(function(ok){ok(h.fn.apply(null,args));}).then(function(){return null;},function(e){return e||new Error('failed');});
    }));
  }
  function settle(){
    if(!inflight.length)return Promise.resolve();
    var now=inflight.map(function(p){return p.then(null,function(){});});
    return Promise.all(now).then(settle);
  }
  function eventEmit(n){return fire(evName(n),[].slice.call(arguments,1)).then(function(){});}
  // As the page has it, nothing to wait on: each listener called in turn.
  function eventEmitAndWait(n){fire(evName(n),[].slice.call(arguments,1));}
  function lifecycle(d){
    // Its handlers read what the engine had: after the snapshot, if one
    // is on its way.
    var first=loaded||!loading?Promise.resolve():loading.then(null,function(){});
    var w={entries:[]};
    first.then(function(){watching.push(w);return fire(evName(d.name||''),d.args||[]);}).then(function(results){
      var at=watching.indexOf(w);if(at>=0)watching.splice(at,1);
      return settle().then(function(){return Promise.all(w.entries.map(function(e){return e.done;}));}).then(function(){
        var issues=results.filter(Boolean).map(function(e){return {code:'hookFailure',message:String(e&&e.message||e)};});
        // A write its handlers started and nobody waited for: its failure
        // is the event's.
        w.entries.forEach(function(e){
          if(e.failed&&!e.seen)issues.push({code:e.failed.code||'hookFailure',
            message:'A write nobody waited for failed: '+String(e.failed.message||e.failed)});
        });
        var ack={type:'ack',eventId:d.eventId,status:issues.length?'failed':'completed',issues:issues};
        // An MVU event: its candidate as the listeners left it.
        var mvu=issues.length?null:mvuFeedback(d);
        if(mvu)ack.mvu=mvu;
        post(ack);
      });
    });
  }
  // What scripts are handed is a Promise that notes whether anyone looked at
  // it (then, catch, finally, await — await goes through then for a
  // subclass); a failure nobody looked at, during an event, fails the event.
  var watching=[];
  class Watched extends Promise{then(a,b){if(this.w)this.w.seen=true;return super.then(a,b);}}
  function track(p){
    if(!p||typeof p.then!=='function')return p;
    var entry={seen:false,failed:null,done:null};
    var out=new Watched(function(ok,no){p.then(ok,no);});
    out.w=entry;
    entry.done=Promise.prototype.then.call(out,null,function(e){entry.failed=e||new Error('failed');});
    watching.forEach(function(w){w.entries.push(entry);});
    return out;
  }
  function watched(f){return function(){return track(f.apply(this,arguments));};}
  var names=['MESSAGE_SENT','MESSAGE_RECEIVED','MESSAGE_EDITED','MESSAGE_UPDATED','MESSAGE_SWIPED','MESSAGE_DELETED',
    'GENERATION_STARTED','GENERATION_AFTER_COMMANDS','GENERATION_STOPPED','GENERATION_ENDED','CHAT_CHANGED'];
  var events={};names.forEach(function(n){events[n]=n;});
  dsh.scripts.eventOn=eventOn;dsh.scripts.eventOnce=eventOnce;
  dsh.scripts.eventRemoveListener=eventRemoveListener;dsh.scripts.eventEmit=eventEmit;dsh.scripts.events=events;
  if(!window.eventOn)window.eventOn=eventOn;
  if(!window.eventOnce)window.eventOnce=eventOnce;
  if(!window.eventRemoveListener)window.eventRemoveListener=eventRemoveListener;
  if(!window.eventEmit)window.eventEmit=eventEmit;
  [['eventMakeFirst',eventMakeFirst],['eventMakeLast',eventMakeLast],['eventEmitAndWait',eventEmitAndWait],
   ['eventClearEvent',eventClearEvent],['eventClearListener',eventClearListener],['eventClearAll',eventClearAll]]
    .forEach(function(f){dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];});
  if(!window.tavern_events)window.tavern_events=events;
  // Prompt injections (酒馆助手's 注入提示词 page): injectPrompts(prompts,
  // {once}) gives {uninject} at once while the engine is told (an event's
  // answer waits for that, as for any write); uninjectPrompts(ids). Fields as
  // the page gives them: position 'in_chat', or 'none' (scanned, not sent);
  // should_scan; filter, a function kept here under a name of this page's
  // own — the engine asks for it by that name when it prepares a prompt, and
  // never sees it. A page drawn again knows none of the old names.
  var filters={},filterOf={},filterSeq=0,pageKey=Math.random().toString(36).slice(2,10);
  var positions={in_chat:'inChat',none:'scanOnly'};
  function injection(p){
    if(!p||typeof p.id!=='string'||!p.id)throw new TypeError('each prompt names its id');
    var x={id:p.id,content:p.content==null?'':String(p.content)};
    if(p.role!==undefined)x.role=p.role;
    if(p.position!==undefined)x.position=positions[p.position]||p.position;
    if(p.depth!==undefined)x.depth=p.depth;
    if(p.should_scan!==undefined)x.scan=p.should_scan;
    if(p.filter!=null){
      if(typeof p.filter!=='function')throw new TypeError('a filter is a function');
      var cb=pageKey+'-'+(++filterSeq);filters[cb]=p.filter;x.filter={callbackId:cb};
    }
    return x;
  }
  function forget(ids){ids.forEach(function(id){var cb=filterOf[id];if(cb){delete filters[cb];delete filterOf[id];}});}
  function injectPrompts(prompts,o){
    var list=[].concat(prompts||[]).map(injection);
    var ids=list.map(function(x){return x.id;});
    // The same id again: its new filter (or none) takes the old one's place.
    forget(ids);
    list.forEach(function(x){if(x.filter)filterOf[x.id]=x.filter.callbackId;});
    var told=track(call('injectPrompts',{prompts:list,once:!!(o&&o.once)}));
    var go=function(){uninjectPrompts(ids);};
    return {uninject:function(){Promise.prototype.then.call(told,go,go);}};
  }
  function uninjectPrompts(ids){
    ids=[].concat(ids||[]).map(String);
    forget(ids);
    track(call('uninjectPrompts',{ids:ids}));
  }
  // The engine asking for a filter's answer: true or false (anything else
  // is no answer), given once the writes it started are back; one it threw
  // says so, and one this page does not keep is not to be had.
  function invoke(d){
    function answer(o){o.type='invoked';o.requestId=d.requestId;post(o);}
    var fn=filters[d.callbackId];
    if(typeof fn!=='function'){answer({status:'failed',message:'This page keeps no filter '+d.callbackId});return;}
    var w={entries:[]};watching.push(w);
    var r;try{r=Promise.resolve(fn.apply(null,d.args||[]));}catch(e){r=Promise.reject(e);}
    var value=null,error=null;
    r.then(function(v){value=v;},function(e){error=e||new Error('failed');}).then(function(){
      var at=watching.indexOf(w);if(at>=0)watching.splice(at,1);
      return settle().then(function(){return Promise.all(w.entries.map(function(e){return e.done;}));});
    }).then(function(){
      var issues=[];
      w.entries.forEach(function(e){
        if(e.failed&&!e.seen)issues.push({code:e.failed.code||'hookFailure',message:'A write nobody waited for failed: '+String(e.failed.message||e.failed)});
      });
      if(error)answer({status:'failed',message:String(error&&error.message||error),issues:issues});
      else answer({status:'completed',value:typeof value==='boolean'?value:null,issues:issues});
    });
  }
  // Asking the model (酒馆助手's 请求生成 page): generate(config) and
  // generateRaw(config) give a Promise of the text, or {content, reasoning}
  // when reasoning was asked for. On the way, as the page tells it:
  // GENERATION_REQUESTED (its listeners may still change the config),
  // GENERATION_STARTED, the stream's tokens (whole so far, and just the new
  // ones) when should_stream, and GENERATION_ENDED with the text. What the
  // engine has no way to do here — another API, tools, a JSON schema,
  // pictures — is refused, said what, never quietly left out.
  var iframe_events={};
  ['GENERATION_REQUESTED','GENERATION_STARTED','STREAM_TOKEN_RECEIVED_FULLY','STREAM_TOKEN_RECEIVED_INCREMENTALLY','GENERATION_ENDED']
    .forEach(function(n){iframe_events[n]='js_'+n.toLowerCase();});
  function told(name,args){fire(evName(iframe_events[name]),args);}
  var placeholders={world_info_before:'worldInfoBefore',persona_description:'personaDescription',char_description:'charDescription',
    char_personality:'charPersonality',scenario:'scenario',world_info_after:'worldInfoAfter',dialogue_examples:'dialogueExamples',
    chat_history:'chatHistory',user_input:'userInput'};
  var placeholderOrder=['world_info_before','persona_description','char_description','char_personality','scenario',
    'world_info_after','dialogue_examples','chat_history','user_input'];
  function unsupported(what){var e=new Error('Not done here: '+what);e.code='unsupportedOption';e.committed=false;return e;}
  function rolePrompt(p){
    if(!p||typeof p!=='object')throw new TypeError('a prompt is {role, content}');
    if(p.image!=null)throw unsupported('image');
    return {role:p.role,content:p.content==null?'':String(p.content)};
  }
  function generationRequest(c,raw){
    ['custom_api','tools','tool_choice','json_schema','image'].forEach(function(k){if(c[k]!=null)throw unsupported(k);});
    var r={generationId:String(c.generation_id)};
    if(c.preset_name!=null&&c.preset_name!=='in_use')r.presetId=String(c.preset_name);
    if(c.user_input!=null)r.userInput=String(c.user_input);
    if(c.should_stream)r.stream=true;
    if(c.should_return_reasoning)r.includeReasoning=true;
    if(c.should_silence)r.silent=true;
    if(typeof c.max_chat_history==='number')r.maxChatHistory=c.max_chat_history;
    var o=c.overrides;
    if(o){
      var ov={};
      placeholderOrder.slice(0,7).forEach(function(k){if(o[k]!=null)ov[placeholders[k]]=String(o[k]);});
      var h=o.chat_history;
      if(h){
        if(h.with_depth_entries!=null)ov.withDepthEntries=!!h.with_depth_entries;
        if(h.author_note!=null)ov.authorNote=String(h.author_note);
        if(h.prompts!=null)ov.chatHistory=[].concat(h.prompts).map(rolePrompt);
      }
      r.overrides=ov;
    }
    if(c.injects!=null)r.injects=[].concat(c.injects).map(function(p,i){
      return injection(Object.assign({},p,{id:r.generationId+'-inject-'+i}));
    });
    if(raw)r.orderedPrompts=(c.ordered_prompts==null?placeholderOrder:[].concat(c.ordered_prompts)).map(function(p){
      if(typeof p==='string'){
        if(!placeholders[p])throw new TypeError('Not a prompt name: '+p);
        return {kind:'placeholder',placeholder:placeholders[p]};
      }
      var x=rolePrompt(p);x.kind='literal';return x;
    });
    return r;
  }
  var genSeq=0,generating={};
  function generation(kind,config){
    var c=Object.assign({},config||{});
    if(c.generation_id==null)c.generation_id='gen-'+pageKey+'-'+(++genSeq);
    var id=String(c.generation_id),g=null;
    return attempt(function(){
      return fire(evName(iframe_events.GENERATION_REQUESTED),[id,kind,c]).then(function(){
        var request=generationRequest(c,kind==='generateRaw');
        g=generating[id]={stream:!!c.should_stream,text:'',started:false};
        return call(kind,{request:request});
      }).then(function(res){
        delete generating[id];
        if(!g.started)told('GENERATION_STARTED',[id]);
        told('GENERATION_ENDED',[res.text,id]);
        if(!c.should_return_reasoning)return res.text;
        var out={content:res.text};if(res.reasoning!=null)out.reasoning=res.reasoning;return out;
      },function(e){if(generating[id]===g)delete generating[id];throw e;});
    });
  }
  function generationEvent(d){
    var g=generating[d.id];if(!g||d.isSnapshot)return;
    if((d.event==='started'||d.event==='textDelta')&&!g.started){g.started=true;told('GENERATION_STARTED',[d.id]);}
    if(d.event==='textDelta'&&g.stream){
      var delta=d.delta||'';
      g.text=d.text?d.text:g.text+delta;
      told('STREAM_TOKEN_RECEIVED_FULLY',[g.text,d.id]);
      told('STREAM_TOKEN_RECEIVED_INCREMENTALLY',[delta,d.id]);
    }
  }
  function generate(config){return generation('generate',config);}
  function generateRaw(config){return generation('generateRaw',config);}
  // Synchronous, as the page has it: whether one of this page's was running
  // and is now asked to stop (the engine's own answer follows).
  function stopGenerationById(id){
    id=String(id);if(!generating[id])return false;
    call('stopGenerationById',{generationId:id}).then(null,function(){});
    return true;
  }
  function stopAllGeneration(){var any=false;Object.keys(generating).forEach(function(id){any=stopGenerationById(id)||any;});return any;}
  [['generate',watched(generate)],['generateRaw',watched(generateRaw)],['stopGenerationById',stopGenerationById],
   ['stopAllGeneration',stopAllGeneration]].forEach(function(f){dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];});
  dsh.scripts.iframe_events=iframe_events;
  if(!window.iframe_events)window.iframe_events=iframe_events;
  dsh.scripts.injectPrompts=injectPrompts;dsh.scripts.uninjectPrompts=uninjectPrompts;
  if(!window.injectPrompts)window.injectPrompts=injectPrompts;
  if(!window.uninjectPrompts)window.uninjectPrompts=uninjectPrompts;
  var hold=null,from=null;
  function post(o){if(window.DshTavern)DshTavern.postMessage(JSON.stringify(o));}
  function owner(t){while(t&&t!==chat){if(t.classList&&t.classList.contains('mes'))return t;t=t.parentNode;}return null;}
  chat.addEventListener('touchstart',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    from=ev.touches[0];
    hold=setTimeout(function(){hold=null;post({type:'menu',node:m.dataset.node});},550);
  },{passive:true});
  function cancel(){if(hold){clearTimeout(hold);hold=null;}}
  chat.addEventListener('touchmove',function(ev){
    if(!from||!hold)return;var t=ev.touches[0];
    if(Math.abs(t.clientX-from.clientX)+Math.abs(t.clientY-from.clientY)>10)cancel();
  },{passive:true});
  chat.addEventListener('touchend',cancel);
  chat.addEventListener('touchcancel',cancel);
  chat.addEventListener('contextmenu',function(ev){
    var m=owner(ev.target);if(!m||!m.dataset.node)return;
    if(String(window.getSelection())==='')ev.preventDefault();
  });
  // Component tags as Web Components: their own look in a shadow root, with
  // parts (::part(paper) …) and --dsh-* variables left for a card to restyle.
  var L=${_inScript(labels.toJson())};
  function fill(s,k,v){return s.split('{'+k+'}').join(v);}
  function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  var base=':host{display:block;margin:6px 0;color:var(--dsh-text);font:inherit;font-style:normal;}'+
    '[part~=card]{border:1px solid var(--dsh-card-border,rgba(127,127,127,.28));border-radius:14px;padding:12px 14px;background:var(--dsh-card,rgba(127,127,127,.06));}'+
    '[part~=head]{display:flex;gap:8px;align-items:baseline;font-weight:600;font-size:.92em;}'+
    '[part~=head] [part~=title]{flex:1;color:var(--dsh-accent);}'+
    '[part~=meta]{font-weight:400;font-size:.8em;color:var(--dsh-muted);}'+
    '[part~=body]{margin-top:8px;}';
  // To a screen reader each is a group (a note for the plain ones) named by
  // what its head says; the head itself is hidden from it, so nothing is
  // said twice. A card's own role or label stays.
  function define(tag,css,html,a11y){
    if(customElements.get(tag))return;
    customElements.define(tag,class extends HTMLElement{
      connectedCallback(){
        if(this.shadowRoot)return;
        var root=this.attachShadow({mode:'open'});
        root.innerHTML='<style>'+base+css+'</style>'+html(this);
        var a=a11y(this);
        if(!this.hasAttribute('role'))this.setAttribute('role',a[0]);
        if(a[1]&&!this.hasAttribute('aria-label'))this.setAttribute('aria-label',a[1]);
      }
    });
  }
  function named(parts){return parts.filter(function(x){return x;}).join(' ');}
  function attr(el,names){for(var i=0;i<names.length;i++){var v=el.getAttribute(names[i]);if(v&&v.trim())return v.trim();}return null;}
  function letter(el){var from=attr(el,['from','sender','author']);return {title:from?fill(L.letterFrom,'from',from):L.letter,date:attr(el,['date','time'])};}
  define('dsh-letter','[part~=card]{background:var(--dsh-letter-paper,rgba(232,211,166,.24));line-height:1.75;}',function(el){
    var x=letter(el);
    return '<div part="card paper"><div part="head" aria-hidden="true"><span part="title">'+esc(x.title)+'</span>'+(x.date?'<span part="meta">'+esc(x.date)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  },function(el){var x=letter(el);return ['group',named([x.title,x.date])];});
  define('dsh-item','[part~=card]{display:flex;gap:12px;align-items:flex-start;padding:10px 14px 10px 12px;}[part~=icon]{width:34px;height:34px;border-radius:10px;background:var(--dsh-item-icon,rgba(127,127,127,.14));display:flex;align-items:center;justify-content:center;flex:none;}[part~=name]{font-weight:600;}[part~=taken]{margin-left:8px;font-size:.75em;padding:1px 7px;border-radius:6px;background:var(--dsh-item-taken,rgba(60,160,90,.18));}[part~=body]{margin-top:2px;font-size:.88em;color:var(--dsh-muted);}',function(el){
    var name=attr(el,['name','title']);var taken=el.hasAttribute('take')||el.hasAttribute('taken');
    return '<div part="card item"><div part="icon" aria-hidden="true">✦</div><div><div aria-hidden="true"><span part="name">'+esc(name||'')+'</span>'+(taken?'<span part="taken">'+esc(L.taken)+'</span>':'')+'</div><div part="body"><slot></slot></div></div></div>';
  },function(el){
    var taken=el.hasAttribute('take')||el.hasAttribute('taken');
    return ['group',named([attr(el,['name','title']),taken?L.taken:null])];
  });
  define('dsh-clue',':host{transform:rotate(-.7deg);}[part~=card]{background:var(--dsh-clue-note,rgba(245,215,110,.28));}',function(el){
    var title=attr(el,['title','name']);
    return '<div part="card note"><div part="head" aria-hidden="true"><span part="title">'+esc(title||L.clue)+'</span></div><div part="body"><slot></slot></div></div>';
  },function(el){return ['group',attr(el,['title','name'])||L.clue];});
  define('dsh-phone','[part~=card]{max-width:360px;}[part~=bubble]{margin-top:8px;padding:8px 12px;border-radius:4px 14px 14px 14px;background:var(--dsh-phone-bubble,rgba(127,127,127,.14));}',function(el){
    var x=phone(el);
    return '<div part="card phone"><div part="head" aria-hidden="true"><span part="title">'+esc(x.title)+'</span>'+(x.time?'<span part="meta">'+esc(x.time)+'</span>':'')+'</div><div part="bubble"><slot></slot></div></div>';
  },function(el){var x=phone(el);return ['group',named([x.title,x.time])];});
  function phone(el){var from=attr(el,['from','sender','name']);return {title:from?fill(L.phoneFrom,'from',from):L.phone,time:attr(el,['time','date'])};}
  function roll(el){
    var skill=attr(el,['skill','check','name','title']);var value=attr(el,['value','roll','score']);var target=attr(el,['target','dc','difficulty','against']);var result=attr(el,['result','outcome']);
    var r=(result||'').toLowerCase();var ok=/^(success|pass|passed|succeeded|成功|大成功|通过)\$/.test(r);var bad=/^(fail|failure|failed|失败|大失败)\$/.test(r);
    return {title:skill?fill(L.rollCheck,'skill',skill):L.roll,score:[value,target].filter(function(x){return x;}).join(' / '),
      label:ok?L.success:(bad?L.failure:result),ok:ok,bad:bad};
  }
  define('dsh-roll','[part~=head]{align-items:center;}[part~=score]{font-variant-numeric:tabular-nums;}[part~=result]{font-weight:700;}.ok{color:var(--dsh-success,#2f8a4c);}.bad{color:var(--dsh-danger,#c0392b);}[part~=body]{margin-top:4px;font-size:.8em;color:var(--dsh-muted);}',function(el){
    var x=roll(el);
    return '<div part="card roll"><div part="head" aria-hidden="true"><span part="title">'+esc(x.title)+'</span>'+(x.score?'<span part="score">'+esc(x.score)+'</span>':'')+(x.label?'<span part="result" class="'+(x.ok?'ok':x.bad?'bad':'')+'">'+esc(x.label)+'</span>':'')+'</div><div part="body"><slot></slot></div></div>';
  },function(el){var x=roll(el);return ['group',named([x.title,x.score,x.label])];});
  define('dsh-notice',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '<slot></slot>';},function(){return ['note',null];});
  define('dsh-game',':host{text-align:center;font-size:.85em;color:var(--dsh-muted);}',function(){return '<span aria-hidden="true">▷ </span>'+esc(L.game);},function(){return ['note',null];});
  // A card's own scripts (its 角色脚本库, docs/design/roleplay-compat.md §8.3):
  // each in a hidden frame of its own, as a module, with this page's helpers
  // on its global — this page's \$ too, which is how a script reaches the
  // story — and named dsh-script-<n>.js, so what it defines knows which
  // script it is (getScriptId, getScriptName, getIframeName).
  var cardScripts=$cardScriptsJson,scriptsStarted=false;
  var shared=['getVariables','replaceVariables','updateVariablesWith','insertOrAssignVariables','insertVariables',
    'deleteVariable','getChatMessages','setChatMessages','createChatMessages','deleteChatMessages','rotateChatMessages',
    'eventOn','eventOnce','eventRemoveListener','eventEmit','tavern_events','iframe_events','getLastMessageId',
    'getCurrentMessageId','getIframeName','getMessageId','toastr','injectPrompts','uninjectPrompts','generate',
    'generateRaw','stopGenerationById','stopAllGeneration','getScriptId','getScriptName','getButtonEvent',
    'eventMakeFirst','eventMakeLast','eventEmitAndWait','eventClearEvent','eventClearListener','eventClearAll',
    'retrieveDisplayedMessage','renderOneMessage','SillyTavern','getCurrentCharacterName','getCurrentCharacterId',
    'getCharacter','getCharData','getCharAvatarPath','getPersonaNames','getPersonaIds','getCurrentPersonaName',
    'getCurrentPersonaId','getPersona','getPersonaAvatarPath','playAudio','pauseAudio','getCurrentAudio',
    'getAudioList','replaceAudioList','appendAudioList','getAudioSettings','setAudioSettings','triggerSlash','getTavernRegexes',
    '\$','jQuery','_','dsh'];
  function callerScript(){
    var limit=Error.stackTraceLimit;Error.stackTraceLimit=200;
    var stack=String(new Error().stack||'');Error.stackTraceLimit=limit;
    var k=/dsh-script-(\\d+)\\.js/.exec(stack);
    return k&&cardScripts[+k[1]]||null;
  }
  function scriptById(id){for(var i=0;i<cardScripts.length;i++)if(cardScripts[i].id===id)return cardScripts[i];return null;}
  function getScriptId(){var s=callerScript();if(!s)throw new Error('getScriptId: not called from a card script');return s.id;}
  function getScriptName(){var s=callerScript();if(!s)throw new Error('getScriptName: not called from a card script');return s.name;}
  // The event a script's button sends when pressed; the buttons themselves
  // are the app's (above the composer).
  function getButtonEvent(name){var s=callerScript();return 'dsh_button__'+(s?s.id:'')+'__'+String(name);}
  [['getScriptId',getScriptId],['getScriptName',getScriptName],['getButtonEvent',getButtonEvent]].forEach(function(f){
    dsh.scripts[f[0]]=f[1];if(!window[f[0]])window[f[0]]=f[1];
  });
${tavernCanvasHelpersJs(mvu: mvu)}
  // MVU (when the card uses it) is on for this chat and Mvu shared before
  // any of them runs.
  function runCardScripts(){mvuStart().then(startCardScripts);}
  function startCardScripts(){
    cardScripts.forEach(function(s,n){
      var frame=document.createElement('iframe');
      frame.style.display='none';frame.setAttribute('aria-hidden','true');frame.dataset.script=s.id;
      // Its own variables first, so getVariables({type:'script'}) reads them
      // at once (or as none, should they not come).
      var own=call('getVariables',{target:{scope:'script',scriptOwner:{kind:'character',scriptId:s.id}}})
        .then(setVar,function(){});
      frame.onload=function(){
        var w=frame.contentWindow;if(!w)return;
        shared.forEach(function(k){if(window[k]!==undefined)w[k]=window[k];});
        own.then(function(){
          var el=w.document.createElement('script');el.type='module';
          el.textContent=withoutMvuImport(s.content)+'\\n//# sourceURL=dsh-script-'+n+'.js';
          w.document.head.appendChild(el);
        });
      };
      // Head and body come of themselves; no closing tags in our script.
      frame.srcdoc='<!doctype html><meta charset="utf-8">';
      document.body.appendChild(frame);
    });
  }
  post({type:'ready'});
  // The app's player learns there is a page to play on, music or not.
  audioReport();
})();
</script></body></html>''';
}
