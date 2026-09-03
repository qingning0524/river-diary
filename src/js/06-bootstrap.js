/* ================= 主流程 ================= */
function renderDataPanel(){
  var d = state.dtab;
  var m = $('dMood'), sp = $('dSocialPanel'), lp = $('dLawPanel'), rv = $('dReviewPanel'), mh = $('dMoodHead');
  if(m) m.style.display = (d==='mood'||d==='screen'||d==='browse') ? '' : 'none';
  if(sp) sp.style.display = (d==='social') ? '' : 'none';
  if(lp) lp.style.display = (d==='law') ? '' : 'none';
  if(rv) rv.style.display = (d==='review') ? '' : 'none';
  if(mh) mh.style.display = (d==='mood') ? '' : 'none';
  var hasSocial = DATA.social && Object.keys(DATA.social).length;
  var sb = document.querySelector('.ctab[data-dtab="social"]');
  if(sb) sb.style.display = hasSocial ? '' : 'none';
  var eb = $('exportBtn');
  if(eb) eb.style.display = (d==='social'||d==='law'||d==='review') ? 'none' : '';
  [].slice.call(document.querySelectorAll('.ctab[data-dtab]')).forEach(function(b){
    b.classList.toggle('on', b.dataset.dtab===d);
    b.setAttribute('aria-selected', b.dataset.dtab===d ? 'true' : 'false');
  });
  if(d==='mood'){ state.tab='score'; renderChips(); renderChart(); }
  else if(d==='screen'){ state.tab='screen'; renderChart(); }
  else if(d==='browse'){ state.tab='browse'; renderChart(); }
  else if(d==='social'){ renderSocial(); }
  else if(d==='law'){ renderAnalytics(); }
  else if(d==='review'){ renderReview(); }
}

window.renderMain = function(){
  renderRiver(); renderDetail(); renderDiary(); renderDataPanel();
  renderHistory();
};

function bind(){
  $('searchInput').addEventListener('input', function(){ state.q=this.value; renderHistory(); });
  $('stageFilter').addEventListener('change', function(){ state.stage=this.value; renderAnalytics(); renderHistory(); });
  $('tagFilter').addEventListener('change', function(){ state.tag=this.value; renderAnalytics(); renderHistory(); });
  var mf=$('monthFilter');
  if(mf) mf.addEventListener('change', function(){ state.month=this.value; renderHistory(); });
  $('exportBtn').onclick=exportMd;
  [].slice.call(document.querySelectorAll('.ctab[data-tab]')).forEach(function(b){
    b.onclick=function(){ state.tab=b.dataset.tab; renderChart(); };
  });
  [].slice.call(document.querySelectorAll('.ctab[data-stab]')).forEach(function(b){
    b.onclick=function(){
      state.stab=b.dataset.stab;
      [].slice.call(document.querySelectorAll('.ctab[data-stab]')).forEach(function(x){ x.classList.toggle('on', x===b); });
      [].slice.call(document.querySelectorAll('.ctab[data-stab]')).forEach(function(x){ x.setAttribute('aria-selected', x===b ? 'true' : 'false'); });
      renderSocial();
    };
  });
  [].slice.call(document.querySelectorAll('.ctab[data-dtab]')).forEach(function(b){
    b.onclick=function(){ state.dtab=b.dataset.dtab; renderDataPanel(); };
  });
  var sc=$('scoreModalClose'), so=$('scoreModal');
  if(sc) sc.onclick=closeScoreHelp;
  if(so) so.addEventListener('click', function(ev){ if(ev.target===so) closeScoreHelp(); });
  var sb=$('shareBtn');
  if(sb) sb.onclick=function(){
    var url = location.href.split('#')[0] + '#date='+(state.date||'')+'&tab='+(state.dcat||'overview');
    if(navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(url).then(function(){ toast('已复制分享链接'); }, function(){ toast('复制失败，请手动复制地址栏'); });
    } else { toast('复制失败，请手动复制地址栏'); }
  };
  document.addEventListener('keydown', function(ev){
    if(ev.key==='Escape'){ closeScoreHelp(); return; }
    var tag=ev.target.tagName; if(tag==='INPUT'||tag==='SELECT'||tag==='TEXTAREA') return;
    if(ev.metaKey||ev.ctrlKey||ev.altKey) return;
    if(ev.key==='ArrowLeft'){ var p=prevEntry(state.date); if(p) setDate(p.date,false); }
    if(ev.key==='ArrowRight'){ var n=nextEntry(state.date); if(n) setDate(n.date,false); }
    if(ev.key==='/'){ ev.preventDefault(); var s=document.getElementById('searchInput'); if(s){ s.focus(); s.select(); } }
    if(ev.key==='d' || ev.key==='D'){ var tb=document.getElementById('themeBtn'); if(tb) tb.click(); }
    if(ev.key==='?'){ ev.preventDefault(); openScoreHelp(); }
  });
  // 快捷键提示（hover 顶栏 logo 显示）
  var brand = document.querySelector('.top-brand');
  if(brand){ brand.title = '快捷键：← → 切日期 · / 搜索 · D 切深色'; }
  window.addEventListener('hashchange', function(){
    var m=location.hash.match(/date=(\d{4}-\d{2}-\d{2})/);
    var mt=location.hash.match(/tab=([a-z][a-z-]*)/);
    var VALID_DCAT = ['overview','thoughts','memos','learn-work','fun-rest','health','plan','meta'];
    var nextDate = m && BYDATE[m[1]] ? m[1] : state.date;
    var nextTab = mt && VALID_DCAT.indexOf(mt[1])>-1 ? mt[1] : state.dcat;
    if(nextDate !== state.date || nextTab !== state.dcat){
      state.date = nextDate;
      state.dcat = nextTab;
      renderMain();
    }
  });
}

