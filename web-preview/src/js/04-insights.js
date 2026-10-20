function renderChips(){
  var el=$('metricChips'); if(!el) return;
  if(!ENTRIES.length){ el.innerHTML=''; return; }
  var avg = {}, cnt = {};
  METRICS.forEach(function(mt){ avg[mt.key]=0; cnt[mt.key]=0; });
  ENTRIES.forEach(function(e){ METRICS.forEach(function(mt){ if(e.metrics[mt.key]!=null){ avg[mt.key]+=e.metrics[mt.key]; cnt[mt.key]++; } }); });
  METRICS.forEach(function(mt){ avg[mt.key]= cnt[mt.key] ? +(avg[mt.key]/cnt[mt.key]).toFixed(1) : null; });
  avg.growth = cnt.growth = 0;
  ENTRIES.forEach(function(e){ if(e.metrics.growth!=null){ avg.growth += e.metrics.growth; cnt.growth++; } });
  avg.growth = cnt.growth ? +(avg.growth/cnt.growth).toFixed(1) : null;
  var gcol = avg.growth==null ? 'var(--ink-3)' : '#4A8FDE';
  el.innerHTML = METRICS.map(function(mt){
    var col = mt.key==='overall' ? 'currentColor' : (avg[mt.key]==null ? 'var(--ink-3)' : mColor(avg[mt.key]));
    return '<div class="mo"><div class="mo-label">平均'+mt.label+'</div><div class="mo-val num">'+(avg[mt.key]==null?'—':avg[mt.key])+'<em>/100</em></div>'+
      '<div class="mo-bar"><div class="mo-fill" style="width:'+((avg[mt.key]==null?0:avg[mt.key])*10)+'%;background:'+col+'"></div></div></div>';
  }).join('')
  +'<div class="mo"><div class="mo-label">平均成长</div><div class="mo-val num">'+(avg.growth==null?'—':avg.growth)+'<em>/100</em></div>'+
    '<div class="mo-bar"><div class="mo-fill" style="width:'+((avg.growth==null?0:avg.growth)*10)+'%;background:'+gcol+'"></div></div></div>';
}

/* ================= 渲染：图表 ================= */
function smoothPath(pts){
  if(!pts.length) return '';
  var d = 'M'+pts[0].x+','+pts[0].y;
  for(var i=0;i<pts.length-1;i++){
    var cx=(pts[i].x+pts[i+1].x)/2;
    d += ' C'+cx+','+pts[i].y+' '+cx+','+pts[i+1].y+' '+pts[i+1].x+','+pts[i+1].y;
  }
  return d;
}

