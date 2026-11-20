// What keeps a card's heavy pages light on a phone (整页画布 and islands):
// messages out of sight skipped and paused, 酒馆设置 › 显示 › 省电渲染's calmer
// styles, and an opt-in frame log for measuring on a device.

/// The frame log: built with `--dart-define=DSH_TAVERN_PERF=true`, the canvas
/// and each island count their frames, and every 5 s the app prints a
/// `[tavern-perf]` line ([tavernPerfLine]), which `adb logcat` shows.
const tavernPerfLog = bool.fromEnvironment('DSH_TAVERN_PERF');

/// 省电渲染's CSS: no backdrop blur anywhere, a card's `!important` too.
const tavernCalmCss = '*,*::before,*::after{-webkit-backdrop-filter:none!important;backdrop-filter:none!important;}';

/// 省电渲染's pass over the page's styles, `dshCalm(root)`: in each style sheet
/// not seen yet (keyframes and @media inside too) and in the inline styles
/// under [root] (the whole page when none), backdrop blur goes, a filter's
/// blur() goes (its other functions stay) and an endless animation plays once.
const tavernCalmJs = r'''
function dshCalm(root){
  var seen=dshCalm.seen||(dshCalm.seen=new WeakSet());
  function fix(s){
    if(s.backdropFilter&&s.backdropFilter!=='none')s.backdropFilter='none';
    if(/blur\(/.test(s.filter))s.filter=s.filter.replace(/blur\([^)]*\)/g,'').trim()||'none';
    if(/infinite/.test(s.animationIterationCount))s.animationIterationCount=s.animationIterationCount.replace(/infinite/g,'1');
  }
  function rules(list){for(var i=0;i<list.length;i++){var r=list[i];if(r.style)fix(r.style);if(r.cssRules)rules(r.cssRules);}}
  [].forEach.call(document.styleSheets,function(sheet){
    if(seen.has(sheet))return;seen.add(sheet);
    // Another origin's (a web font's) cannot be read.
    try{rules(sheet.cssRules);}catch(e){}
  });
  [].forEach.call((root||document).querySelectorAll('[style*="blur"],[style*="infinite"]'),function(el){fix(el.style);});
}
''';

/// The canvas's hold on a message's own page styles, `dshScope(m)`: a card or
/// preset page written for a frame of its own styles `html`, `body` and
/// `:root`; on the canvas they would reach the whole chat (its
/// `body{overflow:hidden}` stopping the chat from scrolling). In each style
/// sheet under [m] (a message, or its text) not seen yet, those selectors are
/// made the message's text.
const tavernScopeJs = r'''
function dshScope(m){
  var box=m.classList.contains('mes_text')?m:m.querySelector('.mes_text');if(!box)return;
  var seen=dshScope.seen||(dshScope.seen=new WeakSet());
  var id=box.dataset.dshScope||(box.dataset.dshScope=String(dshScope.next=(dshScope.next||0)+1));
  var at='.mes_text[data-dsh-scope="'+id+'"]';
  // The page's root, as an element name (not a ::part(body) argument), and
  // `html body` / `html > body` / `:root body`, which are one root here.
  var chain=/(^|[\s,>+~(])(?:html|:root)\s*>?\s*(?=body(?![\w-]))/gi;
  var top=/(^|[\s,>+~]|(?<!::part)\()(?:html|body|:root)(?=$|[\s,>+~.#:\[)])/gi;
  function rules(list){
    for(var i=0;i<list.length;i++){
      var r=list[i],sel=r.selectorText;
      if(sel){
        var scoped=sel.replace(chain,'$1').replace(top,'$1'+at);
        if(scoped!==sel)r.selectorText=scoped;
      }
      if(r.cssRules)rules(r.cssRules);
    }
  }
  [].forEach.call(box.querySelectorAll('style'),function(s){
    if(!s.sheet||seen.has(s.sheet))return;seen.add(s.sheet);
    try{rules(s.sheet.cssRules);}catch(e){}
  });
}
''';

/// The canvas's watch on its messages, `dshOffscreen()`: one
/// IntersectionObserver, a screen's margin above and below. A message out of
/// that is marked `dsh-off` (the page's CSS skips drawing it and pauses its
/// animations), and its playing video and audio pause, to go on when it is
/// back. [watch] (m, tail): a tail message (the latest, for scrolling to the
/// bottom) is always drawn; a message not heard of yet counts as out of sight.
const tavernOffscreenJs = r'''
function dshOffscreen(){
  var io=new IntersectionObserver(function(es){
    es.forEach(function(e){e.target._dshIn=e.isIntersecting;place(e.target);});
  },{rootMargin:'100% 0px'});
  function place(m){
    var off=!m._dshTail&&!m._dshIn;
    if(m.classList.contains('dsh-off')===off)return;
    m.classList.toggle('dsh-off',off);
    [].forEach.call(m.querySelectorAll('video,audio'),function(v){
      if(off){if(!v.paused){v.pause();v._dshPaused=true;}}
      else if(v._dshPaused){v._dshPaused=false;v.play().catch(function(){});}
    });
  }
  return {
    watch:function(m,tail){m._dshTail=tail;if(!m._dshWatched){m._dshWatched=true;io.observe(m);}place(m);},
    unwatch:function(m){m._dshWatched=false;io.unobserve(m);}
  };
}
''';

/// The frame log's counter, `dshPerf(post, more)`: frames by
/// requestAnimationFrame, those over 50 ms long, the longest; every 5 s
/// posted as {type:'perf', span, frames, long, worst} with what [more]
/// adds. Nothing is posted for a span with no frames (the page out of
/// sight), and a gap over a second is a pause, not a frame.
const tavernPerfJs = r'''
function dshPerf(post,more){
  var frames=0,long=0,worst=0,last=0,from=performance.now();
  function tick(t){
    var d=t-last;
    if(last&&d<1000){frames++;if(d>50)long++;if(d>worst)worst=d;}
    last=t;requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);
  setInterval(function(){
    var now=performance.now();
    if(frames)post(Object.assign({type:'perf',span:Math.round(now-from),frames:frames,long:long,worst:Math.round(worst)},more()));
    frames=long=worst=0;from=now;
  },5000);
}
''';

/// One `[tavern-perf]` line for a page's report ([tavernPerfJs]): [page]
/// names it (canvas, or an island's id).
String tavernPerfLine(String page, Map<Object?, Object?> data, {required bool lowPower}) {
  int n(String key) => switch (data[key]) {
    final num v => v.round(),
    _ => 0,
  };
  final span = n('span');
  final fps = span == 0 ? 0 : n('frames') * 1000 / span;
  final messages = data.containsKey('mes') ? ' mes=${n('mes')} off=${n('off')}' : '';
  return '[tavern-perf] $page ${(span / 1000).toStringAsFixed(1)}s frames=${n('frames')} '
      'fps=${fps.toStringAsFixed(1)} long=${n('long')} worst=${n('worst')}ms$messages lowPower=$lowPower';
}
