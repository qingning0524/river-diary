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

  /* ============ V3 美化层 ============ */

  // 工具：View Transitions API 包装器
  // 修复：之前 setDate / dnav-btn 的 VT 包装都是注释（line 1618-1628），完全失效
  // 现在用 _v3Wrap 统一包裹所有需要"切换有动画"的渲染调用
  // ⚠️ 修复 BUG：_v3Wrap 原来只在本 IIFE 内可见（function 声明是局部变量），
  //    而全局 setDate()（line 180）与 renderDiary()（line 500/506）都要调用它，
  //    导致 dnav-btn 切换页签时抛 "ReferenceError: _v3Wrap is not defined"，切页签完全失效。
  //    修法：把它挂到 window 上，全局调用点才能拿到。
  var _vtSupported = typeof document.startViewTransition === 'function';
  function _v3Wrap(fn){
    if(!_vtSupported || window.matchMedia('(prefers-reduced-motion: reduce)').matches){
      fn();
      return;
    }
    // startViewTransition 的回调必须同步修改 DOM（否则 VT 不工作）
    // 防御：若回调抛错，回退到直接渲染，绝不让页面卡在某次 transition 的中间态（白屏）
    try{
      document.startViewTransition(function(){
        fn();
      });
    }catch(err){
      try{ fn(); }catch(e2){ console.error('render error:', e2); }
    }
  }
  window._v3Wrap = _v3Wrap;

  /* ===== 工具：stages 颜色、emoji 映射 ===== */
  var STAGE_COLORS = {'低谷':'#E85D4E','回升':'#F5A04C','平稳':'#D4A017','积极':'#7CB342','饱满':'#5B9BD5'};
  var STAGE_EMOJI = {'低谷':'🥺','回升':'🌤','平稳':'😐','积极':'😊','饱满':'🤩'};
  function stageOf(e){ return e && e.stage ? e.stage.label : '平稳'; }
  function emojiOf(e){ return STAGE_EMOJI[stageOf(e)] || '😐'; }
  function colorOf(label){ return STAGE_COLORS[label] || '#5B4BD8'; }
  // 计算连续天数（从最新一天往前推，断一天就停）
  function calcStreak(){
    if(!ENTRIES.length) return 0;
    var n = 0;
    var prev = null;
    for(var i = ENTRIES.length - 1; i >= 0; i--){
      var d = ENTRIES[i].date;
      if(prev){
        var a = new Date(prev+'T00:00:00'), b = new Date(d+'T00:00:00');
        var diff = Math.round((a - b) / 86400000);
        if(diff === 1) n++;
        else break;
      } else {
        n = 1;
      }
      prev = d;
    }
    return n;
  }

  /* ===== 1. 连击天数：阈值切换 🔥/🌱/⚪ + 弹层热力图 ===== */
  var streakChip = document.getElementById('streakChip');
  var streakNumEl = document.getElementById('streakNum');
  function paintStreakChip(){
    if(!streakChip || !streakNumEl) return;
    var n = calcStreak();
    streakNumEl.textContent = n;
    var ic = streakChip.querySelector('.streak-ic');
    if(!ic) return;
    if(n >= 30){ ic.textContent = '🔥'; streakChip.className = 'top-chip green streak-chip tier-flame'; }
    else if(n >= 7){ ic.textContent = '🌱'; streakChip.className = 'top-chip green streak-chip tier-sprout'; }
    else { ic.textContent = '●'; streakChip.className = 'top-chip green streak-chip'; }
  }
  paintStreakChip();
  if(streakChip){
    var pop = document.createElement('div');
    pop.className = 'streak-pop';
    streakChip.style.position = 'relative';
    streakChip.appendChild(pop);
    function toggleStreakPop(){
      if(pop.classList.contains('show')){ pop.classList.remove('show'); return; }
      // 渲染最近 28 天热力图（4 周）
      var n = calcStreak();
      var last28 = ENTRIES.slice(-28);
      var dates = {};
      for(var i=0;i<last28.length;i++){ dates[last28[i].date] = last28[i]; }
      var html = '<div class="pttl">🔥 已连续 '+n+' 天</div><div class="phd"><span>4 周热力图</span><span>阶段色</span></div>';
      html += '<div class="ph">';
      var todayD = new Date(TODAY+'T00:00:00');
      for(var k=27;k>=0;k--){
        var d = new Date(todayD.getTime() - k*86400000);
        var ds = d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
        var e = dates[ds];
        var cls = 'pc';
        if(e){
          cls += ' has';
          var c = colorOf(stageOf(e));
          var style = 'style="--s:'+c+';background:'+c+';"';
        } else {
          var future = ds > TODAY;
          cls += future ? ' future' : '';
          var style = '';
        }
        html += '<span class="'+cls+'" '+style+' title="'+ds+(e?' · '+(e.score==null?'待评':e.score):'')+'"></span>';
      }
      html += '</div>';
      pop.innerHTML = html;
      pop.classList.add('show');
    }
    streakChip.addEventListener('click', function(ev){ ev.stopPropagation(); toggleStreakPop(); });
    document.addEventListener('click', function(ev){ if(!pop.contains(ev.target) && ev.target !== streakChip) pop.classList.remove('show'); });
  }

  /* ===== 2. 心情分数 emoji ===== */
  // 通过 DOM 直接注入到第一个 .num-big 后
  function injectMoodEmoji(){
    var detailCard = document.getElementById('detailCard');
    if(!detailCard) return;
    // 移除旧的
    var old = detailCard.querySelector('.mood-emoji');
    if(old) old.remove();
    var firstNum = detailCard.querySelector('.detail-left .hero-box .num-big');
    if(!firstNum) return;
    var e = BYDATE[state.date];
    if(!e || e.score == null) return;
    var em = document.createElement('span');
    em.className = 'mood-emoji';
    em.textContent = emojiOf(e);
    em.title = stageOf(e);
    firstNum.parentNode.insertBefore(em, firstNum.nextSibling);
  }

  /* ===== 3. 详情卡顶部色条：宽度跟 7 天相对位置成比例 + 7 天 timeline ===== */
  function paintDetailBar(){
    var detailCard = document.getElementById('detailCard');
    if(!detailCard) return;
    var old = detailCard.querySelector('.detail-bar-wrap');
    if(old) old.remove();
    var e = BYDATE[state.date];
    if(!e) return;
    var idx = idxOf(e.date);
    // 取最近 14 天 score
    var arr = ENTRIES.slice(Math.max(0, idx-13), idx+1).filter(function(x){ return x.score != null; });
    if(arr.length < 2) return;
    var min = Math.min.apply(null, arr.map(function(x){ return x.score; }));
    var max = Math.max.apply(null, arr.map(function(x){ return x.score; }));
    var range = Math.max(1, max - min);
    var pct = e.score == null ? 0 : Math.max(4, Math.min(100, ((e.score - min) / range) * 100));

    var wrap = document.createElement('div');
    wrap.className = 'detail-bar-wrap';
    wrap.innerHTML = '<div class="detail-bar-track"></div>'
      + '<div class="detail-bar-fill" style="width:'+pct+'%"></div>'
      + '<div class="detail-bar-tl">'
      + Array.from({length: 7}, function(){ return '<span class="tick"></span>'; }).join('')
      + '</div>';
    detailCard.appendChild(wrap);
  }

  /* ===== 4. 历史卡周/月分桶角标（统一在 line ~2100 实现，删除这里重复的） ===== */
  // 旧版选择器写错 (.dc[data-date])，永远不命中。删除避免死代码。

  /* ===== 5. 心情分数点击编辑 ===== */
  // 关键修复：每次 detailObs 触发都会跑此函数
  // 之前实现：每次只 remove .score-edit class（实际没真删 DOM 节点）
  //           每次 addEventListener('click', ...) 但不 remove 旧的
  //           后果：pop 节点累积、document click listener 累积
  // 修法：用一个全局 _scoreEditState 跟踪 pop 节点和 listener
  var _scoreEditState = { popEl: null, docClickHandler: null, keyHandler: null, firstNum: null, date: null };
  function wireScoreEdit(){
    var detailCard = document.getElementById('detailCard');
    if(!detailCard) return;
    if(_scoreEditState.popEl && _scoreEditState.popEl.isConnected && _scoreEditState.popEl.classList.contains('show') && _scoreEditState.date === state.date){
      return;
    }
    // 1) 清理旧状态：删 pop、卸载旧 listener、移 class
    if(_scoreEditState.popEl && _scoreEditState.popEl.parentNode){
      _scoreEditState.popEl.parentNode.removeChild(_scoreEditState.popEl);
    }
    if(_scoreEditState.docClickHandler){
      document.removeEventListener('click', _scoreEditState.docClickHandler, true);
    }
    if(_scoreEditState.keyHandler){
      _scoreEditState.firstNum && _scoreEditState.firstNum.removeEventListener('keydown', _scoreEditState.keyHandler);
    }
    if(_scoreEditState.firstNum){
      _scoreEditState.firstNum.classList.remove('score-edit');
      _scoreEditState.firstNum.removeEventListener('click', _scoreEditState.firstNum.__scoreEditClick);
    }
    _scoreEditState = { popEl: null, docClickHandler: null, keyHandler: null, firstNum: null, date: null };

    // 2) 找第一个 .num-big（心情分数）
    var firstNum = detailCard.querySelector('.detail-left .hero-box .num-big');
    if(!firstNum) return;
    var e = BYDATE[state.date];
    if(!e) return;
    firstNum.classList.add('score-edit');
    firstNum.title = '点击编辑今日心情';
    firstNum.style.cursor = 'pointer';

    // 3) 创建 pop
    var pop = document.createElement('div');
    pop.className = 'score-edit-pop';
    pop.setAttribute('role', 'dialog');
    pop.setAttribute('aria-label', '修改今日心情');
    pop.innerHTML = '<div class="label">修改今日心情（0–100）</div>'
      + '<div class="row"><input type="number" min="0" max="100" value="'+e.score+'" aria-label="今日心情分数"/></div>'
      + '<div class="actions"><button data-act="cancel">取消</button><button class="primary" data-act="save">保存到本地</button></div>';
    firstNum.parentNode.appendChild(pop);
    var input = pop.querySelector('input');

    // 4) 数字点击切换 pop
    var numClickHandler = function(ev){
      ev.stopPropagation();
      pop.classList.toggle('show');
      firstNum.setAttribute('aria-expanded', pop.classList.contains('show') ? 'true' : 'false');
      if(pop.classList.contains('show')){ setTimeout(function(){ input.focus({ preventScroll: true }); input.select(); }, 50); }
    };
    firstNum.setAttribute('tabindex', '0');
    firstNum.setAttribute('role', 'button');
    firstNum.setAttribute('aria-haspopup', 'dialog');
    firstNum.setAttribute('aria-expanded', 'false');
    firstNum.addEventListener('click', numClickHandler);
    firstNum.__scoreEditClick = numClickHandler;

    // 5) 外部点击关闭（capture 阶段，避免冒泡冲突）
    var docClickHandler = function(ev){
      if(!pop.contains(ev.target) && ev.target !== firstNum) pop.classList.remove('show');
    };
    document.addEventListener('click', docClickHandler, true);

    // 6) Esc 关 / Enter 存
    var keyHandler = function(ev){
      if(ev.key === 'Enter'){ pop.querySelector('[data-act="save"]').click(); }
      if(ev.key === ' '){ ev.preventDefault(); numClickHandler(ev); }
      if(ev.key === 'Escape'){ pop.classList.remove('show'); }
    };
    firstNum.addEventListener('keydown', keyHandler);

    // 7) 保存到 localStorage
    pop.querySelector('[data-act="cancel"]').addEventListener('click', function(){ pop.classList.remove('show'); });
    pop.querySelector('[data-act="save"]').addEventListener('click', function(){
      var v = Number(input.value);
      if(!isFinite(v) || input.value.trim() === '' || v < 0 || v > 100){ alert('请输入 0–100 之间的数字'); return; }
      v = Math.round(v);
      try{
        var all = JSON.parse(localStorage.getItem('diary-pending-scores') || '{}');
        if(!all || typeof all !== 'object' || Array.isArray(all)) all = {};
        all[state.date] = v;
        localStorage.setItem('diary-pending-scores', JSON.stringify(all));
      }catch(err){}
      e.score = v; e.score_source = 'user';
      var restoreY = window.scrollY || window.pageYOffset || 0;
      renderMain();
      renderChips();
      renderPeriodCompare();
      renderDataQuality();
      paintMetricsCard();
      pop.classList.remove('show');
      requestAnimationFrame(function(){
        requestAnimationFrame(function(){
          var behavior = document.documentElement.style.scrollBehavior;
          document.documentElement.style.scrollBehavior = 'auto';
          window.scrollTo(0, restoreY);
          document.documentElement.style.scrollBehavior = behavior;
          var freshNum = document.querySelector('.detail-left .hero-box .num-big');
          if(freshNum) freshNum.focus({ preventScroll: true });
        });
      });
    });

    // 8) 记入 _scoreEditState 供下次清理
    _scoreEditState.popEl = pop;
    _scoreEditState.docClickHandler = docClickHandler;
    _scoreEditState.keyHandler = keyHandler;
    _scoreEditState.firstNum = firstNum;
    _scoreEditState.date = state.date;
  }

  // renderDetail 完成后注入：emoji + bar + 编辑（用 MutationObserver）
  var _v3Busy = false;
  var detailObs = new MutationObserver(function(){
    if(_v3Busy) return;
    _v3Busy = true;
    try{
      injectMoodEmoji();
      paintDetailBar();
      wireScoreEdit();
      paintGrowthCard();
    }catch(err){}
    setTimeout(function(){ _v3Busy = false; }, 50);
  });
  var dc = document.getElementById('detailCard');
  if(dc) detailObs.observe(dc, {childList: true, subtree: true});
  // 初次跑一次
  setTimeout(function(){ injectMoodEmoji(); paintDetailBar(); wireScoreEdit(); paintGrowthCard(); }, 80);

  /* ===== 6. View Transitions API 包裹（统一在 _v3Wrap） ===== */
  // 修复：旧代码用 var _origSetDate = window.setDate，但 setDate 不是 window 属性
  //      且 prevEntry/nextEntry 是 function 声明不能重新赋值
  // 实际包装在 setDate 函数体 + dnav-btn onclick 内完成（见 line 173 / 496）
  // 这里的 if 块全部注释，删除避免误导

  /* ===== 7. logo 河流波浪 + 点击回顶部 ===== */
  var logo = document.getElementById('logoRiver');
  if(logo){
    logo.addEventListener('click', function(){
      logo.classList.add('firing');
      setTimeout(function(){ logo.classList.remove('firing'); }, 600);
      window.scrollTo({top: 0, behavior: 'smooth'});
    });
  }

  /* ===== 8. （已移除）页签切换"保留滚动位置"的 MutationObserver ===== */
  // 修复 BUG：原实现想用 MutationObserver 监听 #diary 内容变化后用 scrollBy 抵消高度差，
  // 以"保留切换页签时的滚动位置"。但它有两个致命问题导致**点击模块页面会无端自动滚动**：
  //   1) 记录旧位置的 .diary-nav click 监听是在 IIFE 初始化时挂的，那时 #diary 还是空的、
  //      querySelector('.diary-nav') 为 null，监听器从未挂上 → _lastDiaryTop 永远是 0、
  //      _diaryTransitioning 永远是 false；
  //   2) 于是每次 renderDiary 触发观察者时 delta = 0 - 当前diary距视口顶 = 一个任意大负值，
  //      直接 window.scrollBy(0, delta) → 页面被随意拉上/拉下。
  // 移除后：切页签只是内容高度自然变化，浏览器按原 scrollY 停留，不再有人为跳动。

  /* ===== 9. ⌘K 命令面板 ===== */
  var cmdkOverlay = document.getElementById('cmdkOverlay');
  var cmdkInput = document.getElementById('cmdkInput');
  var cmdkList = document.getElementById('cmdkList');
  var cmdkResults = []; // 当前过滤结果
  var cmdkIdx = 0;
  function openCmdk(){
    if(!cmdkOverlay) return;
    window._cmdkFocus = document.activeElement;
    cmdkOverlay.classList.add('show');
    refreshOverlayLock();
    cmdkInput.value = '';
    cmdkIdx = 0;
    renderCmdk('');
    setTimeout(function(){ cmdkInput.focus(); }, 50);
  }
  function closeCmdk(){
    cmdkOverlay && cmdkOverlay.classList.remove('show');
    refreshOverlayLock();
    var back = window._cmdkFocus; if(back && back.focus) back.focus(); window._cmdkFocus = null;
  }
  function renderCmdk(q){
    cmdkResults = buildCmdkResults(q);
    if(!cmdkResults.length){
      cmdkList.innerHTML = '<div class="cmdk-empty">没找到匹配项</div>';
      return;
    }
    cmdkList.innerHTML = cmdkResults.map(function(r, i){
      return '<div class="cmdk-item'+(i===cmdkIdx?' on':'')+'" data-i="'+i+'">'
        + '<span class="em">'+r.em+'</span>'
        + '<span class="main"><b>'+esc(r.title)+'</b><i>'+esc(r.sub||'')+'</i></span>'
        + (r.hint ? '<span class="hint">'+esc(r.hint)+'</span>' : '')
        + '</div>';
    }).join('');
    Array.prototype.forEach.call(cmdkList.querySelectorAll('.cmdk-item'), function(n){
      n.addEventListener('click', function(){ executeCmdk(parseInt(n.dataset.i, 10)); });
    });
  }
  function buildCmdkResults(q){
    var out = [];
    var ql = (q||'').toLowerCase().trim();
    function hit(text){ return !ql || String(text||'').toLowerCase().indexOf(ql) > -1; }
    // 静态命令
    var cmds = [
      {em:'🏠', title:'回到顶部', sub:'滚动到页面顶部', hint:'top', act: function(){ window.scrollTo({top:0, behavior:'smooth'}); }},
      {em:'📅', title:'跳到最新日记', sub:'今天的最新一篇', hint:'最新', act: function(){ setDate(latestDate(), false); }},
      {em:'◐', title:'切换深色/浅色', sub:'按 D 也行', hint:'D', act: function(){ var tb=document.getElementById('themeBtn'); if(tb) tb.click(); }},
      {em:'🔒', title:'切换演示模式', sub:'隐藏/显示好友姓名', hint:'隐私', act: function(){ var pb=document.getElementById('privacyBtn'); if(pb) pb.click(); }},
      {em:'🌊', title:'打开情绪河流图', sub:'跳转到可视化图', hint:'河流', act: function(){ scrollToId('riverCard'); }},
      {em:'🏃', title:'查看健康恢复', sub:'睡眠与步数趋势', hint:'健康', act: function(){ state.dtab='health'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'🩺', title:'查看数据体检', sub:'缺失记录一览', hint:'体检', act: function(){ state.dtab='law'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'📅', title:'打开月度回顾', sub:'按月统计与热力图', hint:'回顾', act: function(){ state.dtab='review'; renderDataPanel(); scrollToId('dataSecTitle'); }},
      {em:'📤', title:'导出 JSON 备份', sub:'包含全部日记数据', hint:'导出', act: function(){ exportJson(); }},
      {em:'❓', title:'打开功能指南', sub:'快捷键和本地修改说明', hint:'帮助', act: function(){ if(window.openHelpModal) window.openHelpModal(); }}
    ];
    out = out.concat(cmds.filter(function(cmd){ return hit(cmd.title + ' ' + cmd.sub + ' ' + cmd.hint); }));
    // 标签快速跳转
    var tagSet = {};
    var tagCount = 0;
    for(var i=0;i<ENTRIES.length;i++){
      (ENTRIES[i].tags||[]).forEach(function(t){ tagSet[t] = (tagSet[t]||0)+1; });
    }
    Object.keys(tagSet).forEach(function(t){
      if(tagCount < 8 && (!ql || t.toLowerCase().indexOf(ql)>=0)){
        out.push({em:'🏷', title:'#'+t, sub:tagSet[t]+' 条日记', hint:'标签', act: function(){
          // 通过 filter 模拟点击
          var sel=document.getElementById('tagFilter'); if(sel){ sel.value=t; sel.dispatchEvent(new Event('change')); }
          scrollToId('historySecTitle');
        }});
        tagCount++;
      }
    });
    // 日记搜索（限制 8 条避免列表过长）
    if(ql){
      var hits = [];
      for(var j=0;j<ENTRIES.length;j++){
        var e = ENTRIES[j];
        var hay = ((e.title||'')+' '+(e.overview||'')+' '+(e.mood||'')+' '+(e.thoughts||'')+' '+(e.tags||[]).join(' ')+' '+fmtFull(e.date)+' '+fmtW(e.date)+' '+e.date).toLowerCase();
        if(hay.indexOf(ql)>=0) hits.push(e);
        if(hits.length>=8) break;
      }
      // 标记分组
      hits.forEach(function(e){
        out.push({em:'📝', title:(e.title||fmtFull(e.date))+' · '+(e.score==null?'待评':e.score), sub:fmtFull(e.date)+' · '+(e.overview||'').slice(0,40), hint:stageOf(e), _group:'日记', act: function(){
          setDate(e.date, false);
          setTimeout(function(){ scrollToId('detailCard'); }, 60);
        }});
      });
    }
    // 修复：限制总结果数（之前不限制，36 条全显，列表过长）
    return out.slice(0, 30);
  }
  function executeCmdk(i){
    var r = cmdkResults[i];
    if(!r) return;
    closeCmdk();
    setTimeout(r.act, 50);
  }
  if(cmdkOverlay){
    document.addEventListener('keydown', function(ev){
      // ⌘K / Ctrl+K 打开
      if((ev.metaKey || ev.ctrlKey) && ev.key === 'k'){
        ev.preventDefault();
        if(cmdkOverlay.classList.contains('show')) closeCmdk(); else openCmdk();
      }
      if(ev.key === 'Escape' && cmdkOverlay.classList.contains('show')){ closeCmdk(); return; }
      if(!cmdkOverlay.classList.contains('show')) return;
      if(ev.key === 'Tab'){ trapDialogFocus(cmdkOverlay, ev); }
      // 上下选择 + 回车
      if(ev.key === 'ArrowDown'){ ev.preventDefault(); cmdkIdx = Math.min(cmdkResults.length-1, cmdkIdx+1); renderCmdk(cmdkInput.value); }
      if(ev.key === 'ArrowUp'){ ev.preventDefault(); cmdkIdx = Math.max(0, cmdkIdx-1); renderCmdk(cmdkInput.value); }
      if(ev.key === 'Enter'){ ev.preventDefault(); executeCmdk(cmdkIdx); }
    });
    cmdkInput.addEventListener('input', function(){ cmdkIdx = 0; renderCmdk(cmdkInput.value); });
    cmdkOverlay.addEventListener('click', function(ev){ if(ev.target === cmdkOverlay) closeCmdk(); });
  }

  /* ===== 10. 5 指标移到独立卡（移到 detailCard 下方） ===== */
  // 不重排 DOM：在 detailCard 后插入 metrics-card
  // 注意：metrics-card 不在 detailCard 内，独立 busy 标志
  var _metricsBusy = false;
  function paintMetricsCard(){
    if(_metricsBusy) return;
    _metricsBusy = true;
    try{
      var existing = document.getElementById('metricsCard');
      if(existing) existing.remove();
      var dcEl = document.getElementById('detailCard');
      if(!dcEl) return;
      var e = BYDATE[state.date];
      if(!e) return;
      var m = e.metrics || {};
      // 从 BYDATE 直接读 stMin/browseTotal/wCnt/lCnt（用全局 screenTotal / browseTotal 函数）
      var screenMin = (typeof screenTotal === 'function') ? screenTotal(e) : 0;
      var browseT = (typeof browseTotal === 'function') ? browseTotal(e) : 0;
      var didW = 0, didL = 0;
      (e.did||[]).forEach(function(g){ if({work:1,study:1,env:1,self:1}[g.cat]) didW++; else didL++; });
      // 用全局 fmtMin（已存在）

      var items = [
        {k:'mood', label:'心情', v:e.score, col:'#E85D4E'},
        {k:'energy', label:'精力', v:m.energy, col:'#F5A04C', basis: m.energy_basis},
        {k:'focus', label:'专注', v:m.focus, col:'#7CB342', basis: m.focus_basis},
        {k:'output', label:'产出', v:m.output, col:'#5B9BD5', basis: m.output_basis},
        {k:'overall', label:'综合', v:m.overall, col:'#5B4BD8'}
      ];
      var card = document.createElement('section');
      card.id = 'metricsCard';
      card.className = 'metrics-card';
      card.innerHTML = '<div class="ph"><h3>📊 今日指标</h3><button type="button" class="mini-link" id="scoreHelp">? 看评分说明</button></div>'
        + '<div style="display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:12px">'
        + items.map(function(it){
          var val = it.v == null ? '—' : it.v;
          // 修复：心情分如果是 AI 推断，在数值下加小标识
          var aiTag = (it.k === 'mood' && e.score_source === 'ai') ? '<span class="ai-tag">AI 推断</span>' : '';
          return '<div class="mi-cell" style="border:1px solid var(--line);background:var(--card-2)">'
            + '<div class="lab" style="color:var(--ink-2)"><span class="d" style="background:'+it.col+';width:8px;height:8px;border-radius:50%;display:inline-block"></span>'+it.label+'</div>'
            + '<div class="val" style="color:var(--ink);font-weight:650;font-variant-numeric:tabular-nums">'
            + ( (it.k==='mood'||it.k==='overall')
                ? val+(it.v==null?'':'<em style="font-size:11px;color:var(--ink-3);font-weight:500;margin-left:2px">/100</em>')
                : (it.v==null
                    ? '—'
                    : bandLabel(it.v)+'<em style="font-size:12px;color:var(--ink-2);font-weight:500;margin-left:4px;font-style:normal">'+it.v+'</em>') )
            + '</div>'
            + aiTag
            + ( (it.k==='energy'||it.k==='focus'||it.k==='output')
                ? '<div class="basis" style="font-size:10.5px;color:var(--ink-3);line-height:1.5;margin-top:3px">'+bandLabel(it.v)+(it.basis?' · '+esc(it.basis):'')+'</div>'
                : (it.basis ? '<div class="basis" style="font-size:10.5px;color:var(--ink-3);line-height:1.5;margin-top:3px">'+esc(it.basis)+'</div>' : '') )
            + '</div>';
        }).join('')
        + '</div>'
        + '<div class="daily-row">'
        + '<span class="dr-item"><b>📱</b> 屏幕 <em>'+fmtMin(screenMin)+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>🌐</b> 浏览 <em>'+browseT+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>✅</b> 事项 <em>'+didW+'/'+didL+'</em></span>'
        + '<span class="dr-sep">·</span>'
        + '<span class="dr-item"><b>📈</b> '+(e.daily||'—')+'</span>'
        + '</div>';
      dcEl.parentNode.insertBefore(card, dcEl.nextSibling);
      var scoreHelpButton = card.querySelector('#scoreHelp');
      if(scoreHelpButton) scoreHelpButton.onclick = openScoreHelp;
      // detail-right 现在只放「今日塔罗」，不再与 daily-row 重复 3 个小指标，故不再隐藏
    }catch(err){}
    setTimeout(function(){ _metricsBusy = false; }, 50);
  }
  // 用独立 setInterval 监听日期变化（避免受 detailObs 限制）
  setInterval(function(){
    if(window._lastMetricsDate !== state.date){
      window._lastMetricsDate = state.date;
      paintMetricsCard();
    }
  }, 200);
  setTimeout(paintMetricsCard, 200);

  /* ===== 12. 成长独立卡（已废弃：详情卡内已有成长卡，重复） ===== */
  // V3 早期版本在这里注入了一个孤立的"成长 68/100"小卡，但详情卡里已经存在
  // 原生的 hero-box 成长块（.detail-hero 第二个 .hero-box），导致重复
  // 这里保留函数以避免外部调用报错，但不实际渲染
  function paintGrowthCard(){
    // no-op: 详情卡自带的 hero-box 成长块已足够
  }

  /* ===== 17. 每日诗词印章卡片 ===== */
  // 用 dataset 记原始诗，避免被注入后的 DOM 污染 textContent
  // 注意：poem-stamp 操作的是 #footerPoem，不与 detailCard 互斥
  // 因此不用 _v3Busy 保护（否则切日期时诗不更新）
  var _poemBusy = false;
  function paintPoemStamp(){
    if(_poemBusy) return;
    _poemBusy = true;
    try{
      var f = document.getElementById('footerPoem');
      if(!f) return;
      var original = f.dataset.originalPoem || f.textContent.trim();
      if(!original) return;
      if(f.dataset.originalPoem) original = f.dataset.originalPoem;
      else f.dataset.originalPoem = original;
      var date = state.date || TODAY;
      // 避免重复渲染：如果已有的 sign 文本包含当前日期，跳过
      if(f.querySelector('.poem-stamp') && f.querySelector('.sign').textContent.indexOf(fmtFull(date)) > 0) return;
      f.innerHTML = '';
      var stamp = document.createElement('div');
      stamp.className = 'poem-stamp';
      // 修复：DATA.poem 是全局字段（没有 per-date 诗），切日期时诗内容不变
      // 修法：在签名前加"今日诗"标识（state.date != today 时特别标注）
      var isToday = state.date === TODAY;
      var signText = isToday
        ? '— '+esc(fmtFull(date))+' · 今日诗'
        : '— '+esc(fmtFull(date))+' · 选自今日诗';
      stamp.innerHTML = '<div class="body">'
        + '<div class="text">'+esc(original)+'</div>'
        + '<div class="sign">'+signText+'</div>'
        + '</div>'
        + '<div class="stamp">情绪<br>河流<em>·记·</em></div>';
      f.appendChild(stamp);
    }catch(err){}
    setTimeout(function(){ _poemBusy = false; }, 50);
  }
  setTimeout(paintPoemStamp, 300);
  // 切日期时也刷新（用一次轮询，但只触发一次）
  var _poemLastDate = null;
  setInterval(function(){
    if(_poemLastDate !== state.date){
      _poemLastDate = state.date;
      paintPoemStamp();
    }
  }, 600);

  /* ===== 18. 分享图生成（1080×1920 Canvas） ===== */
  var imgShareBtn = document.getElementById('imgShareBtn');
  var shareResult = document.getElementById('shareResult');
  var shareImg = document.getElementById('shareImg');
  function openShareResult(dataUrl){
    if(!shareResult) return;
    window._shareResultFocus = document.activeElement;
    shareImg.src = dataUrl;
    shareResult.classList.add('show');
    refreshOverlayLock();
    var close = document.getElementById('shareCloseBtn'); if(close) close.focus();
  }
  function closeShareResult(){
    if(!shareResult || !shareResult.classList.contains('show')) return;
    shareResult.classList.remove('show');
    refreshOverlayLock();
    var back = window._shareResultFocus;
    if(back && back.focus) back.focus();
    window._shareResultFocus = null;
  }
  if(shareResult){
    document.getElementById('shareCloseBtn').addEventListener('click', closeShareResult);
    shareResult.addEventListener('click', function(ev){ if(ev.target === shareResult) closeShareResult(); });
    document.addEventListener('keydown', function(ev){
      if(!shareResult.classList.contains('show')) return;
      if(ev.key === 'Escape') closeShareResult();
      if(ev.key === 'Tab') trapDialogFocus(shareResult, ev);
    });
  }
  function drawShareCard(){
    var e = BYDATE[state.date];
    if(!e){ alert('没有当前日记可分享'); return; }
    // 等待字体加载
    var fontsReady = (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
    fontsReady.then(function(){
      var W = 1080, H = 1920;
      var c = document.createElement('canvas');
      c.width = W; c.height = H;
      var ctx = c.getContext('2d');
      // 背景渐变（暖调奶白，不再偏紫）
      var bg = ctx.createLinearGradient(0, 0, W, H);
      bg.addColorStop(0, '#FAF7F2');
      bg.addColorStop(0.5, '#FDFBF7');
      bg.addColorStop(1, '#F5F0E8');
      ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H);
      // 装饰光晕（极淡——再小就完全看不见了，给点"水彩"感不染主色）
      var glow1 = ctx.createRadialGradient(W*0.15, H*0.1, 0, W*0.15, H*0.1, 350);
      glow1.addColorStop(0, 'rgba(91,75,216,0.04)');
      glow1.addColorStop(1, 'rgba(91,75,216,0)');
      ctx.fillStyle = glow1; ctx.fillRect(0, 0, W, H);
      var glow2 = ctx.createRadialGradient(W*0.9, H*0.95, 0, W*0.9, H*0.95, 300);
      glow2.addColorStop(0, 'rgba(224,111,149,0.04)');
      glow2.addColorStop(1, 'rgba(224,111,149,0)');
      ctx.fillStyle = glow2; ctx.fillRect(0, 0, W, H);
      // 顶部 logo
      ctx.save();
      var lx = 80, ly = 80, lr = 36;
      var lg = ctx.createLinearGradient(lx, ly, lx+lr*2, ly+lr*2);
      lg.addColorStop(0, '#5B4BD8'); lg.addColorStop(1, '#E06F95');
      ctx.fillStyle = lg;
      roundRect(ctx, lx, ly, lr*2, lr*2, 18); ctx.fill();
      ctx.strokeStyle = 'rgba(255,255,255,0.7)'; ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(lx+12, ly+lr+4);
      ctx.bezierCurveTo(lx+lr*0.5, ly+lr*0.4, lx+lr*0.8, ly+lr*1.4, lx+lr*1.4, ly+lr*0.6);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(lx+12, ly+lr+18);
      ctx.bezierCurveTo(lx+lr*0.5, ly+lr+10, lx+lr*0.8, ly+lr*1.8, lx+lr*1.4, ly+lr+12);
      ctx.stroke();
      ctx.restore();
      // 标题（加多平台 fallback：Hiragino Sans GB / Microsoft YaHei / Source Han Sans SC）
      ctx.fillStyle = '#17202B';
      ctx.font = '700 44px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", "Noto Sans CJK SC", sans-serif';
      ctx.textBaseline = 'top';
      ctx.fillText('情绪河流', 80, 90);
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", "Noto Sans CJK SC", sans-serif';
      ctx.fillText('每日自动记录', 80, 140);
      // 日期 + emoji（修复重叠：emoji 在右上，日期在 emoji 下方左侧）
      var emoji = emojiOf(e);
      ctx.font = '88px -apple-system, "Apple Color Emoji", "Segoe UI Emoji", sans-serif';
      ctx.textAlign = 'right';
      ctx.fillText(emoji, W-80, 90);
      ctx.fillStyle = '#5F6D7A';
      ctx.font = '600 26px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
      ctx.fillText(fmtFull(e.date), W-80, 200);
      ctx.textAlign = 'left';
      // 大心情分数（修复：/100 移到与心情数字基线对齐）
      ctx.fillStyle = '#7D8A99';
      ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif';
      ctx.fillText('心情', 80, 280);
      var stCol = colorOf(stageOf(e));
      ctx.fillStyle = stCol;
      ctx.font = '200 220px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
      ctx.fillText((e.score==null?'—':e.score), 80, 310);
      // /100 用 textBaseline='bottom' 与心情数字底部对齐
      // 修复 Vision 反馈：之前 y=530 偏下，改为 y=500 紧贴 220px 数字底部
      ctx.fillStyle = '#9AA3AE';
      ctx.font = '500 40px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textBaseline = 'bottom';
      ctx.fillText('/100', 320, 500);
      ctx.textBaseline = 'top';
      // 阶段 chip
      var stLabel = stageOf(e);
      var chipW = ctx.measureText(stLabel).width + 60;
      var chipH = 60;
      var chipX = 80, chipY = 580;
      ctx.fillStyle = stCol + '26';
      roundRect(ctx, chipX, chipY, chipW, chipH, 30); ctx.fill();
      ctx.fillStyle = stCol;
      ctx.font = '700 28px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textBaseline = 'middle';
      ctx.fillText(stLabel, chipX+30, chipY+chipH/2);
      ctx.textBaseline = 'top';
      // 5 指标行
      var m = e.metrics || {};
      var metrics = [
        {k:'精力', v:m.energy, col:'#F5A04C'},
        {k:'专注', v:m.focus, col:'#7CB342'},
        {k:'产出', v:m.output, col:'#5B9BD5'},
        {k:'成长', v:m.growth, col:'#A78BFA'}
      ];
      var my0 = 720;
      var mw = (W - 160) / 4;
      metrics.forEach(function(it, i){
        var x = 80 + i*mw;
        // 卡片
        ctx.fillStyle = 'rgba(255,255,255,0.7)';
        roundRect(ctx, x+8, my0, mw-16, 140, 16); ctx.fill();
        ctx.strokeStyle = 'rgba(23,32,43,0.08)';
        ctx.lineWidth = 1;
        roundRect(ctx, x+8, my0, mw-16, 140, 16); ctx.stroke();
        ctx.fillStyle = it.col;
        ctx.beginPath(); ctx.arc(x+30, my0+30, 8, 0, Math.PI*2); ctx.fill();
        ctx.fillStyle = '#5F6D7A';
        ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
        ctx.fillText(it.k, x+50, my0+18);
        ctx.fillStyle = '#17202B';
        ctx.font = '600 50px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
        ctx.textBaseline = 'alphabetic';
        // 数字靠左，/100 紧贴数字右侧 12px（修复重叠：之前 +8 太近，黏在一起）
        ctx.fillText((it.v==null?'—':it.v), x+18, my0+95);
        ctx.font = '500 50px -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif';
        var numW = ctx.measureText(String(it.v==null?'—':it.v)).width;
        ctx.fillStyle = '#7D8A99';
        ctx.font = '500 20px -apple-system, sans-serif';
        ctx.textBaseline = 'alphabetic';
        // /100 baseline 与数字 baseline 对齐（同 y），间距 12px
        ctx.fillText('/100', x+18+numW+12, my0+95);
        ctx.textBaseline = 'top';
      });
      // 7 天 sparkline
      var idx = idxOf(e.date);
      var last7 = ENTRIES.slice(Math.max(0, idx-6), idx+1);
      var sy0 = 920, sw = W - 160, sh = 180;
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      roundRect(ctx, 80, sy0, sw, sh, 20); ctx.fill();
      ctx.strokeStyle = 'rgba(23,32,43,0.08)';
      roundRect(ctx, 80, sy0, sw, sh, 20); ctx.stroke();
      ctx.fillStyle = '#5F6D7A';
      ctx.font = '700 24px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.fillText('最近 7 天心情', 110, sy0+22);
      var barW = (sw - 80) / last7.length;
      last7.forEach(function(x, i){
        var px = 110 + i*barW;
        var ph = x.score==null ? 8 : Math.max(8, (x.score/100)*(sh-80));
        var c = x.score==null ? '#E6EBF1' : colorOf(stageOf(x));
        ctx.fillStyle = c;
        var isLast = i === last7.length - 1;
        roundRect(ctx, px+4, sy0+sh-12-ph, barW-12, ph, 4); ctx.fill();
        if(isLast){
          ctx.strokeStyle = '#17202B'; ctx.lineWidth = 2.5;
          roundRect(ctx, px+4, sy0+sh-12-ph, barW-12, ph, 4); ctx.stroke();
        }
      });
      // 诗词印章
      var poem = (DATA && DATA.poem) || '每日一句诗词';
      var py0 = 1140;
      ctx.fillStyle = 'rgba(255,255,255,0.7)';
      roundRect(ctx, 80, py0, sw, 240, 20); ctx.fill();
      ctx.strokeStyle = 'rgba(23,32,43,0.08)';
      roundRect(ctx, 80, py0, sw, 240, 20); ctx.stroke();
      // 诗词用衬线字体（修复：加多平台 fallback——之前只有 Songti SC/STSong，在 Windows/Linux 浏览器会缺字）
      // font 链：Source Han Serif SC（开源跨平台）→ SimSun（Windows）→ Songti SC（Mac）→ STSong → serif
      ctx.fillStyle = '#17202B';
      ctx.font = '600 36px "Source Han Serif SC", "Noto Serif CJK SC", "Songti SC", "STSong", "SimSun", Georgia, serif';
      wrapText(ctx, poem, 130, py0+50, sw-280, 52);
      // 印章（修复：字号太小看不清，'·记·'改 22px，'情绪河流'加粗大字号）
      var sx = W-180, sy = py0+90, sr = 64;
      var sg = ctx.createLinearGradient(sx-sr, sy-sr, sx+sr, sy+sr);
      sg.addColorStop(0, '#C8362F'); sg.addColorStop(1, '#8B1A1A');
      ctx.save();
      ctx.translate(sx, sy);
      ctx.rotate(-6 * Math.PI / 180);
      ctx.fillStyle = sg;
      roundRect(ctx, -sr, -sr, sr*2, sr*2, 12); ctx.fill();
      // 印章边框细线
      ctx.strokeStyle = 'rgba(255,230,225,0.4)';
      ctx.lineWidth = 2;
      roundRect(ctx, -sr+8, -sr+8, sr*2-16, sr*2-16, 8); ctx.stroke();
      ctx.fillStyle = '#FCE8E5';
      ctx.font = '900 28px "STSong", "Songti SC", "SimSun", "Source Han Serif SC", serif';
      ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.fillText('情绪河流', 0, -10);
      ctx.font = '600 20px "STSong", "SimSun", "Source Han Serif SC", serif';
      ctx.fillText('·  记  ·', 0, 22);
      ctx.textAlign = 'left'; ctx.textBaseline = 'top';
      ctx.restore();
      // 签名
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 20px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.fillText('—  '+fmtFull(e.date)+' · 情绪河流', 130, py0+200);
      // 底部水印
      ctx.fillStyle = '#7D8A99';
      ctx.font = '500 22px -apple-system, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Source Han Sans SC", sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('🌊 情绪河流 · 每日自动记录', W/2, H-80);
      // 导出
      try{
        var dataUrl = c.toDataURL('image/png');
        openShareResult(dataUrl);
        window._lastShareDataUrl = dataUrl;
      }catch(err){
        alert('生成失败：' + err.message);
      }
    });
  }
  function roundRect(ctx, x, y, w, h, r){
    if(typeof r === 'number') r = {tl:r, tr:r, br:r, bl:r};
    ctx.beginPath();
    ctx.moveTo(x + r.tl, y);
    ctx.lineTo(x + w - r.tr, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r.tr);
    ctx.lineTo(x + w, y + h - r.br);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r.br, y + h);
    ctx.lineTo(x + r.bl, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r.bl);
    ctx.lineTo(x, y + r.tl);
    ctx.quadraticCurveTo(x, y, x + r.tl, y);
    ctx.closePath();
  }
  function wrapText(ctx, text, x, y, maxW, lh){
    var chars = text.split('');
    var line = '';
    var yy = y;
    for(var i=0;i<chars.length;i++){
      var t = line + chars[i];
      if(ctx.measureText(t).width > maxW && line){
        ctx.fillText(line, x, yy);
        line = chars[i];
        yy += lh;
      } else {
        line = t;
      }
    }
    if(line) ctx.fillText(line, x, yy);
  }
  if(imgShareBtn) imgShareBtn.addEventListener('click', drawShareCard);
  // 分享图操作
  var dl = document.getElementById('shareDownloadBtn');
  if(dl) dl.addEventListener('click', function(){
    if(!window._lastShareDataUrl) return;
    var a = document.createElement('a');
    a.href = window._lastShareDataUrl;
    a.download = '情绪河流-'+(state.date || TODAY)+'.png';
    a.click();
  });
  var cp = document.getElementById('shareCopyBtn');
  if(cp) cp.addEventListener('click', function(){
    if(!window._lastShareDataUrl) return;
    // 复制到剪贴板：先 fetch 成 blob
    fetch(window._lastShareDataUrl).then(r=>r.blob()).then(function(blob){
      try{
        var item = new ClipboardItem({'image/png': blob});
        navigator.clipboard.write([item]).then(function(){
          cp.textContent = '已复制 ✓';
          setTimeout(function(){ cp.textContent = '复制到剪贴板'; }, 1500);
        });
      }catch(err){
        alert('当前浏览器不支持复制图片，请用下载');
      }
    });
  });

  // 包装 ⌘K 也支持点击搜索框
  if(document.getElementById('searchInput')){
    // 修复：之前是 focus 立即抢焦点到 ⌘K，用户输入被打断
    // 改为：点击搜索框时打开 ⌘K 面板（搜索框只是入口），同时不立即抢焦点
    // 让用户用 ⌘K 面板进行搜索；原搜索框保留作为 ⌘K 提示入口
    var searchInput = document.getElementById('searchInput');
    searchInput.setAttribute('readonly', 'readonly'); // 防止真输入
    searchInput.addEventListener('focus', function(ev){
      ev.preventDefault();
      openCmdk();
      searchInput.blur();
    });
    searchInput.addEventListener('click', function(ev){
      ev.preventDefault();
      openCmdk();
    });
  }

  /* ===== 17. 诗词：fcount 区右侧加个 ⌘K 提示 ===== */
  // 已经在 placeholder 里加了 "⌘K" 提示

  /* ===== 顶部 ⌘K 快捷键提示加到 brand ===== */
  var brand = document.querySelector('.top-brand');
  if(brand){ brand.title = '快捷键：← → 切日期 · ⌘K 搜索 · D 切深色 · 点击 logo 回顶部'; }

  /* ===== 7. logo 河流流动效 + 回顶部 ===== */
  var logo = document.getElementById('logoRiver');
  if(logo){
    logo.addEventListener('click', function(){
      logo.classList.remove('flow');
      // 强制 reflow 重启动画
      void logo.offsetWidth;
      logo.classList.add('flow');
      setTimeout(function(){
        // 顺滑回到顶部
        window.scrollTo({top:0, behavior:'smooth'});
      }, 280);
      setTimeout(function(){
        logo.classList.remove('flow');
      }, 1300);
    });
  }

  /* ===== 4. 历史卡周/月分桶角标（用独立 busy 标志） ===== */
  // 修复：之前用 _v3Busy（detailObs 用的），会互相阻塞——如果 detailObs 正在跑，paintDcWeek 被 skip
  // 现在用独立的 _dcWeekBusy
  var _dcWeekBusy = false;
  function paintDcWeek(){
    if(_dcWeekBusy) return;
    _dcWeekBusy = true;
    try{
      var grid = document.getElementById('historyGrid');
      if(!grid) return;
      var dcs = grid.querySelectorAll('.dc');
      if(!dcs.length) return;
      var today = new Date(TODAY);
      dcs.forEach(function(dc, i){
        if(dc.querySelector('.dc-period')) return; // 已画过
        var dateStr = dc.dataset.d;
        if(!dateStr) return;
        var d = new Date(dateStr);
        if(isNaN(d.getTime())) return;
        var daysAgo = Math.floor((today - d) / (1000*60*60*24));
        var period = daysAgo < 7 ? 'week' : 'month';
        var badge = document.createElement('span');
        badge.className = 'dc-period dc-period-' + period;
        badge.title = daysAgo < 7 ? '本周' : '本月';
        dc.appendChild(badge);
      });
    }catch(err){}
    setTimeout(function(){ _dcWeekBusy = false; }, 50);
  }
  var gridObs = new MutationObserver(paintDcWeek);
  setTimeout(function(){
    var grid = document.getElementById('historyGrid');
    if(grid) gridObs.observe(grid, {childList: true, subtree: false});
    paintDcWeek();
  }, 200);
  // 当筛选条件变化（renderHistory）时，旧的 .dc 会被 replaceWith，dcPeriod 也消失
  // gridObs 的 childList: true 会自动触发 paintDcWeek —— OK

  // beforeunload 清理（防御性）
  window.addEventListener('beforeunload', function(){
    if(_dcWeekBusy === false) _dcWeekBusy = true; // 阻止后续 paintDcWeek
    if(gridObs) gridObs.disconnect();
  });
})();