function renderChart(){
  var legend=$('chartLegend'), scroll=$('chartScroll'), stats=$('chartStats');
  if(!legend||!scroll) return;
  var tt = $('tooltip');
  var tabs=[].slice.call(document.querySelectorAll('.ctab[data-tab]'));
  tabs.forEach(function(b){ b.classList.toggle('on', b.dataset.tab===state.tab); });

  if(!ENTRIES.length){ legend.innerHTML=''; scroll.innerHTML=''; if(tt) scroll.appendChild(tt); stats.innerHTML=''; return; }

  // legend（仅 score 模式）
  if(state.tab==='score'){
    legend.innerHTML = METRICS.map(function(mt){
      return '<span class="lg'+(state.legend[mt.key]?'':' off')+'" data-k="'+mt.key+'"><span class="sw" style="background:'+mt.color+'"></span>'+mt.label+'</span>';
    }).join('');
    [].slice.call(legend.querySelectorAll('.lg')).forEach(function(l){
      l.onclick=function(){ state.legend[l.dataset.k]=!state.legend[l.dataset.k]; renderChart(); };
    });
  } else {
    legend.innerHTML = '';
  }

  var W = Math.max(ENTRIES.length*46+70, 620), H=250, PADL=34, PADR=16, PADT=14, PADB=26;
  var iw = W-PADL-PADR, ih = H-PADT-PADB;
  var step = ENTRIES.length>1 ? iw/(ENTRIES.length-1) : iw;

  if(state.tab==='score'){
    var active = METRICS.filter(function(mt){ return state.legend[mt.key]; });
    var g='';
    for(var gy=0; gy<=10; gy+=2){
      var yy = PADT + ih - (gy/100)*ih;
      g += '<line x1="'+PADL+'" y1="'+yy+'" x2="'+(W-PADR)+'" y2="'+yy+'" style="stroke:var(--line)" stroke-width="1"/>'+
           '<text x="'+(PADL-8)+'" y="'+(yy+3.5)+'" font-size="9.5" style="fill:var(--ink-3)" text-anchor="end">'+gy+'</text>';
    }
    // 面积（心情：主曲线，跳过未评分）
    var ptO = [];
    ENTRIES.forEach(function(e,i){ if(e.score!=null) ptO.push({x:PADL+i*step, y:PADT+ih-(e.score/100)*ih}); });
    if(ptO.length>1){
      var area = smoothPath(ptO) + ' L'+ptO[ptO.length-1].x+','+(PADT+ih)+' L'+ptO[0].x+','+(PADT+ih)+' Z';
      g += '<path d="'+area+'" fill="rgba(124,108,240,.07)"/>';
    }
    active.forEach(function(mt){
      var pts = ENTRIES.map(function(e,i){ return {x:PADL+i*step, y:PADT+ih-(e.metrics[mt.key]/100)*ih}; });
      g += '<path d="'+smoothPath(pts)+'" fill="none" stroke="'+mt.color+'" stroke-width="'+(mt.key==='mood'||mt.key==='overall'?2.6:1.8)+'" stroke-linecap="round" stroke-linejoin="round" opacity="'+(mt.key==='mood'?1:.75)+'"/>';
    });
    // 竖分隔线 + 日点
    ENTRIES.forEach(function(e,i){
      var x = PADL+i*step;
      g += '<line x1="'+x+'" y1="'+PADT+'" x2="'+x+'" y2="'+(PADT+ih)+'" style="stroke:'+(e.date===state.date?'currentColor':'var(--line)')+'" stroke-width="'+(e.date===state.date?1.2:1)+'"/>';
      active.forEach(function(mt){
        var y = PADT+ih-(e.metrics[mt.key]/100)*ih;
        g += '<circle cx="'+x+'" cy="'+y+'" r="'+(mt.key==='mood'?4:2.6)+'" fill="#fff" stroke="'+mt.color+'" stroke-width="2"/>';
      });
    });
    // 命中区
    ENTRIES.forEach(function(e,i){
      var x = PADL+i*step;
      g += '<rect x="'+(x-step/2)+'" y="'+PADT+'" width="'+step+'" height="'+ih+'" fill="transparent" data-d="'+e.date+'" style="cursor:pointer"/>';
    });
    scroll.innerHTML = '<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'" role="img" aria-label="心情与指标趋势图">'+g+'</svg>';
    scroll.appendChild(tt);
    bindHover(scroll, 'score');

    var rated = ENTRIES.filter(function(x){ return x.score!=null; });
    var avgM = rated.length ? +(rated.reduce(function(s,e){return s+e.score;},0)/rated.length).toFixed(1) : '—';
    var hi = rated.length ? rated.reduce(function(a,b){ return b.score>a.score?b:a; }) : null;
    var lo = rated.length ? rated.reduce(function(a,b){ return b.score<a.score?b:a; }) : null;
    stats.innerHTML =
      '<div class="cs"><div class="cs-num num">'+ENTRIES.length+'</div><div class="cs-label">记录天数</div></div>'+
      '<div class="cs"><div class="cs-num num">'+(avgM==='—'?'—':avgM)+'</div><div class="cs-label">平均心情</div></div>'+
      (hi?'<div class="cs"><div class="cs-num num">'+hi.score+'</div><div class="cs-label">最高 · '+fmtD(hi.date)+'</div></div>':'')+
      (lo?'<div class="cs"><div class="cs-num num">'+lo.score+'</div><div class="cs-label">最低 · '+fmtD(lo.date)+'</div></div>':'');
  }

  if(state.tab==='screen'){
    var maxMin = Math.max.apply(null, ENTRIES.map(screenTotal)) || 60;
    var bw = Math.max(16, Math.min(30, iw/ENTRIES.length*0.62));
    var g='';
    for(var gy2=0; gy2<=4; gy2++){
      var yy2 = PADT + ih - (gy2/4)*ih;
      g += '<line x1="'+PADL+'" y1="'+yy2+'" x2="'+(W-PADR)+'" y2="'+yy2+'" style="stroke:var(--line)"/>'+
           '<text x="'+(PADL-8)+'" y="'+(yy2+3.5)+'" font-size="9.5" style="fill:var(--ink-3)" text-anchor="end">'+(gy2===0?'0h':(maxMin*gy2/4/60).toFixed(1)+'h')+'</text>';
    }
    ENTRIES.forEach(function(e,i){
      var x = PADL+i*step;
      var v = screenTotal(e), hh = Math.max(1, v/maxMin*ih);
      var col = e.stage.color;
      if(e.date===state.date) col = 'currentColor';
      g += '<rect x="'+(x-bw/2)+'" y="'+(PADT+ih-hh)+'" width="'+bw+'" height="'+hh+'" rx="3" style="fill:'+col+';cursor:pointer" opacity="'+(e.date===state.date?1:.78)+'" data-d="'+e.date+'"/>';
      if(ENTRIES.length<=31) g += '<text x="'+x+'" y="'+(PADT+ih-hh-5)+'" font-size="9" style="fill:var(--ink-3)" text-anchor="middle" font-weight="600">'+fmtMin(v)+'</text>';
      g += '<text x="'+x+'" y="'+(H-8)+'" font-size="9.5" style="fill:'+(e.date===state.date?'currentColor':'var(--ink-3)')+'" text-anchor="middle" font-weight="600">'+fmtD(e.date)+'</text>';
    });
    scroll.innerHTML = '<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'">'+g+'</svg>';
    scroll.appendChild(tt);
    bindHover(scroll, 'screen');
    var totalMin = ENTRIES.reduce(function(s,e){return s+screenTotal(e);},0);
    var avgMin = Math.round(totalMin/ENTRIES.length);
    var maxD = ENTRIES.reduce(function(a,b){ return screenTotal(b)>screenTotal(a)?b:a; });
    stats.innerHTML =
      '<div class="cs"><div class="cs-num num">'+fmtMin(totalMin)+'</div><div class="cs-label">累计屏幕</div></div>'+
      '<div class="cs"><div class="cs-num num">'+fmtMin(avgMin)+'</div><div class="cs-label">日均</div></div>'+
      '<div class="cs"><div class="cs-num num">'+fmtMin(screenTotal(maxD))+'</div><div class="cs-label">最长 · '+fmtD(maxD.date)+'</div></div>';
  }

  if(state.tab==='browse'){
    var has = ENTRIES.filter(function(e){ return browseTotal(e)>0; });
    if(!has.length){
      scroll.innerHTML = '<div class="empty" style="margin:20px 0">暂无浏览足迹数据</div>';
      scroll.appendChild(tt);
      stats.innerHTML=''; return;
    }
    var maxN = Math.max.apply(null, has.map(browseTotal)) || 1;
    var g='';
    ENTRIES.forEach(function(e,i){
      var x = PADL+i*step;
      var v = browseTotal(e), hh = v? Math.max(1, v/maxN*ih) : 1.5;
      var col = e.stage.color;
      if(e.date===state.date) col = 'currentColor';
      g += '<rect x="'+(x-4)+'" y="'+(PADT+ih-hh)+'" width="8" height="'+hh+'" rx="2" style="fill:'+col+';cursor:pointer" opacity="'+(v? (e.date===state.date?1:.75):.15)+'" data-d="'+e.date+'"/>';
      if(ENTRIES.length<=31) g += '<text x="'+x+'" y="'+(PADT+ih-hh-5)+'" font-size="9" style="fill:var(--ink-3)" text-anchor="middle" font-weight="600">'+(v?v+'':'·')+'</text>';
      if(i%3===0 || e.date===state.date) g += '<text x="'+x+'" y="'+(H-8)+'" font-size="9.5" style="fill:'+(e.date===state.date?'currentColor':'var(--ink-3)')+'" text-anchor="middle">'+fmtD(e.date)+'</text>';
    });
    scroll.innerHTML = '<svg width="'+W+'" height="'+H+'" viewBox="0 0 '+W+' '+H+'">'+g+'</svg>';
    scroll.appendChild(tt);
    bindHover(scroll, 'browse');
    var tot = ENTRIES.reduce(function(s,e){return s+browseTotal(e);},0);
    var topD = has.reduce(function(a,b){ return browseTotal(b)>browseTotal(a)?b:a; });
    stats.innerHTML =
      '<div class="cs"><div class="cs-num num">'+tot+'</div><div class="cs-label">累计浏览</div></div>'+
      '<div class="cs"><div class="cs-num num">'+has.length+'</div><div class="cs-label">有记录的天数</div></div>'+
      '<div class="cs"><div class="cs-num num">'+browseTotal(topD)+'</div><div class="cs-label">最多 · '+fmtD(topD.date)+'</div></div>';
  }
}

