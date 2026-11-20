// What keeps a card's heavy pages light on a phone: on 整页画布, messages
// out of sight skipped and paused.

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