/* ============ 启动：内联数据优先，否则 fetch data/data.json ============ */
function setData(d){
  DATA = d;
  ENTRIES = d.entries || [];
  try{
    var pendingScores = JSON.parse(localStorage.getItem('diary-pending-scores') || '{}');
    if(!pendingScores || typeof pendingScores !== 'object' || Array.isArray(pendingScores)) pendingScores = {};
    ENTRIES.forEach(function(e){
      var v = pendingScores[e.date];
      if(typeof v === 'number' && v >= 0 && v <= 100){ e.score = v; e.score_source = 'user'; }
    });
  }catch(err){}
  BYDATE = {};
  ENTRIES.forEach(function(e){
    (e.browse_sites||[]).forEach(function(site){
      site.site = cleanSiteName(site.site);
      var count = Number(site.n != null ? site.n : site.count);
      site.n = isFinite(count) ? count : 0;
    });
    BYDATE[e.date] = e;
  });
  TODAY = d.today || '';
  var err = document.getElementById('loadError');
  if(err) err.style.display = 'none';
  initState();
  // 首屏默认打开当天随笔小记（亲手记录优先展示）；显式 tab= 参数优先
  // 修复 BUG：原正则 /tab=([a-z]+)/ 匹配不到带连字符的页签 key（如 learn-work / fun-rest），
  //           导致 #date=…&tab=learn-work 这类深链被当成"无 tab 参数"，被默认覆盖成 memos。
  //           改为匹配含连字符的 key，并按合法 key 校验，深链页签才能真正定位。
  // 另修复：原来按下拉最新一篇（ENTRIES 最后一篇）有没有随笔来决定"默认开随笔"，
  //         但深链跳到更早的无随笔日期时，仍会把 dcat 覆盖成 memos → 无页签高亮。
  //         改为按"当前选中日期 state.date"自查，选中日期没随笔就保持默认 overview。
  var se = BYDATE[state.date];
  var mtab = location.hash.match(/tab=([a-z][a-z-]*)/);
  var VALID_DCAT = ['overview','thoughts','memos','learn-work','fun-rest','health','plan','meta'];
  if(!(mtab && VALID_DCAT.indexOf(mtab[1])>-1) && se && (se.memos||[]).some(function(x){ return x && x.indexOf('无数据')<0; })) state.dcat = 'memos';
  renderHeader();
  bind();
  renderMain();
  window.scrollTo(0, 0);
}
function boot(){
  var err = document.getElementById('loadError');
  var inline = document.getElementById('diary-data');
  if(inline && inline.textContent.trim()){
    try{ setData(JSON.parse(inline.textContent)); return; }
    catch(e){ console.warn('内联数据解析失败，尝试加载 data.json', e); }
  }
  fetch(DATA_URL, {cache:'no-store'})
    .then(function(r){ if(!r.ok) throw new Error('HTTP '+r.status); return r.json(); })
    .then(setData)
    .catch(function(e){
      console.error('数据加载失败:', e);
      if(err){
        err.style.display = 'block';
        err.textContent = '⚠️ 无法加载数据（data/data.json）。请用本地服务器访问：在项目目录运行 python3 -m http.server，或先运行 python3 build.py 生成可直接双击打开的单文件版。';
      }
    });
}
boot();


/* ============ 深色模式 + 侧边导航 ============ */