function bindHover(scroll, mode){
  var tt = scroll.querySelector('.tt');
  var svg = scroll.querySelector('svg');
  if(!svg || !tt) return;
  if(!scroll._tipScrollBound){
    scroll._tipScrollBound = true;
    scroll.addEventListener('scroll', function(){ tt.style.opacity = 0; }, { passive: true });
  }
  svg.querySelectorAll('[data-d]').forEach(function(el){
    el.addEventListener('mouseenter', function(){
      var d = el.getAttribute('data-d'), e = BYDATE[d]; if(!e) return;
      var html = '<b>'+fmtFull(d)+' '+fmtW(d)+' · '+e.stage.label+' · 心情 '+(e.score==null?'待评分':e.score)+'分</b>';
      if(mode==='score'){
        METRICS.forEach(function(mt){ html += '<div class="r"><span>'+mt.label+'</span><i>'+e.metrics[mt.key]+'</i></div>'; });
      } else if(mode==='screen'){
        html += '<div class="r"><span>屏幕</span><i>'+fmtMin(screenTotal(e))+'</i></div>';
        (e.screen_apps||[]).slice(0,3).forEach(function(a){ html += '<div class="r"><span>'+esc(a.app)+'</span><i>'+fmtMin(a.min||0)+'</i></div>'; });
      } else {
        html += '<div class="r"><span>浏览</span><i>'+browseTotal(e)+' 次</i></div>';
      }
      tt.innerHTML = html;
      tt.style.opacity = 1;
      var c = el.getAttribute('cx')!=null ? parseFloat(el.getAttribute('cx')) : (parseFloat(el.getAttribute('x')) + parseFloat(el.getAttribute('width'))/2);
      tt.style.left = Math.min(Math.max(c, 10), Math.max(10, scroll.scrollWidth - tt.offsetWidth - 10)) + 'px';
      tt.style.top = '8px';
    });
    el.addEventListener('mouseleave', function(){ tt.style.opacity = 0; });
    el.addEventListener('click', function(){ setDate(el.getAttribute('data-d'), true); });
  });
}


