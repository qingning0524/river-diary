/* ============ 河流回放 · 全屏回忆回放 ============ */
function riverColorStage(e){ return (e.stage && e.stage.color) || '#9B8CFF'; }
var _rpTimer = null;
function rpEl(id){ return document.getElementById(id); }

function openRiverReplay(){
  var ov = rpEl('replay'), scene = rpEl('replayScene');
  if(!ov || !scene || !ENTRIES.length) return;
  var reduced = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  var days = ENTRIES.slice().reverse(); // 从最近往回走
  function stageHtml(e){
    var c = riverColorStage(e), m = e.metrics || {};
    var txt = (e.overview && e.overview.indexOf('无数据')<0) ? esc(e.overview)
            : ((e.mood && e.mood.indexOf('无数据')<0) ? esc(e.mood) : '这一天没有留下文字。');
    function cell(k,lab){ var v=m[k]; return v==null?'':('<div class="rp-cell"><b>'+v+'</b><span>'+lab+'</span></div>'); }
    var moodC = e.score==null
      ? '<div class="rp-cell"><b>—</b><span>心情</span></div>'
      : '<div class="rp-cell mood"><b>'+e.score+'</b><span>心情'+(e.score_source==='ai'?' · 推断':'')+'</span></div>';
    return '<article class="rp-stage" style="--rp:'+c+'" data-date="'+esc(e.date)+'" tabindex="0" role="button" aria-label="打开'+fmtFull(e.date)+'的日记">'
      +'<span class="rp-badge">'+(e.stage?esc(e.stage.label):'')+'</span>'
      +'<div class="rp-date">'+fmtFull(e.date)+'</div>'
      +'<div class="rp-weekday">'+fmtW(e.date)+'</div>'
      +'<div class="rp-line"></div>'
      +'<p class="rp-overview">'+txt+'</p>'
      +'<div class="rp-mini">'+moodC+cell('energy','精力')+cell('focus','专注')+cell('output','产出')+cell('overall','综合')+'</div>'
      +'<div class="rp-enter">⇲ 点卡片 · 打开当天日记</div>'
      +'</article>';
  }
  scene.innerHTML = days.map(stageHtml).join('');
  if(!scene._rpOpen){ scene._rpOpen = 1;
    scene.addEventListener('click', function(ev){
      var t = ev.target;
      while(t && t !== scene){
        if(t.classList && t.classList.contains('rp-stage') && t.getAttribute('data-date')){ openRiverDay(t.getAttribute('data-date')); return; }
        t = t.parentNode;
      }
    });
    scene.addEventListener('keydown', function(ev){
      if(ev.key !== 'Enter' && ev.key !== ' ') return;
      var t = ev.target;
      if(t && t.classList && t.classList.contains('rp-stage') && t.getAttribute('data-date')){
        ev.preventDefault();
        openRiverDay(t.getAttribute('data-date'));
      }
    });
  }
  ov._days = days;
  ov._rp_i = days.length-1;
  ov._reduced = reduced;
  ov.classList.add('show');
  refreshOverlayLock();
  ov._focus = document.activeElement;
  var closeBtn = rpEl('replayClose'); if(closeBtn) closeBtn.focus();
  rpRender(ov._rp_i);
  rpPlay(!reduced);
}

function openRiverDay(date){
  if(!BYDATE[date]) return;
  rpClose();
  state.dcat = 'memos';
  if(state.date === date){ renderDiary(); }
  else { setDate(date, false); }
  setTimeout(function(){ scrollToId('detailCard'); }, 160);
}

function rpRender(i){
  var ov = rpEl('replay'); if(!ov || !ov._days) return;
  var l = ov._days.length;
  ov._rp_i = ((i % l) + l) % l;
  var stages = ov.querySelectorAll('.rp-stage');
  for(var k=0;k<stages.length;k++) stages[k].classList.toggle('on', k===ov._rp_i);
  var e = ov._days[ov._rp_i], cnt = rpEl('replayCount');
  if(cnt) cnt.textContent = (ov._rp_i+1)+' / '+l;
  var bg = rpEl('replayBg'); if(bg) bg.style.setProperty('--rp', riverColorStage(e));
  rpRestart();
}
function rpGo(d){ var ov=rpEl('replay'); if(!ov||!ov._days) return; rpRender(ov._rp_i + d); }

function rpRestart(){
  var ov = rpEl('replay'), fill = rpEl('replayFill'), t = rpEl('replayToggle');
  var auto = !!(ov && ov._playing && !ov._reduced);
  clearInterval(_rpTimer);
  if(auto){
    if(fill){ fill.style.transition='none'; fill.style.width='0';
      requestAnimationFrame(function(){ fill.style.transition='width 4.4s linear'; fill.style.width='100%'; }); }
    _rpTimer = setInterval(function(){ rpGo(1); }, 4600);
  } else {
    if(fill){ fill.style.transition='none'; fill.style.width='0'; }
  }
  if(t){ t.innerHTML = auto
      ? '<svg viewBox="0 0 24 24"><path d="M7 5h3v14H7zM14 5h3v14h-3z" fill="currentColor"/></svg>'
      : '<svg viewBox="0 0 24 24"><path d="M7 5v14l11-7z" fill="currentColor"/></svg>'; }
}
function rpPlay(on){ var ov=rpEl('replay'); if(ov){ ov._playing=!!on; rpRestart(); } }
function rpClose(){
  clearInterval(_rpTimer);
  var ov=rpEl('replay');
  if(ov){
    ov.classList.remove('show');
    var back=ov._focus; if(back && back.focus) back.focus(); ov._focus=null;
  }
  refreshOverlayLock();
}

(function(){
  function bind(){
    var prev=rpEl('replayPrev'), next=rpEl('replayNext'), tog=rpEl('replayToggle'),
        close=rpEl('replayClose'), ov=rpEl('replay');
    if(prev) prev.onclick=function(){ rpGo(-1); };
    if(next) next.onclick=function(){ rpGo(1); };
    if(tog) tog.onclick=function(){ var o=rpEl('replay'); if(o) rpPlay(!o._playing); };
    if(close) close.onclick=rpClose;
    if(ov) ov.addEventListener('click', function(ev){ if(ev.target===ov) rpClose(); });
    document.addEventListener('keydown', function(ev){
      var o=rpEl('replay');
      if(!o || !o.classList.contains('show')) return;
      if(ev.key==='Escape') rpClose();
      else if(ev.key==='Tab') trapDialogFocus(o, ev);
      else if(ev.key==='ArrowLeft') rpGo(-1);
      else if(ev.key==='ArrowRight') rpGo(1);
      else if(ev.key===' '){ rpPlay(!o._playing); ev.preventDefault(); }
    });
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();
})();
