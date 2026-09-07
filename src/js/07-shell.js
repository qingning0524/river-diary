(function(){
  var saved = null;
  try{ saved = localStorage.getItem('diary-theme'); }catch(e){}
  var prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  if(saved === 'dark' || (!saved && prefersDark)){ document.documentElement.setAttribute('data-theme','dark'); }
  var ICON_SUN='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19"/></svg>';
  var ICON_MOON='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z"/></svg>';
  function apply(persist){
    if(persist === undefined) persist = true;
    var on = document.documentElement.getAttribute('data-theme') === 'dark';
    if(persist){ try{ localStorage.setItem('diary-theme', on ? 'dark' : 'light'); }catch(e){} }
    var b = document.getElementById('themeBtn');
    if(b) b.innerHTML = on ? ICON_SUN : ICON_MOON;
    if(b) b.setAttribute('aria-pressed', on ? 'true' : 'false');
  }
  var tb = document.getElementById('themeBtn');
  if(tb){ tb.onclick = function(){
    var on = document.documentElement.getAttribute('data-theme') === 'dark';
    if(on){ document.documentElement.removeAttribute('data-theme'); }
    else{ document.documentElement.setAttribute('data-theme','dark'); }
    apply();
  }; }
  apply(false);

  // 演示模式：隐藏好友姓名（录视频前开启）
  try{ if(localStorage.getItem('diary-privacy') === '0') state.privacy = false; }catch(e){}
  var pb = document.getElementById('privacyBtn');
  function paintPrivacy(){
    if(pb) pb.innerHTML = state.privacy
      ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>'
      : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.3 3.8 5.2 3.8 8.5s-1.3 6.2-3.8 8.5c-2.5-2.3-3.8-5.2-3.8-8.5s1.3-6.2 3.8-8.5z"/></svg>';
    if(pb) pb.title = state.privacy ? '演示模式已开启：好友姓名已隐藏（点击显示）' : '演示模式已关闭（点击隐藏姓名）';
    if(pb) pb.setAttribute('aria-pressed', state.privacy ? 'true' : 'false');
    try{ localStorage.setItem('diary-privacy', state.privacy ? '1' : '0'); }catch(e){}
  }
  if(pb){ pb.onclick = function(){ state.privacy = !state.privacy; paintPrivacy(); renderDataPanel(); }; }
  paintPrivacy();

  // 侧边导航：点击后滚动到对应区块
  document.querySelectorAll('.rail-btn[data-scroll]').forEach(function(btn){
    if(!btn.hasAttribute('aria-label')) btn.setAttribute('aria-label', btn.getAttribute('data-tip'));
    btn.onclick = function(){ scrollToId(btn.getAttribute('data-scroll')); };
  });
  var railTop = document.getElementById('railTop'), railTopBtn = document.getElementById('railTopBtn');
  function toTop(){ window.scrollTo({top:0, behavior:'smooth'}); }
  if(railTop){ railTop.addEventListener('click', function(ev){ ev.preventDefault(); toTop(); }); }
  if(railTopBtn){ railTopBtn.addEventListener('click', toTop); }

  // 滚动高亮：当前所在区块对应的导航按钮点亮
  var spyTargets = ['detailSecTitle','diarySecTitle','riverCard','historySecTitle','dataSecTitle'];
  var topEl = document.querySelector('.top');
  // 顶栏压缩 + 阅读进度条
  function onScroll(){
    var y = window.scrollY || window.pageYOffset;
    if(topEl) topEl.classList.toggle('is-scrolled', y > 24);
    // 进度条：滚动量 / (文档总高 - 视口高)，最大 1
    var doc = document.documentElement;
    var max = (doc.scrollHeight - doc.clientHeight) || 1;
    var p = Math.max(0, Math.min(1, y / max));
    if(topEl) topEl.style.setProperty('--read', p);
  }
  function railSpy(){
    var pos = window.scrollY + 120;
    var cur = spyTargets[0];
    for(var i=0;i<spyTargets.length;i++){
      var el = document.getElementById(spyTargets[i]);
      if(el && el.getBoundingClientRect().top + window.scrollY <= pos) cur = spyTargets[i];
    }
    document.querySelectorAll('.rail-btn[data-scroll]').forEach(function(b){
      b.classList.toggle('on', b.getAttribute('data-scroll')===cur);
    });
    onScroll();
  }
  window.addEventListener('scroll', railSpy, {passive:true});
  window.addEventListener('resize', railSpy);
  railSpy();

  // 视口触发的淡入：给 main 下的直接子节点加 .reveal，进入视口后加 .is-visible
  if('IntersectionObserver' in window && !window.matchMedia('(prefers-reduced-motion: reduce)').matches){
    var io = new IntersectionObserver(function(items){
      items.forEach(function(it){
        if(it.isIntersecting){
          it.target.classList.add('is-visible');
          io.unobserve(it.target);
        }
      });
    }, {rootMargin:'-8% 0px -8% 0px', threshold:0.05});
    document.querySelectorAll('main.anim > *').forEach(function(el, i){
      el.classList.add('reveal');
      el.setAttribute('data-d', String(Math.min(i, 4)));
      io.observe(el);
    });
  }

  // 移动端 FAB 搜索：<780px 浮按钮 → 弹出全屏搜索表
  if(window.matchMedia && window.matchMedia('(max-width:780px)').matches){
    var fab = document.createElement('button');
    fab.className = 'fab-search';
    fab.setAttribute('aria-label','搜索');
    fab.innerHTML = '🔍';
    var sheet = document.createElement('div');
    sheet.className = 'search-sheet';
    sheet.setAttribute('role', 'dialog');
    sheet.setAttribute('aria-modal', 'true');
    sheet.setAttribute('aria-label', '搜索日记');
    sheet.innerHTML = '<div class="search-sheet-head">'
      +'<input type="search" placeholder="搜索日记…" autocomplete="off" />'
      +'<button class="close" aria-label="关闭">✕</button>'
      +'</div><div class="results"></div>';
    document.body.appendChild(fab);
    document.body.appendChild(sheet);
    var inp = sheet.querySelector('input');
    var list = sheet.querySelector('.results');
    function openSheet(){ sheet.classList.add('show'); refreshOverlayLock(sheet); setTimeout(function(){ inp.focus(); }, 50); }
    function closeSheet(){ sheet.classList.remove('show'); refreshOverlayLock(); }
    function doSearch(q){
      list.innerHTML = '';
      if(!q || !q.trim()) return;
      var ql = q.toLowerCase();
      var previousQ = state.q;
      state.q = ql;
      var hits = applyFilters().slice(-20).reverse();
      state.q = previousQ;
      if(!hits.length){ list.innerHTML = '<div class="res" style="cursor:default"><i>没找到匹配的日记</i></div>'; return; }
      list.innerHTML = hits.map(function(e){
        return '<div class="res" data-date="'+e.date+'" tabindex="0" role="button" aria-label="打开'+fmtFull(e.date)+'的日记"><b>'+esc(fmtFull(e.date))+' · '+(e.score==null?'待评分':e.score)+'</b><i>'+esc((e.title||e.overview||'').slice(0,60))+'</i></div>';
      }).join('');
      Array.prototype.forEach.call(list.querySelectorAll('.res'), function(n){
        n.addEventListener('click', function(){
          if(n.dataset.date){ setDate(n.dataset.date, true); closeSheet(); }
        });
        n.addEventListener('keydown', function(ev){
          if(ev.key !== 'Enter' && ev.key !== ' ') return;
          ev.preventDefault();
          n.click();
        });
      });
    }
    fab.addEventListener('click', openSheet);
    sheet.querySelector('.close').addEventListener('click', closeSheet);
    inp.addEventListener('input', function(){ doSearch(inp.value); });
    sheet.addEventListener('click', function(ev){ if(ev.target===sheet) closeSheet(); });
    document.addEventListener('keydown', function(ev){
      if(!sheet.classList.contains('show')) return;
      if(ev.key === 'Escape') closeSheet();
      if(ev.key === 'Tab') trapDialogFocus(sheet, ev);
    });
  }

})();