/* ================= 渲染：分析 & 日历 & 历史 ================= */

function renderAnalytics(){
  var wdEl=$('weekdayAna'), stEl=$('stageAna'), tgEl=$('tagAna');
  if(!ENTRIES.length){ if(wdEl) wdEl.innerHTML='<div class="empty">暂无数据</div>'; if(stEl) stEl.innerHTML='<div class="empty">暂无数据</div>'; return; }
  // 周几分析（用心情分）
  var acc={}; for(var i=0;i<7;i++) acc[i]={s:0,n:0};
  ENTRIES.forEach(function(e){ if(e.score==null) return; var w=wdOf(e.date); acc[w].s+=e.score; acc[w].n++; });
  var order=[1,2,3,4,5,6,0];
  wdEl.innerHTML = order.map(function(w){
    var a=acc[w]; if(!a.n) return '<div class="wd-row"><span class="wd">'+WDN[w].slice(1)+'</span><div class="strack"></div><span class="wv muted">–</span></div>';
    var avg=+(a.s/a.n).toFixed(1), col=mColor(avg);
    return '<div class="wd-row"><span class="wd">'+WDN[w].slice(1)+'</span><div class="strack"><div class="sfill" style="width:'+(avg*10)+'%;background:'+col+'"></div></div><span class="wv" style="color:'+col+'">'+avg+'</span></div>';
  }).join('');
  // 阶段分布
  var cnt={}; ENTRIES.forEach(function(e){ cnt[e.stage.label]=(cnt[e.stage.label]||0)+1; });
  var orderS=STAGES.map(function(s){return s.label;}).filter(function(l){return cnt[l];});
  var total=ENTRIES.length;
  stEl.innerHTML = orderS.map(function(l){
    var st=STAGES.filter(function(s){return s.label===l;})[0];
    return '<div class="stage-row"><span class="sdot" style="background:'+st.color+'"></span><span class="sname">'+l+'</span><span class="scnt">'+cnt[l]+'天</span>'+
      '<div class="strack"><div class="sfill" style="width:'+(cnt[l]/total*100)+'%;background:'+st.color+'"></div></div></div>';
  }).join('');
  // 标签
  var tcnt={}; ENTRIES.forEach(function(e){ (e.tags||[]).forEach(function(t){ if(t) tcnt[t]=(tcnt[t]||0)+1; }); });
  var tagHtml = Object.keys(tcnt).sort(function(a,b){return tcnt[b]-tcnt[a];}).map(function(t){
    return '<span class="tag'+(state.tag===t?' on':'')+'" data-t="'+esc(t)+'">#'+esc(t)+' <b>'+tcnt[t]+'</b></span>';
  }).join('') || '<div class="empty">暂无标签</div>';
  if(tgEl){
    tgEl.innerHTML = tagHtml;
    [].slice.call(tgEl.querySelectorAll('.tag')).forEach(function(el){
      el.onclick=function(){ state.tag = (state.tag===el.dataset.t ? '' : el.dataset.t); var tf=$('tagFilter'); if(tf) tf.value=state.tag; renderHistory(); renderAnalytics(); };
    });
  }
}

