(function(){
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
    }catch(err){}
    setTimeout(function(){ _v3Busy = false; }, 50);
  });
  var dc = document.getElementById('detailCard');
  if(dc) detailObs.observe(dc, {childList: true, subtree: true});
  // 初次跑一次
  setTimeout(function(){ injectMoodEmoji(); paintDetailBar(); wireScoreEdit(); }, 80);
})();
