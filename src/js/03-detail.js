function renderDetail(){
  var h = $('detailCard'); if(!h) return;
  var ts = $('detailSecTitle');
  if(!state.date){ h.innerHTML = '<div class="empty">暂无日记记录</div>'; if(ts) ts.textContent='今日'; return; }
  if(ts) ts.textContent = (state.date===TODAY ? '今日' : fmtFull(state.date));
  var e = BYDATE[state.date], m = e.metrics, st = e.stage;
  var prev = prevEntry(state.date), nx = nextEntry(state.date);
  var diff = null;
  if(prev && e.score!=null && prev.score!=null){ diff = +(e.score - prev.score).toFixed(1); }
  var trendHtml = diff!==null ? (diff>0 ? '<span class="t-up">↑ +'+diff+' 较前日</span>' : diff<0 ? '<span class="t-down">↓ '+diff+' 较前日</span>' : '<span class="t-flat">→ 持平</span>') : '';
  var isToday = (e.date === TODAY);

  var miHtml = ['mood','energy','focus','output','overall'].map(function(k){
    var lab = {mood:'心情',energy:'精力',focus:'专注',output:'产出',overall:'综合'}[k];
    var v = m[k], col = (k==='overall'?'#2A2520':(v>=70?'#5A8A4F':(v>=50?'#C9851E':(v>=30?'#C9554A':'#A39888'))));
    var basis = m.basis && m.basis[k] ? m.basis[k] : (k==='overall'?'加权合成':'');
    return '<div class="mi-cell"><div class="lab"><span class="d" style="background:'+col+'"></span>'+lab+'</div><div class="val">'+v+'<em style="font-size:9px;color:var(--ink-3);font-weight:500;margin-left:1px">/100</em></div>'+(basis?'<div class="basis">'+esc(basis)+'</div>':'')+'</div>';
  }).join('');

  var bal = m.balance, life = 100-bal;
  var stMin = screenTotal(e), bt = browseTotal(e);
  var wCnt=0, lCnt=0;
  (e.did||[]).forEach(function(g){ if({work:1,study:1,env:1,self:1}[g.cat]) wCnt++; else lCnt++; });

  h.innerHTML =
    '<div class="detail-head">'
      +'<span class="dh-date"><b>'+fmtD(e.date)+'</b>'+fmtW(e.date)+(isToday?'<em>· 今天</em>':'')+'</span>'
      +'<div class="day-nav">'
        +'<button id="prevBtn" '+(prev?'':'disabled')+' aria-label="前一天">‹</button>'
        +'<span class="pick">'+(isToday?'今天':'最近一篇')+'</span>'
        +'<button id="nextBtn" '+(nx?'':'disabled')+' aria-label="后一天">›</button>'
      +'</div>'
      +'<div class="trend">'+trendHtml+'</div>'
    +'</div>'
    + (e.overview && e.overview.indexOf('无数据')<0
        ? '<div class="day-note">'+esc(e.overview)+'</div>'
        : '')
    +'<div class="detail-hd">'+
      '<div class="detail-left">'+
        '<div class="detail-hero">'+
          '<div class="hero-box">'+
            '<div class="hero-label"><span class="dot" style="background:'+st.color+'"></span>今日心情</div>'+
            '<div class="hero-score-line"><span class="num-big">'+(e.score==null?'—':e.score)+'</span><span class="num-sub">/100</span></div>'+
            '<span class="hero-tag strong" style="color:'+st.color+';background:'+st.color+'0d">'+st.label+'</span>'+
          '</div>'+
          '<div class="hero-box">'+
            '<div class="hero-label"><span class="dot" style="background:'+m.growth_stage.color+'"></span>今日成长</div>'+
            '<div class="hero-score-line"><span class="num-big">'+(m.growth==null?'—':m.growth)+'</span><span class="num-sub">/100</span></div>'+
            '<span class="hero-tag strong" style="color:'+m.growth_stage.color+';background:'+m.growth_stage.color+'0d">'+m.growth_stage.label+'</span>'+
          '</div>'+
        '</div>'+
        '<div class="dc-band">'+
          '<div class="dc-spark"></div>'
          +'<div class="dc-row dc-foot">'
            +'<div class="bal-mini">'
              +'<div class="bal-hd"><span>生活</span><span>'+life+'% / '+bal+'% 工作</span></div>'
              +'<div class="bal-bar"><div class="bal-life" style="width:'+life+'%"></div><div class="bal-work" style="width:'+bal+'%"></div></div>'
            +'</div>'
            +'<div class="stats-mini"><div class="st"><b>'+(e.daily||'—')+'</b><span>今日数据</span></div></div>'
          +'</div>'
        +'</div>'
      +'</div>'+
      '<div class="detail-right">'+
        (function(){
          var _tp = tarotPick(e);
          return '<div class="tome-lab">今日一签</div>'
            + buildTarot(e)
            + '<div class="tome-cap'+( _tp.dir==='rev' ? ' rev' : '')+'">'+esc(_tp.arc.cn)+' · '+esc(_tp.arc.mean)
              + '<i>'+( _tp.dir==='up' ? '正位 · 顺势而行' : '逆位 · 稍安勿躁' )+'</i>'
            + '</div>'
            + '<div class="tome-stats">'
              + '<span class="ts"><b>'+fmtMin(stMin)+'</b><em>屏幕</em></span>'
              + '<span class="ts"><b>'+bt+'</b><em>浏览</em></span>'
              + '<span class="ts"><b>'+wCnt+'/'+lCnt+'</b><em>事项</em></span>'
            + '</div>';
        })()+
      '</div>'+
    '</div>';

  var pb=$('prevBtn'), nb=$('nextBtn');
  if(pb) pb.onclick=function(){ if(prev) setDate(prev.date, false); };
  if(nb) nb.onclick=function(){ if(nx) setDate(nx.date, false); };
  var sh = $('scoreHelp');
  if(sh) sh.onclick=function(){ openScoreHelp(); };
  // 数字滚动动画：心情 + 成长 两颗数字
  var bigs = h.querySelectorAll('.num-big');
  if(bigs.length && e.score!=null) countUp(bigs[0], e.score);
  if(bigs.length>1 && m.growth!=null) countUp(bigs[1], m.growth);
  h.style.setProperty('--mc', st.color);

  // 7 天 sparkline：找到最近 7 天（含今天），按心情分渲染迷你条
  try{
    var idx = idxOf(e.date);
    var last7 = ENTRIES.slice(Math.max(0, idx-6), idx+1);
    if(last7.length){
      // 先清旧的（如果有）
      var oldSpark = h.querySelector('.spark7');
      if(oldSpark) oldSpark.remove();
      // 标记 hero 盒子：bar 会有 from-to 过渡
      var bars = last7.map(function(x, i){
        var isLast = i === last7.length - 1;
        if(x.score==null) return '<span class="bar" data-na="1" style="height:6px" title="'+x.date+' · 待评分"></span>';
        var pct = Math.max(8, Math.min(100, x.score));
        var stg = (x.stage && x.stage.label) || '';
        // 初始 height:0，下一帧切到 pct，触发 CSS 过渡
        return '<span class="bar'+(isLast?' is-today':'')+'" data-stage="'+esc(stg)+'" data-pct="'+pct+'" style="height:0" title="'+x.date+' · '+x.score+' · '+esc(stg)+'"></span>';
      }).join('');
      var spark = '<div class="spark7" title="最近 '+last7.length+' 天心情">'+bars+'</div>';
      // 7 天心情条：放进左侧底部「状态带」
      var spEl = h.querySelector('.dc-spark');
      if(spEl) spEl.insertAdjacentHTML('beforeend', spark);
      // 下一帧：把每个 bar 的 height 设到目标 pct，触发 CSS transition
      requestAnimationFrame(function(){
        var sp2 = h.querySelector('.dc-spark');
        if(!sp2) return;
        sp2.querySelectorAll('.spark7 .bar').forEach(function(bar){
          var pct = bar.dataset.pct;
          if(pct) bar.style.height = pct + '%';
        });
      });
      // 分数来源标注：保留在心情 hero-box 上
      var firstBox = h.querySelector('.detail-left .hero-box');
      var srcLabel = e.score==null ? '待评分' : (e.score_source==='ai' ? 'AI 推断' : '你的自评');
      var hasAiBadge = firstBox && firstBox.querySelector('.ai-badge');
      var srcNode = '<div class="score-source" data-src="'+esc(e.score_source||'user')+'"><span class="src-dot"></span>'+srcLabel+'</div>';
      // 如果大卡已有 AI 推断徽章，就不再插入 source 行；只在「你的自评」时插入
      if(firstBox && !firstBox.querySelector('.score-source') && (hasAiBadge ? (e.score_source==='user') : true)){
        firstBox.insertAdjacentHTML('beforeend', srcNode);
      }
    }
  }catch(err){ /* sparkline 失败不影响主流程 */ }
}
function renderDiary(){
  var d=$('diary'), t=$('diarySecTitle'); if(!d) return;
  if(!state.date){ d.innerHTML=''; if(t) t.textContent='日记'; return; }
  var e = BYDATE[state.date];
  if(t) t.textContent = (e.date===TODAY) ? '今日日记' : (fmtFull(e.date)+' 的日记');

  var cats = buildDiaryCats(e);
  if(!cats.length){ d.innerHTML='<div class="empty">今日无日记内容</div>'; return; }

  // 固定六大模块：不再拆分「更多数据」，直接全部平铺为固定页签
  // 修复 BUG：cur 原来在主题色计算之后才赋值（var 提升为 undefined），
  //           导致 --mod-c 永远取 state.dcat 而不是实际展示的当前页签 cur.key；
  //           若 state.dcat 非法（旧深链 key），主题色还会取错。把 cur 的解析提前。
  var cur = null;
  for(var i=0;i<cats.length;i++){ if(cats[i].key===state.dcat){ cur=cats[i]; break; } }
  if(!cur) cur = cats[0];
  if(state.dcat !== cur.key){
    state.dcat = cur.key;
    try{ history.replaceState(null,'','#date='+(state.date||'')+'&tab='+state.dcat); }catch(e){}
  }

  // 模块专属主题色：页签高亮、窗格圆点、模块光晕随页签联动
  var MODTHEME = {memos:'#E06F95', thoughts:'#A78BFA', 'learn-work':'#2F6FDE', 'fun-rest':'#F5A04C', health:'#E0637C', overview:'#5B4BD8', plan:'#E06F95', meta:'#8B95A6'};
  var mc = MODTHEME[cur.key] || '#5B4BD8';
  d.style.setProperty('--mod-c', mc);

  // 固定六大模块：不再拆分「更多数据」，直接全部平铺为固定页签
  function btn(c){
    // 高亮实际展示的当前页签：state.dcat 命中则高亮；若该日期没有 state.dcat 对应页签
    // （如深链指向的日子缺某模块），fallback 到 cur（已在前文解析为 cats[0]），避免全无高亮
    var on = c.key===state.dcat || (!(cats.some(function(x){ return x.key===state.dcat; })) && c===cur);
    return '<button class="dnav-btn'+(on?' on':'')+'" data-k="'+c.key+'" style="--mc:'+(MODTHEME[c.key]||'#5B4BD8')+'" title="'+esc(c.label)+'" role="tab" aria-selected="'+(on?'true':'false')+'" aria-controls="diaryPane">'
      +'<span class="dnav-ic">'+c.emoji+'</span><span class="dnav-lb">'+esc(c.label)+'</span>'
      +(c.count?'<span class="dnav-cnt">'+c.count+'</span>':'')+'</button>';
  }
  var nav = cats.map(btn).join('');

  d.innerHTML = '<div class="diary-view">'
    +'<div class="diary-nav" role="tablist" aria-label="日记模块">'+nav+'</div>'
    +'<div class="diary-pane" id="diaryPane" role="tabpanel" aria-label="当前日记模块">'
      +'<div class="pane-hd"><span class="dot"></span>'+cur.emoji+' '+esc(cur.label)+(cur.count?' · '+cur.count+' 项':'')+'</div>'
      +cur.html
    +'</div>'
  +'</div>';
  [].slice.call(d.querySelectorAll('.dnav-btn[data-k]')).forEach(function(b){
    b.onclick=function(){
      if(state.dcat === b.dataset.k) return;
      // ⚠️ 修复 BUG：旧的切换逻辑会先把旧窗格加上 .is-fading（透明度 0 = 白屏），
      // 再 setTimeout(160ms) 后异步 _v3Wrap 重渲染。一旦中间任何一步抛错或被打断，
      // 旧窗格会永远停在透明态 → 整个日记区白屏且无法切换。
      // 改为：先同步更新 state.dcat，再统一走 _v3Wrap 渲染。
      //   · 有 View Transitions API 时，startViewTransition 自动为前后状态做 crossfade；
      //   · 没有 VT / 系统减弱动效时，直接同步 renderDiary()（新窗格自带 paneRise 渐显动画）。
      //   无论如何都不会再留下“淡出后没人接管”的永久白屏。
      state.dcat = b.dataset.k;
      try{ history.replaceState(null,'','#date='+(state.date||'')+'&tab='+state.dcat); }catch(e){}
      _v3Wrap(function(){ renderDiary(); });
    };
    b.addEventListener('keydown', function(ev){
      if(ev.key !== 'ArrowRight' && ev.key !== 'ArrowLeft') return;
      ev.preventDefault();
      var buttons=[].slice.call(d.querySelectorAll('.dnav-btn[data-k]'));
      var next=buttons[(buttons.indexOf(b)+(ev.key==='ArrowRight'?1:buttons.length-1))%buttons.length];
      next.focus(); next.click();
    });
  });
  // 圆环生长动画：WAAPI 从空环过渡到目标偏移
  var reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if(!reduceMotion){
    [].slice.call(d.querySelectorAll('.ring-fg[data-off]')).forEach(function(c,i){
      c.animate([{strokeDashoffset:c.dataset.circ},{strokeDashoffset:c.dataset.off}],{duration:850,easing:'cubic-bezier(.77,0,.175,1)',fill:'both',delay:i*70});
    });
  }
}