function renderHistory(){
  var grid=$('historyGrid'), cnt=$('histCount'), sf=$('stageFilter'), tf=$('tagFilter');
  if(!sf) return;
  var list = applyFilters().slice().reverse();
  cnt.textContent = '共 '+list.length+' 条 / '+ENTRIES.length+' 条记录';
  if(!list.length){ grid.innerHTML = '<div class="dc-none">没有匹配的记录，换个关键词试试？</div>'; return; }
  grid.innerHTML = list.map(function(e){
    var mi=e.metrics;
    // 点阵 = 精力/专注/产出/综合
    var dots = ['energy','focus','output','overall'].map(function(k){
      var v=mi[k]; return '<span class="dc-dot" style="background:'+(k==='overall'?'currentColor':mColor(v))+';opacity:'+Math.max(.3,Math.min(1,v/100))+'"></span>';
    }).join('');
    var txt = (e.overview||e.mood||'').slice(0,96);
    var d = e.date;
    return '<div class="dc'+(state.date===d?' sel':'')+'" style="--mc:'+e.stage.color+'" data-d="'+d+'" tabindex="0" role="button" aria-label="打开'+fmtFull(d)+'的日记">'+
      '<div class="dc-top">'+
        '<div class="dc-date"><b class="num">'+d.slice(8)+'</b><span>'+d.slice(5,7)+'月 · '+fmtW(d)+'</span></div>'+
        '<span class="dc-score num'+(e.score==null?' dc-na':'')+'">'+(e.score==null?'—':e.score)+'</span>'+
      '</div>'+
      '<div class="dc-dots">'+dots+'</div>'+
      (txt?'<div class="dc-txt">'+esc(txt)+'</div>':'')+
      '<div class="dc-foot">'+
        '<span class="dc-stage" style="color:'+e.stage.color+';background:'+e.stage.color+'1a">'+e.stage.label+'</span>'+
        '<span class="dc-growth" style="color:'+mi.growth_stage.color+'">成长'+mi.growth+'</span>'+
        ((e.tags||[]).length?'<span class="dc-tag">#'+esc(e.tags[0])+'</span>':'')+
        '<span class="dc-arrow">›</span>'+
      '</div>'+
    '</div>';
  }).join('');
  [].slice.call(grid.querySelectorAll('.dc')).forEach(function(c){
    c.onclick=function(){ setDate(c.dataset.d, true); };
    c.onkeydown=function(ev){
      if(ev.key!=='Enter' && ev.key!==' ') return;
      ev.preventDefault();
      setDate(c.dataset.d, true);
    };
  });
  // 月份选项
  var mf=$('monthFilter');
  if(mf){
    var months = {};
    ENTRIES.forEach(function(e){ months[e.date.slice(0,7)] = 1; });
    mf.innerHTML = '<option value="">全部月份</option>'+Object.keys(months).sort().reverse().map(function(m){
      return '<option'+(state.month===m?' selected':'')+' value="'+m+'">'+m.slice(0,4)+'年'+parseInt(m.slice(5),10)+'月</option>';
    }).join('');
  }
  // 筛选器选项（保持一次）
  var opts={}; ENTRIES.forEach(function(e){ opts[e.stage.label]=1; (e.tags||[]).forEach(function(t){ if(t) opts['#'+t]=1; }); });
  sf.innerHTML = '<option value="">全部阶段</option>'+Object.keys(opts).filter(function(k){return k.indexOf('#')<0;}).map(function(k){
    return '<option'+(state.stage===k?' selected':'')+'>'+esc(k)+'</option>';
  }).join('');
  tf.innerHTML = '<option value="">全部标签</option>'+Object.keys(opts).filter(function(k){return k.indexOf('#')===0;}).map(function(k){
    return '<option'+(state.tag===k.slice(1)?' selected':'')+'>'+esc(k.slice(1))+'</option>';
  }).join('');
}

function renderHeader(){
  document.title = '情绪河流 · ' + (state.date ? fmtFull(state.date) : '每日自动记录');
  var streak=0;
  if(ENTRIES.length){
    var last = new Date(ENTRIES[ENTRIES.length-1].date+'T00:00:00');
    var cur = new Date(last);
    for(var i=ENTRIES.length-1;i>=0;i--){
      var d = new Date(ENTRIES[i].date+'T00:00:00');
      if(d.getTime()===cur.getTime()){ streak++; cur.setDate(cur.getDate()-1); }
      else break;
    }
  }
  $('streakNum').textContent = streak;
  $('genTime').textContent = '更新于 '+DATA.generated;
  $('footerPoem').textContent = '“'+DATA.poem+'”';
  $('footerGen').textContent = '每日自动更新 · '+DATA.generated;
}

/* ================= 导出 Markdown ================= */
function exportMd(){
  var e = BYDATE[state.date]; if(!e){ toast('没有可导出的日记'); return; }
  var L=[];
  L.push('# '+fmtFull(e.date)+'（'+fmtW(e.date)+'） 心情 '+(e.score==null?'待评分':e.score)+'/100 · '+e.stage.label+' · 综合 '+(e.metrics.overall==null?'—':e.metrics.overall)+' · 成长 '+(e.metrics.growth==null?'—':e.metrics.growth));
  L.push('');
  if(e.daily) L.push('> 今日数据：'+e.daily);
  if(e.overview) L.push('', '## 📅 今日概览', '', e.overview);
  if((e.thoughts||[]).length){ L.push('', '## 💭 想法与心情'); (e.thoughts||[]).forEach(function(t){ L.push('- '+t); }); }
  if((e.did||[]).length){ L.push('', '## ✅ 今天做了什么'); (e.did||[]).forEach(function(g){ L.push(''); L.push('### '+g.sub); (g.items||[]).forEach(function(x){ L.push('- '+x); }); }); }
  if((e.screen_apps||[]).length){ L.push('', '## ⏱️ 屏幕使用时间'); L.push('| App | 时长 |'); L.push('| --- | --- |'); (e.screen_apps||[]).forEach(function(a){ L.push('| '+a.app+' | '+a.time+' |'); }); }
  if((e.browse_sites||[]).length){ L.push('', '## 🌐 浏览足迹'); L.push('| 站点 | 次数 |'); L.push('| --- | --- |'); (e.browse_sites||[]).forEach(function(b){ L.push('| '+b.site+' | '+(b.n||0)+' |'); }); }
  if((e.memos||[]).length){ L.push('', '## 🗒️ 备忘录动态'); (e.memos||[]).forEach(function(x){ L.push('- '+x); }); }
  if((e.hermes_logs||[]).length){ L.push('', '## 📝 Hermes 协助记录'); (e.hermes_logs||[]).forEach(function(x){ L.push('- '+x); }); }
  if(e.plan) L.push('', '## 📌 明日计划', '', e.plan);
  if(e.workbuddy) L.push('', '## 🤖 WorkBuddy 记录', '', e.workbuddy);
  var md = L.join('\n');
  function fallback(){
    var ta=document.createElement('textarea'); ta.value=md; document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); toast('已复制 Markdown'); }catch(err){ toast('复制失败，请手动选择'); }
    document.body.removeChild(ta);
  }
  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(md).then(function(){ toast('已复制 Markdown'); }, fallback);
  } else fallback();
}

function toast(msg){
  var t=document.createElement('div'); t.className='toast'; t.setAttribute('role','status'); t.setAttribute('aria-live','polite'); t.textContent=msg; document.body.appendChild(t);
  requestAnimationFrame(function(){ t.classList.add('show'); });
  setTimeout(function(){ t.classList.remove('show'); setTimeout(function(){ t.remove(); },300); }, 1600);
}