function buildDiaryCats(e){
  var cats = [];
  function push(key, emoji, label, count, html){ if(html) cats.push({key:key, emoji:emoji, label:label, count:count, html:html}); }
  function groupsHtml(gs){
    var b='';
    gs.forEach(function(g){
      b += '<div class="did-sub">'+mdText(g.sub)+'</div>';
      (g.items||[]).forEach(function(x){ b += '<div class="did-item">'+mdText(x)+'</div>'; });
    });
    return b;
  }
  // 时间轴形态：带竖线与节点，镜头感更强
  function timelineHtml(gs){
    var b='';
    gs.forEach(function(g){
      b += '<div class="tl-group"><div class="tl-time">'+mdText(g.sub)+'</div>';
      (g.items||[]).forEach(function(x){ b += '<div class="tl-item">'+mdText(x)+'</div>'; });
      b += '</div>';
    });
    return b;
  }

  // 固定顺序按视频脚本叙事：随笔小记 → 想法与心情 → 学习与工作 → 娱乐休息 → 身心健康 → 今日概览（汇流）

  // 📝 随笔小记（亲手记录，优先展示 + 状态解读）
  var cleanMemos = (e.memos||[]).filter(function(x){ return x && x.indexOf('无数据')<0; });
  var memoHtml = cleanMemos.map(function(x){
    var p = memoParts(x);
    return '<div class="memo-item">'+(p.title?'<div class="memo-hd">'+esc(p.title)+'</div>':'')+'<div class="memo-body">'+mdText(p.body)+'</div></div>';
  }).join('');
  var anaHtml = '';
  if(cleanMemos.length){
    var A = analyzeMemo(cleanMemos.map(memoCleanText).join('。'));
    anaHtml = '<div class="memo-analysis">'
      +'<div class="ma-hd">✨ 状态解读</div>'
      +'<div class="ma-row"><span class="ma-k">情绪基调</span><b class="ma-tone" data-t="'+A.tone+'">'+A.tone+'</b>'
      + (A.energy ? '<span class="ma-k">精力</span><b>'+A.energy+'</b>' : '') + '</div>'
      + (A.themes.length ? '<div class="ma-row"><span class="ma-k">内容主题</span><span>'+A.themes.join(' · ')+'</span></div>' : '')
      + (A.tags.length ? '<div class="ma-row"><span class="ma-k">状态标签</span><span class="ma-tags">'+A.tags.map(function(x){ return '<i>#'+esc(x)+'</i>'; }).join('')+'</span></div>' : '')
      + '<div class="ma-txt">'+A.interp+'</div>'
      + (A.keys.length ? '<div class="ma-keys"><span class="ma-k">要点摘录</span><ul>'+A.keys.map(function(s){ return '<li>'+esc(s)+'</li>'; }).join('')+'</ul></div>' : '')
      +'</div>';
  }
  push('memos','📝','随笔小记', cleanMemos.length,
    (anaHtml + (memoHtml ? '<div class="memo-list">'+memoHtml+'</div>' : '')) || '');

  // 💭 想法
  var th = (e.thoughts||[]).map(function(x){ return '<div class="th-item">'+mdText(x)+'</div>'; }).join('');
  push('thoughts','💭','想法与心情', (e.thoughts||[]).length,
    th ? '<div class="th-list">'+th+'</div>' : '');

  // 📚 学习与工作（合并：工作/学习/环境/自我类事项 + Hermes 协助 + WorkBuddy 记录）
  var workCats = ['work','study','env','self'];
  var wkGroups = timelineHtml((e.did||[]).filter(function(g){ return workCats.indexOf(g.cat)>-1; }));
  var hermesHtml = (e.hermes_logs||[]).map(function(x){ return '<div class="src-item"><div class="src-badge" style="--sc:#5B4BD8">Hermes</div><div class="src-body">'+mdText(x)+'</div></div>'; }).join('');
  var wkCount = (e.did||[]).filter(function(g){ return workCats.indexOf(g.cat)>-1; }).reduce(function(s,g){ return s+(g.items||[]).length; },0);
  var wkHtml = '';
  if(wkGroups) wkHtml += '<div class="block"><div class="block-title">今日进展</div>'+wkGroups+'</div>';
  if(e.workbuddy) wkHtml += '<div class="block"><div class="src-item"><div class="src-badge" style="--sc:#0FA07A">WorkBuddy</div><div class="src-body wb-text">'+mdText(e.workbuddy)+'</div></div></div>';
  if(hermesHtml) wkHtml += '<div class="block"><div class="block-title">AI 工具日志</div>'+hermesHtml+'</div>';
  push('learn-work','📚','学习与工作', wkCount||null, wkHtml);

  // 🎬 娱乐休息（合并：娱乐/兴趣/生活类事项 + 屏幕时间 + 浏览足迹）
  var funCats = ['fun','hobby','life'];
  var fnGroups = timelineHtml((e.did||[]).filter(function(g){ return funCats.indexOf(g.cat)>-1; }));
  var fnCount = (e.did||[]).filter(function(g){ return funCats.indexOf(g.cat)>-1; }).reduce(function(s,g){ return s+(g.items||[]).length; },0);
  var fnHtml = '';
  if(fnGroups) fnHtml += '<div class="block"><div class="block-title">今日安排</div>'+fnGroups+'</div>';
  var scrHtml = '';
  if((e.screen_apps||[]).length){
    var maxA = Math.max.apply(null, e.screen_apps.map(function(a){return a.min||0;})) || 1;
    var bars = e.screen_apps.slice(0,6).map(function(a){
      var w = Math.max(4, Math.round((a.min||0)/maxA*100));
      return '<div class="rank-row"><span class="rank-name">'+esc(a.app)+'</span><div class="rank-track"><div class="rank-fill" data-w="'+w+'" style="--w:'+w+'%"></div></div><span class="rank-val">'+fmtMin(a.min||0)+'</span></div>';
    }).join('');
    scrHtml = '<div class="block"><div class="metric-chip-row"><span class="mchip">总时长 <b>'+fmtMin(screenTotal(e))+'</b></span></div><div class="rank-list">'+bars+'</div>'
      + (e.screen_note ? '<div class="note">'+mdText(e.screen_note)+'</div>' : '')+'</div>';
  } else if(e.screen_h>0){
    scrHtml = '<div class="block"><div class="metric-chip-row"><span class="mchip">屏幕时间 <b>共 '+e.screen_h+' 小时</b></span></div><div class="empty">明细未记录</div></div>';
  }
  var brRows = ''; var brHtml2 = '';
  if((e.browse_sites||[]).length){
    var bmax = Math.max.apply(null, e.browse_sites.map(function(b){return b.n||0;})) || 1;
    brRows = e.browse_sites.slice(0,6).map(function(b){
      var w = Math.max(4, Math.round((b.n||0)/bmax*100));
      return '<div class="rank-row"><span class="rank-name">'+esc(b.site)+'</span><div class="rank-track"><div class="rank-fill dim" data-w="'+w+'" style="--w:'+w+'%"></div></div><span class="rank-val">'+b.n+' 次</span></div>';
    }).join('');
    brHtml2 = '<div class="block"><div class="metric-chip-row"><span class="mchip">访问 <b>'+browseTotal(e)+' 次</b></span></div><div class="rank-list">'+brRows+'</div>'
      + (e.browse_note ? '<div class="note">'+mdText(e.browse_note)+'</div>' : '')+'</div>';
  } else { brHtml2=''; }
  if(scrHtml) fnHtml += scrHtml;
  if(typeof brHtml2!=='undefined' && brHtml2) fnHtml += brHtml2;
  push('fun-rest','🎬','娱乐休息', fnCount||null, fnHtml);

  // ❤️ 身心健康（精力/专注/产出/成长指标 + AI 判定依据；未来接入运动/睡眠后在此扩展）
  var mt = e.metrics||{};
  var HCOL = {energy:'#F5A04C', focus:'#2F6FDE', output:'#7C5CFF', growth:'#3E9B6C'};
  function metricRow(k,label,icon){
    var v = mt[k];
    if(v===undefined||v===null) return '';
    var pct = Math.max(0,Math.min(100,v));
    var r = 21, circ = (2*Math.PI*r).toFixed(1);
    var off = (circ*(1-pct/100)).toFixed(1);
    var col = HCOL[k] || '#5B4BD8';
    var basis = (mt.basis&&mt.basis[k]) ? esc(mt.basis[k]) : '';
    return '<div class="metric-detail" style="--hc:'+col+'">'
      +'<div class="ring-wrap">'
        +'<svg viewBox="0 0 52 52" class="ring-svg"><circle class="ring-bg" cx="26" cy="26" r="'+r+'"/>'
        +'<circle class="ring-fg" data-circ="'+circ+'" data-off="'+off+'" cx="26" cy="26" r="'+r+'" stroke-dasharray="'+circ+'" stroke-dashoffset="'+off+'"/></svg>'
        +'<div class="ring-num"><b>'+Math.round(v)+'</b></div>'
      +'</div>'
      +'<div class="metric-info"><div class="metric-name">'+icon+' '+label+'</div>'
      +(basis?'<div class="metric-basis">'+basis+'</div>':'')
      +'</div>'
      +'</div>';
  }
  var healthHtml = metricRow('energy','精力','⚡')+metricRow('focus','专注','🎯')
    +metricRow('output','产出','📦')+metricRow('growth','成长','🌱');
  if(e.mood && !mt.basis) healthHtml += '<div class="note">今日心情：'+mdText(e.mood)+'</div>';
  if(e.ios_health){
    var h=e.ios_health, bits=[];
    if(h.steps!=null) bits.push('<b>'+h.steps.toLocaleString()+'</b> 步');
    if(h.distance_km!=null) bits.push('<b>'+h.distance_km+'</b> km');
    if(h.active_energy_kcal!=null) bits.push('<b>'+h.active_energy_kcal+'</b> kcal');
    if(h.sleep_hours!=null) bits.push('<b>'+h.sleep_hours+'</b> 小时睡眠');
    if(bits.length) healthHtml += '<div class="note"><span class="health-source">iPhone · Apple 健康</span>'+bits.join(' · ')+'</div>';
  }
  push('health','❤️','身心健康', null, healthHtml ? '<div class="health-grid">'+healthHtml+'</div>' : '');

  // 📅 今日概览（各支流汇集成河，按脚本叙事放最后）——引言体叙事卡
  var ovDate = (e.date||'').slice(5).replace('-',' / ');
  var ovHtml = e.overview
    ? '<div class="ov-narr"><div class="ovn-mark">“</div><p class="ovn-text">'+mdText(e.overview)+'</p><div class="ovn-meta">— 情绪河流 · '+ovDate+' 的支流汇入</div></div>'
    : '';
  push('overview','📅','今日概览', null, ovHtml);

  // 📌 明日计划
  push('plan','📌','明日计划', null,
    e.plan ? '<div class="plan">'+mdText(e.plan)+'</div>' : '');

  // 🏷 元数据
  var meta=[];
  if(e.status) meta.push('<span class="chip">'+esc(e.status)+'</span>');
  (e.tags||[]).forEach(function(t){ meta.push('<span class="chip">#'+esc(t)+'</span>'); });
  push('meta','🏷','标签与状态', meta.length,
    meta.length ? '<div class="chip-row">'+meta.join('')+'</div>' : '');

  return cats;
}

/* ================= 渲染：指标概览 ================= */
